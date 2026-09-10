import Foundation
import Foundation
import CoreGraphics
import TidyBarCore

struct LayoutEngineTests {
    private let itemID = "com.test.dropbox"
    private let other = "com.test.wechat"

    private func makeEngine(
        reader: FakeMenuBarReader,
        mover: MenuBarMoving?,
        cursor: FakeCursor = FakeCursor(),
        label: String = "engine"
    ) -> (LayoutEngine, LayoutJournal) {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory(label))
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: mover, cursor: cursor),
            journal: journal,
            sentinel: EventSentinel(driftTolerance: 4, minIntervalBetweenOperations: 0.05)
        )
        return (engine, journal)
    }

    // MARK: 成功路径

    func successfulMoveCommitsAndClearsPending() throws {
        let reader = FakeMenuBarReader(ids: [itemID, other])
        let fakeMover = FakeMenuBarMover()
        fakeMover.coupledReader = reader
        let (engine, journal) = makeEngine(reader: reader, mover: fakeMover)

        try engine.apply(itemID: itemID, to: .hidden, targetX: 700)

        expect(engine.layout.zone(of: itemID) == .hidden)
        expect(engine.capability == .fullDrag)
        expect(engine.hasConfirmedDragSupport, "完成一次「拖拽 + 复核全绿」才算 M0 达标")
        expect(journal.readPendingIntent() == nil, "成功后必须清掉意图，否则下次启动会误重放")
        expect(journal.readCommittedLayout()?.zone(of: itemID) == .hidden)
        expect(fakeMover.moved.count == 1)
    }

    // MARK: 哨兵中止路径

    func userHoldingMouseAbortsAndRollsBack() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let (engine, journal) = makeEngine(reader: reader, mover: FakeMenuBarMover(), cursor: FakeCursor(pressed: true))

        expect(throws: LayoutEngine.EngineError.sentinelAborted(.userInteracting)) {
            try engine.apply(itemID: itemID, to: .hidden, targetX: 600)
        }
        expect(engine.layout.zone(of: itemID) == nil, "回滚后不得留下半成品布局")
        expect(!journal.hasPendingIntent)
        expect(!engine.hasConfirmedDragSupport)
    }

    /// 落点偏离目标 40pt：典型的「光标被系统接管」现场，必须中止
    /// 验证项 3 之后的职责划分：光标纪律（含落点漂移）归 mover，
    /// 引擎只认「图标到底动没动」。这里 FakeMenuBarMover 没有联动 reader，
    /// 等于模拟 macOS 静默忽略，引擎必须判失败并回滚。
    func dragWithNoVisibleEffectRollsBack() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let (engine, journal) = makeEngine(reader: reader, mover: FakeMenuBarMover(landingY: 1_148))

        do {
            // 目标要离开原位（600 是图标当前中心），否则"已在目标位"规则会合法放过
            try engine.apply(itemID: itemID, to: .hidden, targetX: 700)
            try record("图标没动必须判为失败，否则会把没发生的变更提交")
        } catch let error as LayoutEngine.EngineError {
            guard case .noVisibleEffect = error else {
                try record("应判定 noVisibleEffect，实际：\(error)")
                return
            }
        }
        expect(engine.layout.zone(of: itemID) == nil, "回滚后不留半成品布局")
        expect(!journal.hasPendingIntent)
        expect(!engine.hasConfirmedDragSupport, "没产生效果不算一次成功验证")
    }

    /// 联动读取器的假拖拽器 = 系统真的重排了：引擎才允许提交
    func dragThatActuallyMovesCommits() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        let (engine, journal) = makeEngine(reader: reader, mover: mover)

        try engine.apply(itemID: itemID, to: .hidden, targetX: 640)
        expectEqual(engine.layout.zone(of: itemID), .hidden)
        expect(engine.hasConfirmedDragSupport)
        expectNil(journal.readPendingIntent())
    }

    // MARK: 降级路径

    func unsupportedSystemDegradesToPanelOnly() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let (engine, journal) = makeEngine(reader: reader, mover: UnverifiedMenuBarMover(), label: "unsupported")

        expect(engine.capability == .panelOnlyFallback)
        expect(engine.capabilityReason != nil)

        try engine.apply(itemID: itemID, to: .hidden, targetX: 600)

        expect(engine.layout.zone(of: itemID) == .hidden, "降级模式下布局仅在内存/面板内生效")
        expect(!engine.hasConfirmedDragSupport)
        expect(journal.readPendingIntent() == nil, "降级路径也必须收尾，不留孤儿意图")
    }

    func moverErrorRollsBackLayout() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        mover.injectedError = .itemVanished(itemID)
        let (engine, journal) = makeEngine(reader: reader, mover: mover)

        expect(throws: LayoutEngine.EngineError.moveFailed(.itemVanished(itemID))) {
            try engine.apply(itemID: itemID, to: .hidden, targetX: 600)
        }
        expect(engine.layout.zone(of: itemID) == nil)
        expect(!journal.hasPendingIntent)
    }

    // MARK: 启动恢复

    func orphanedIntentIsReplayedOnLaunch() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("orphan"))
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(
            LayoutJournal.LayoutIntent(itemID: itemID, targetZone: .hidden, targetPosition: nil, previousZone: .visible, previousPosition: 0)
        )

        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: FakeMenuBarReader(ids: [itemID]), mover: nil),
            journal: journal
        )
        let recovery = engine.recoverOnLaunch()

        guard case .interrupted(let intent, _) = recovery else {
            try record("应识别为上次变更未完成")
            return
        }
        expect(intent.targetZone == .hidden)
        expect(engine.layout.zone(of: itemID) == .hidden, "按意图重建，而不是从系统当前状态反推用户想要什么")
    }

    func discardPendingIntentFallsBackToCommitted() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("discard"))
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(
            LayoutJournal.LayoutIntent(itemID: itemID, targetZone: .alwaysHidden, targetPosition: nil, previousZone: .visible, previousPosition: 0)
        )

        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: FakeMenuBarReader(ids: [itemID]), mover: nil),
            journal: journal
        )
        _ = engine.recoverOnLaunch()
        engine.discardPendingIntent()

        expect(engine.layout.zone(of: itemID) == .visible, "用户显式放弃时回到上次已确认布局")
        expect(!journal.hasPendingIntent)
    }

    // MARK: 同步

    func synchronizeAdoptsNewAndDropsGoneItems() throws {
        let reader = FakeMenuBarReader(ids: [itemID])
        let (engine, _) = makeEngine(reader: reader, mover: nil)
        engine.synchronize(newItemZone: .hidden)
        expect(engine.layout.zone(of: itemID) == .hidden)

        reader.items = [TestItems.item(other)]
        engine.synchronize(newItemZone: .visible)
        expect(engine.layout.zone(of: itemID) == nil)
        expect(engine.layout.zone(of: other) == .visible)
    }
}

struct TidyBarControllerTests {
    private func makeController(
        settings: AppSettings = AppSettings(),
        mover: MenuBarMoving? = UnverifiedMenuBarMover(),
        store: FakeSettingsStore = FakeSettingsStore(),
        ids: [String] = ["com.test.a", "com.test.b"],
        contextProvider: SystemContextProviding = LiveSystemContextProvider()
    ) -> (TidyBarController, FakeMenuBarReader) {
        let reader = FakeMenuBarReader(ids: ids)
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("controller"))
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: mover),
            journal: journal
        )
        var resolved = settings
        resolved.revealTriggers = [.dividerClick, .hotkey]
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: settings.rehideDelay),
            settings: resolved,
            store: store,
            contextProvider: contextProvider
        )
        controller.start(now: TestDates.onWeekday())
        return (controller, reader)
    }

    func onlyEnabledTriggersReveal() throws {
        let (controller, _) = makeController()
        controller.handle(event: .init(trigger: .hover, location: .zero), at: Date())
        expect(!controller.snapshot.isRevealed, "未启用的呼出方式不得生效")

        controller.handle(event: .init(trigger: .dividerClick, location: .zero), at: Date())
        expect(controller.snapshot.isRevealed)
    }

    func autoConcealAfterDelay() throws {
        let (controller, _) = makeController(settings: AppSettings(rehideDelay: 2))
        let start = Date(timeIntervalSince1970: 50_000)

        controller.handle(event: .init(trigger: .dividerClick, location: .zero), at: start)
        expect(controller.snapshot.isRevealed)
        expect(!controller.tick(at: start.addingTimeInterval(1)))
        expect(controller.tick(at: start.addingTimeInterval(2)))
        expect(!controller.snapshot.isRevealed)
    }

    func searchRanksByMatchQuality() throws {
        let (controller, _) = makeController(ids: ["Dropbox", "WeChat", "Notion"])
        expect(controller.search("not").first?.title == "Notion")
        expect(controller.search("drop").map(\.title) == ["Dropbox"])
        expect(controller.search("").count == 3, "空查询不视为过滤")
    }

    func demoModeLeavesSystemItemsAlone() throws {
        let (controller, reader) = makeController()
        reader.items.append(TestItems.item("com.apple.clock", isSystemOwned: true))
        controller.refreshItems()
        controller.move("com.apple.clock", to: .visible)

        controller.toggleDemoMode(at: Date())

        expect(controller.isDemoMode)
        expect(controller.snapshot.layout.zone(of: "com.apple.clock") == .visible, "系统项由用户自己决定，工具不接管")
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .hidden)
    }

    func profileSaveAndApply() throws {
        let store = FakeSettingsStore()
        let (controller, _) = makeController(store: store)

        controller.move("com.test.a", to: .alwaysHidden)
        controller.saveProfile(named: "录屏干净版")

        controller.move("com.test.a", to: .visible)
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .visible)

        controller.applyProfile(named: "录屏干净版")
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .alwaysHidden)
        expect(store.stored?.activeProfileName == "录屏干净版")
    }

    func profileListAndDelete() throws {
        let store = FakeSettingsStore()
        let (controller, _) = makeController(store: store)
        controller.saveProfile(named: "工作")
        controller.saveProfile(named: "家庭")
        expect(controller.listProfiles() == ["家庭", "工作"])
        controller.deleteProfile(named: "家庭")
        expect(controller.listProfiles() == ["工作"])
    }

    func rulesEvaluatedWithCurrentContext() throws {
        var settings = AppSettings()
        settings.rules = [DisplayRule(name: "专注模式隐藏", conditions: [.focusModeActive], actions: [.hide("com.test.a")])]
        struct MockProvider: SystemContextProviding {
            func currentContext() -> SystemContext {
                SystemContext(batteryLevel: nil, isCharging: false, connectedWiFiSSID: nil, activeFocusMode: "工作", frontmostAppBundleID: nil)
            }
        }
        let (controller, _) = makeController(settings: settings, contextProvider: MockProvider())
        _ = controller.move("com.test.a", to: .visible)
        let batch = controller.evaluateRulesWithCurrentContext()
        expect(batch.changes.count == 1)
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .hidden)
    }

    func rulesAreAppliedThroughController() throws {
        var settings = AppSettings()
        settings.rules = [DisplayRule(name: "低电量收起", conditions: [.batteryLow], actions: [.hide("com.test.a")])]
        let (controller, _) = makeController(settings: settings)
        controller.move("com.test.a", to: .visible)

        let batch = controller.evaluateRules(context: SystemContext(
            batteryLevel: 0.05,
            isCharging: false,
            connectedWiFiSSID: "Office",
            activeFocusMode: nil,
            frontmostAppBundleID: nil,
            now: TestDates.onWeekday(hour: 15),
            calendar: fixedCalendar()
        ))

        expect(batch.changes.count == 1)
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .hidden)
    }

    func rulesCanBeDisabledGlobally() throws {
        var settings = AppSettings()
        settings.rulesEnabled = false
        settings.rules = [DisplayRule(name: "低电量收起", conditions: [.batteryLow], actions: [.hide("com.test.a")])]
        let (controller, _) = makeController(settings: settings)
        controller.move("com.test.a", to: .visible)

        let batch = controller.evaluateRules(context: SystemContext(
            batteryLevel: 0.05,
            isCharging: false,
            connectedWiFiSSID: "Office",
            activeFocusMode: nil,
            frontmostAppBundleID: nil,
            now: TestDates.onWeekday(hour: 15),
            calendar: fixedCalendar()
        ))
        expect(batch.isEmpty)
        expect(controller.snapshot.layout.zone(of: "com.test.a") == .visible)
    }

    func settingsUpdatesArePersistedAndSanitized() throws {
        let store = FakeSettingsStore()
        let (controller, _) = makeController(store: store)
        controller.update { $0.rehideDelay = 999 }

        expect(controller.settings.rehideDelay == 10, "非法值必须夹紧，不能让手改 plist 把工具搞崩")
        expect(store.stored?.rehideDelay == 10)
    }

    func snapshotCallbackFires() throws {
        let (controller, _) = makeController()
        var updates = 0
        controller.onSnapshot = { _ in updates += 1 }

        controller.handle(event: .init(trigger: .dividerClick, location: .zero), at: Date())
        controller.conceal()

        expect(updates >= 2)
    }
}

extension LayoutEngineTests {
    static var testCases: [TestCase] {
        let suite = LayoutEngineTests()
        return [
            TestCase("successfulMoveCommitsAndClearsPending", suite.successfulMoveCommitsAndClearsPending),
            TestCase("userHoldingMouseAbortsAndRollsBack", suite.userHoldingMouseAbortsAndRollsBack),
            TestCase("dragWithNoVisibleEffectRollsBack", suite.dragWithNoVisibleEffectRollsBack),
            TestCase("dragThatActuallyMovesCommits", suite.dragThatActuallyMovesCommits),
            TestCase("unsupportedSystemDegradesToPanelOnly", suite.unsupportedSystemDegradesToPanelOnly),
            TestCase("moverErrorRollsBackLayout", suite.moverErrorRollsBackLayout),
            TestCase("orphanedIntentIsReplayedOnLaunch", suite.orphanedIntentIsReplayedOnLaunch),
            TestCase("discardPendingIntentFallsBackToCommitted", suite.discardPendingIntentFallsBackToCommitted),
            TestCase("synchronizeAdoptsNewAndDropsGoneItems", suite.synchronizeAdoptsNewAndDropsGoneItems),
        ]
    }
}

extension TidyBarControllerTests {
    static var testCases: [TestCase] {
        let suite = TidyBarControllerTests()
        return [
            TestCase("onlyEnabledTriggersReveal", suite.onlyEnabledTriggersReveal),
            TestCase("autoConcealAfterDelay", suite.autoConcealAfterDelay),
            TestCase("searchRanksByMatchQuality", suite.searchRanksByMatchQuality),
            TestCase("demoModeLeavesSystemItemsAlone", suite.demoModeLeavesSystemItemsAlone),
            TestCase("profileSaveAndApply", suite.profileSaveAndApply),
            TestCase("profileListAndDelete", suite.profileListAndDelete),
            TestCase("rulesEvaluatedWithCurrentContext", suite.rulesEvaluatedWithCurrentContext),
            TestCase("rulesAreAppliedThroughController", suite.rulesAreAppliedThroughController),
            TestCase("rulesCanBeDisabledGlobally", suite.rulesCanBeDisabledGlobally),
            TestCase("settingsUpdatesArePersistedAndSanitized", suite.settingsUpdatesArePersistedAndSanitized),
            TestCase("snapshotCallbackFires", suite.snapshotCallbackFires),
        ]
    }
}
