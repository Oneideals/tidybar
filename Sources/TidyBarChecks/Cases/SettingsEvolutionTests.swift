import Foundation
import TidyBarCore

// MARK: - 设置前向兼容、热键假开关、新图标问答、用户钉住

struct SettingsEvolutionTests {
    /// 老版本写下的设置文件里没有新字段。合成解码会整份失败，
    /// 而外层是 `try?` ⇒ 用户会遇到"我什么都没做，设置全回默认值"。
    func legacyFileKeepsExistingValues() throws {
        let suite = "tidybar-tests-\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let legacy = #"{"revealTriggers":["hover"],"rehideDelay":7.5,"newItemZone":"alwaysHidden","itemSpacing":2,"stylingEnabled":true,"rulesEnabled":false,"followMenuBarColorEnabled":false,"autoRecoverPendingIntent":false,"profiles":{},"rules":[]}"#
        defaults.set(Data(legacy.utf8), forKey: "tidybar.settings.v1")

        let store = UserDefaultsSettingsStore(defaults: defaults)
        let loaded = store.load()
        expectEqual(loaded.rehideDelay, 7.5, "老字段被丢了 ⇒ 整份设置被重置")
        expectEqual(loaded.newItemZone, MenuBarZone.alwaysHidden)
        expectEqual(loaded.revealTriggers, Set<RevealTrigger>([.hover]))
        expectEqual(loaded.autoRecoverPendingIntent, false)
        expectEqual(loaded.emptyBarClickAction, GestureAction.toggleDrawer)
        expectEqual(loaded.scrollOrSwipeAction, GestureAction.toggleFold)
        expectEqual(loaded.askAboutNewItems, false, "新字段该按默认值补上，而不是拉整份下水")
        expectEqual(loaded.hasCompletedFirstRunGuide, false)
        expect(!store.didFallBackToDefaults, "本可救回来的文件不该被记成回退事故")
        defaults.removePersistentDomain(forName: suite)
    }

    /// 自然手势（空白处点击/轻扫）与动作行为的序列化与反序列化
    func gestureActionsArePersistedAndDecoded() throws {
        var settings = AppSettings()
        settings.emptyBarClickAction = .toggleDrawer
        settings.scrollOrSwipeAction = .toggleDrawer
        settings.revealTriggers = [.emptyBarClick, .scrollOrSwipe]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        expectEqual(decoded.emptyBarClickAction, .toggleDrawer)
        expectEqual(decoded.scrollOrSwipeAction, .toggleDrawer)
        expectEqual(decoded.revealTriggers, [.emptyBarClick, .scrollOrSwipe])
    }

    /// 真的读不出来时，必须留下"我回退了"的痕迹，而不是静默当作首次运行。
    func unreadableFileIsReportedNotSwallowed() throws {
        let suite = "tidybar-tests-\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("不是 json".utf8), forKey: "tidybar.settings.v1")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        _ = store.load()
        expect(store.didFallBackToDefaults, "静默回退是最难归因的一类数据事故")
        defaults.removePersistentDomain(forName: suite)
    }

    /// 接管模式但没有合法落点：不许报成功，问答也要留在队列里让用户能重答。
    func assignmentWithoutLandingPointFailsLoudly() throws {
        let controller = makeController(
            settings: AppSettings(newItemZone: .hidden, askAboutNewItems: true),
            capableMover: true
        )
        let fresh = TestItems.item("com.test.new", centerX: 600, centerY: 1_188)
        controller.applyScan([fresh])
        expect(!controller.answerNewItem(fresh.id, zone: MenuBarZone.alwaysHidden),
               "没有 targetProvider 也没有坐标时不该报成功")
        expectEqual(controller.pendingNewItems.map(\.id), [fresh.id], "没生效就该继续问着")
        expect(controller.logs.contains(where: { $0.contains("合法落点") }),
               "原因要具体到缺落点/分隔符：\(controller.logs)")
    }

    /// 热键注册失败时，设置里不能还显示"快捷键已启用"。
    func failedHotKeyIsRetiredFromEffectiveTriggers() throws {
        let controller = makeController(settings: AppSettings(revealTriggers: [.dividerClick, .hotkey]))
        expect(controller.settings.revealTriggers.contains(RevealTrigger.hotkey))
        controller.retireHotKeyTrigger(reason: "权限不足")
        expect(!controller.settings.revealTriggers.contains(.hotkey),
               "挂着一个永不触发的方式比没有它更糟")
        expect(controller.logs.last?.contains("快捷键呼出不可用") ?? false, "\(controller.logs)")
        // 只摘一次，不该把别的呼出方式带下水
        expect(controller.settings.revealTriggers.contains(RevealTrigger.dividerClick))
    }

    func askQueueCollectsNewThirdPartyItems() throws {
        let controller = makeController(settings: AppSettings(newItemZone: .hidden, askAboutNewItems: true))
        let fresh = TestItems.item("com.test.new", centerX: 600, centerY: 1_188)
        controller.applyScan([fresh])
        expectEqual(controller.pendingNewItems.map(\.id), [fresh.id])

        expect(controller.answerNewItem(fresh.id, zone: MenuBarZone.alwaysHidden))
        expect(controller.pendingNewItems.isEmpty, "答过就该从队列里消失")
        expectEqual(controller.snapshot.layout.zone(of: fresh.id), MenuBarZone.alwaysHidden)

        // 关掉问答后不该继续攒问题
        controller.update { $0.askAboutNewItems = false }
        controller.applyScan([TestItems.item("com.test.other", centerX: 640, centerY: 1_188)])
        expect(controller.pendingNewItems.isEmpty)
    }

    /// 规则推出来的改动不能冒充"用户决定"——否则免修剪保护会攒一堆误钉。
    func ruleChangesAreNotPinnedAsUser() throws {
        let store = IdentityLedgerStore(url: TestPaths.journalDirectory("pin-origin").appendingPathComponent("identity-ledger.json"))
        let reader = FakeMenuBarReader(ids: ["com.test.a"])
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            // 降级模式：分配只是内存意图，一定会生效——本用例只验"谁的决定"，不掺落点问题
            services: makeServices(reader: reader, mover: UnverifiedMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("pin-engine")),
            ledger: store
        )
        let item = TestItems.item("com.test.a", centerX: 600, centerY: 1_188)
        engine.fold(items: [item], newItemZone: .visible)
        expectEqual(engine.ledgerRecordsSnapshot.first?.pinnedBy, IdentityRecord.Pin.inferred, "折叠只是推断")

        // 规则改动走控制器，来源标成 .rule ⇒ 不许钉住
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(),
            store: FakeSettingsStore()
        )
        controller.move(item.id, to: .hidden, origin: .rule)
        expectEqual(engine.ledgerRecordsSnapshot.first?.pinnedBy, IdentityRecord.Pin.inferred, "规则改动必须仍是 inferred")

        // 用户走同一条 move，来源默认 .user ⇒ 才允许钉住
        controller.move(item.id, to: .visible)
        expectEqual(engine.ledgerRecordsSnapshot.first?.pinnedBy, IdentityRecord.Pin.user, "用户改分区要能钉住")
        // 落盘要带回去，否则重启后保护就丢了
        expectEqual(store.load().first?.pinnedBy, IdentityRecord.Pin.user)
    }

    /// `capableMover=false` 对应今天线上形态（收纳面板降级：不搬图标，分配只是内存意图）；
    /// true 对应已解锁接管的机器，此时没有落点就必须显式失败。
    private func makeController(settings: AppSettings, capableMover: Bool = false) -> TidyBarController {
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(
                reader: FakeMenuBarReader(ids: []),
                mover: capableMover ? FakeMenuBarMover() : UnverifiedMenuBarMover()
            ),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("settings-evo-\(UUID().uuidString.prefix(6))"))
        )
        return TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: settings.rehideDelay),
            settings: settings,
            store: FakeSettingsStore(settings)
        )
    }
}

extension SettingsEvolutionTests {
    static var testCases: [TestCase] {
        let suite = SettingsEvolutionTests()
        return [
            TestCase("legacyFileKeepsExistingValues", suite.legacyFileKeepsExistingValues),
            TestCase("gestureActionsArePersistedAndDecoded", suite.gestureActionsArePersistedAndDecoded),
            TestCase("unreadableFileIsReportedNotSwallowed", suite.unreadableFileIsReportedNotSwallowed),
            TestCase("failedHotKeyIsRetiredFromEffectiveTriggers", suite.failedHotKeyIsRetiredFromEffectiveTriggers),
            TestCase("askQueueCollectsNewThirdPartyItems", suite.askQueueCollectsNewThirdPartyItems),
            TestCase("assignmentWithoutLandingPointFailsLoudly", suite.assignmentWithoutLandingPointFailsLoudly),
            TestCase("ruleChangesAreNotPinnedAsUser", suite.ruleChangesAreNotPinnedAsUser),
        ]
    }
}
