import Foundation
import CoreGraphics
import TidyBarCore

/// M0 验证项 1 的结论固化。这些用例的价值在于：真机测到的坑一旦被写成断言，
/// 以后任何人想把 reader 改回"看起来更聪明"的实现（例如拿 roleDescription 兜底取名）都会被打回。

struct MenuBarItemPolicyTests {
    private let mainScreen = ScreenInfo(
        identifier: 1,
        frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        menuBarHeight: 30,
        notchWidth: nil,
        isBuiltin: false
    )

    func rejectsZeroSizedInvisibleItems() throws {
        // 实测 Control Center 一次报了 37 项，其中 28 项是 0×0
        let rejection = MenuBarItemPolicy.rejection(
            frame: CGRect(x: 0, y: 0, width: 0, height: 0),
            screens: [mainScreen]
        )
        expect(rejection == .zeroSize, "系统报出的不可见项必须拦掉")
    }

    func rejectsPopupElements() throws {
        // 实测 BetterDisplay 把一个 310×346 的弹层混在 extras 子项里
        let rejection = MenuBarItemPolicy.rejection(
            frame: CGRect(x: 1_337, y: 704, width: 310, height: 346),
            screens: [mainScreen]
        )
        expect(rejection != nil, "弹层/窗口不是图标，必须拒绝")
    }

    func acceptsNormalSizedIconInMenuBarBand() throws {
        let rejection = MenuBarItemPolicy.rejection(
            frame: CGRect(x: 776, y: 1_053, width: 34, height: 24),
            screens: [mainScreen]
        )
        expect(rejection == nil, "实测 Raycast 图标的真实尺寸必须通过")
    }

    func acceptsWideClockItem() throws {
        // 实测最宽的合法图标是时钟 146pt（含时间文字），不能按"太宽"误杀
        let rejection = MenuBarItemPolicy.rejection(
            frame: CGRect(x: 1_765, y: 1_054, width: 146, height: 22),
            screens: [mainScreen]
        )
        expect(rejection == nil)
    }

    func secondaryScreenWithNegativeOriginIsNotOffScreen() throws {
        // 实测副屏 frame.origin.y = -384；用主屏框一刀切会把副屏图标全判成越界
        let secondary = ScreenInfo(
            identifier: 2,
            frame: CGRect(x: 1_920, y: -384, width: 1_470, height: 956),
            menuBarHeight: 33,
            notchWidth: 179,
            isBuiltin: true
        )
        let onSecondary = CGRect(x: 2_000, y: 539, width: 24, height: 24)
        expect(
            MenuBarItemPolicy.rejection(frame: onSecondary, screens: [mainScreen, secondary]) == nil,
            "副屏菜单栏上的图标是合法的"
        )
    }

    func rejectsItemBelowMenuBarOnItsOwnScreen() throws {
        let secondary = ScreenInfo(
            identifier: 2,
            frame: CGRect(x: 1_920, y: -384, width: 1_470, height: 956),
            menuBarHeight: 33,
            notchWidth: 179,
            isBuiltin: true
        )
        // 实测 cubox 有一个 y=-24 的残留项：在那块屏上，但远不在菜单栏带内
        let stray = CGRect(x: 7, y: -24, width: 24, height: 26)
        expect(
            MenuBarItemPolicy.rejection(frame: stray, screens: [mainScreen, secondary]) != nil,
            "同屏但不在菜单栏带内的残留项要拒绝"
        )
    }

    func acceptsFoldedOffScreenItems() throws {
        // 物理折叠时，隐藏区域的图标被分隔符推至左侧负坐标（如 x = -1127, y = 1053）
        let foldedItem = CGRect(x: -1_127, y: 1_053, width: 24, height: 24)
        expect(
            MenuBarItemPolicy.rejection(frame: foldedItem, screens: [mainScreen]) == nil,
            "折叠时被推至左侧离屏的菜单栏图标必须保留，不得误杀"
        )
    }
}

struct ScreenCoordinateSpaceTests {
    func cgToAppKitFlipsVerticallyAroundPrimaryHeight() throws {
        // AX 实测：我们的图标 position=(504,3) size=24x24，主屏高 1080
        let axFrame = CGRect(x: 504, y: 3, width: 24, height: 24)
        let appKit = ScreenCoordinateSpace.cgToAppKit(axFrame, primaryScreenHeight: 1_080)
        expectEqual(appKit.minX, 504)
        expectEqual(appKit.minY, 1_053, "顶边 y=3 的图标翻转后应在屏幕最上方一带")
        expectEqual(appKit.height, 24)
    }

    func roundTripIsLossless() throws {
        let original = CGRect(x: 1_234, y: 5, width: 34, height: 24)
        let there = ScreenCoordinateSpace.cgToAppKit(original, primaryScreenHeight: 1_080)
        let back = ScreenCoordinateSpace.appKitToCG(there, primaryScreenHeight: 1_080)
        expectEqual(back, original)
    }

    func menuBarItemsLandInTheMenuBarBand() throws {
        let screen = ScreenInfo(
            identifier: 1,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            menuBarHeight: 30,
            notchWidth: nil,
            isBuiltin: false
        )
        let converted = ScreenCoordinateSpace.cgToAppKit(
            CGRect(x: 776, y: 3, width: 34, height: 24),
            primaryScreenHeight: 1_080
        )
        expect(
            ScreenCoordinateSpace.isWithinMenuBar(converted, screen: screen),
            "换算后的坐标应落进菜单栏带，否则策略会误杀全部图标"
        )
    }
}

struct ItemIdentityTests {
    private func frame(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 1_053, width: 24, height: 24) }

    func namedIdentitySurvivesTitleRewrap() throws {
        let spaced = ManagedItem.stableID(ownerBundleID: "com.test.WeChat", title: "  微信 ")
        let plain = ManagedItem.stableID(ownerBundleID: "com.test.wechat", title: "微信")
        expectEqual(spaced, plain)
    }

    func ordinalIdentityIgnoresTitleText() throws {
        // 序号型身份的名字只是显示用（实测 88% 的图标只能这样识别），
        // 若 App 改了 tooltip 之类导致显示名变化，身份不能跟着变，否则配置错位
        let a = ManagedItem.stableID(
            ownerBundleID: "com.test.app", title: "旧名字",
            identitySource: .ownerOrdinal, ordinalInOwner: 2
        )
        let b = ManagedItem.stableID(
            ownerBundleID: "com.test.app", title: "新名字",
            identitySource: .ownerOrdinal, ordinalInOwner: 2
        )
        expectEqual(a, b)
    }

    func soleItemIsPersistentButMultiItemIsNot() throws {
        let sole = ManagedItem(
            id: "x", ownerBundleID: "com.test.app", title: "App",
            frame: frame(100), identitySource: .ownerOrdinal, ordinalInOwner: 0, ownerItemCount: 1
        )
        expectEqual(sole.identityStrength, .soleItem)
        expect(sole.canPersistAssignment, "单图标进程的序号恒为 0，等价于稳定")

        let multi = ManagedItem(
            id: "y", ownerBundleID: "com.test.app", title: "App",
            frame: frame(100), identitySource: .ownerOrdinal, ordinalInOwner: 1, ownerItemCount: 4
        )
        expectEqual(multi.identityStrength, .positional)
        expect(!multi.canPersistAssignment, "多图标进程只能按位置认领，不得静默持久化")
        expectNotNil(multi.identityStrength.caveat, "这类项必须在设置界面给出提示")
        expectNil(sole.identityStrength.caveat)
    }

    func displayNameFallsBackToOwnerName() throws {
        let discovery = ManagedItem.Discovery(
            ownerBundleID: "com.raycast.macos",
            ownerDisplayName: "Raycast",
            axTitle: "",
            axDescription: nil,
            frame: frame(776),
            isSystemOwned: false,
            identitySource: .ownerOrdinal
        )
        expectEqual(discovery.item.title, "Raycast", "读不到 AXTitle 时退回 App 名，比叫「状态菜单」有用")
    }

    func axTitleWinsOverEverything() throws {
        let discovery = ManagedItem.Discovery(
            ownerBundleID: "local.tidybar.app",
            ownerDisplayName: "TidyBar",
            axTitle: "☰",
            axDescription: "别的名字",
            frame: frame(504),
            isSystemOwned: false,
            identitySource: .axTitle
        )
        expectEqual(discovery.item.title, "☰")
        expectEqual(discovery.item.identityStrength, .named)
    }

    func dedupPreservesIdentityFields() throws {
        // 曾经的真实 bug：去重重建 ManagedItem 时丢了身份字段，
        // 于是"按位置认领"的项被静默升级成命名型身份并被持久化
        let positional = ManagedItem(
            id: "com.test.app.#item0",
            ownerBundleID: "com.test.app",
            title: "App",
            frame: frame(100),
            identitySource: .ownerOrdinal,
            ordinalInOwner: 0,
            ownerItemCount: 3
        )
        let deduped = MenuBarEnumeration.deduplicatedIDs(from: [positional, positional])
        expectEqual(deduped.count, 2)
        expectNotEqual(deduped[0].id, deduped[1].id, "同名项必须可区分")
        for item in deduped {
            expectEqual(item.identitySource, .ownerOrdinal)
            expectEqual(item.ownerItemCount, 3)
            expectEqual(item.identityStrength, .positional)
        }
    }
}

struct EnumerationCadenceTests {
    func firstRefreshAlwaysRuns() throws {
        expect(EnumerationCadence.shouldRefresh(lastRefreshAt: nil, now: Date()))
    }

    /// 冷启动扫描节奏是**实测出来的**，不是拍出来的：
    /// 串行首扫 4.2~13.3s（击穿 2s 预算）、并发 12 是 0.5~0.7s；
    /// 而把单进程超时从 500ms 压到 150ms，同一时刻会静默少 2~3 个图标。
    /// 这两条断言的作用是让"改回串行"或"调短超时换指标"都必须显式改测试。
    func coldScanRhythmIsConcurrentAndBounded() throws {
        let config = AccessibilityMenuBarReader.Config()
        expect(config.processConcurrency >= 8,
               "并发度退回串行/低并发会让冷启动击穿 2s 预算（实测串行 4.2~13.3s）")
        expect(config.processMessagingTimeout >= 0.3 && config.processMessagingTimeout <= 1.0,
               "超时须停在实测不丢图的区间：短于 300ms 会静默丢图标，无上限则一个卡住的 App 就能拖死首扫")
    }

    func refreshIsDebouncedBeyondP95() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let justBelow = now.addingTimeInterval(-0.2)
        let beyond = now.addingTimeInterval(-EnumerationCadence.debounceInterval)
        expect(!EnumerationCadence.shouldRefresh(lastRefreshAt: justBelow, now: now))
        expect(EnumerationCadence.shouldRefresh(lastRefreshAt: beyond, now: now))
    }

    func debounceWindowExceedsMeasuredP95() throws {
        // 实测全量枚举 p95 ≈ 195ms：去抖窗口若小于它，一次图标抖动会引发连环重扫
        let debounceMS = EnumerationCadence.debounceInterval * 1_000
        expect(debounceMS >= EnumerationCadence.measuredSteadyP95Milliseconds)
    }

    func coldStartCannotBeAwaitedSynchronously() throws {
        // 实测冷启动全量扫描 ≈ 2.6s，超过"启动到接管 2s"的预算 → 必须异步首扫
        expect(EnumerationCadence.measuredColdStartMilliseconds > PerformanceBudget.maxColdStartSeconds * 1_000)
    }
}

extension MenuBarItemPolicyTests {
    static var testCases: [TestCase] {
        let suite = MenuBarItemPolicyTests()
        return [
            TestCase("rejectsZeroSizedInvisibleItems", suite.rejectsZeroSizedInvisibleItems),
            TestCase("rejectsPopupElements", suite.rejectsPopupElements),
            TestCase("acceptsNormalSizedIconInMenuBarBand", suite.acceptsNormalSizedIconInMenuBarBand),
            TestCase("acceptsWideClockItem", suite.acceptsWideClockItem),
            TestCase("secondaryScreenWithNegativeOriginIsNotOffScreen", suite.secondaryScreenWithNegativeOriginIsNotOffScreen),
            TestCase("rejectsItemBelowMenuBarOnItsOwnScreen", suite.rejectsItemBelowMenuBarOnItsOwnScreen),
            TestCase("acceptsFoldedOffScreenItems", suite.acceptsFoldedOffScreenItems),
        ]
    }
}

extension ScreenCoordinateSpaceTests {
    static var testCases: [TestCase] {
        let suite = ScreenCoordinateSpaceTests()
        return [
            TestCase("cgToAppKitFlipsVerticallyAroundPrimaryHeight", suite.cgToAppKitFlipsVerticallyAroundPrimaryHeight),
            TestCase("roundTripIsLossless", suite.roundTripIsLossless),
            TestCase("menuBarItemsLandInTheMenuBarBand", suite.menuBarItemsLandInTheMenuBarBand),
        ]
    }
}

extension ItemIdentityTests {
    static var testCases: [TestCase] {
        let suite = ItemIdentityTests()
        return [
            TestCase("namedIdentitySurvivesTitleRewrap", suite.namedIdentitySurvivesTitleRewrap),
            TestCase("ordinalIdentityIgnoresTitleText", suite.ordinalIdentityIgnoresTitleText),
            TestCase("soleItemIsPersistentButMultiItemIsNot", suite.soleItemIsPersistentButMultiItemIsNot),
            TestCase("displayNameFallsBackToOwnerName", suite.displayNameFallsBackToOwnerName),
            TestCase("axTitleWinsOverEverything", suite.axTitleWinsOverEverything),
            TestCase("dedupPreservesIdentityFields", suite.dedupPreservesIdentityFields),
        ]
    }
}

extension EnumerationCadenceTests {
    static var testCases: [TestCase] {
        let suite = EnumerationCadenceTests()
        return [
            TestCase("firstRefreshAlwaysRuns", suite.firstRefreshAlwaysRuns),
            TestCase("refreshIsDebouncedBeyondP95", suite.refreshIsDebouncedBeyondP95),
            TestCase("debounceWindowExceedsMeasuredP95", suite.debounceWindowExceedsMeasuredP95),
            TestCase("coldStartCannotBeAwaitedSynchronously", suite.coldStartCannotBeAwaitedSynchronously),
            TestCase("coldScanRhythmIsConcurrentAndBounded", suite.coldScanRhythmIsConcurrentAndBounded),
        ]
    }
}
