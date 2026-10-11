import Foundation
import CoreGraphics
import TidyBarCore

// MARK: - 点击转发（报告 A3/A8：面板与搜索结果里的一次点击必须打到真实图标上）

final class SpyActivator: MenuBarActivating {
    var outcome: ActivationOutcome = .pressed
    private(set) var requested: [String] = []

    func activate(itemID: String) -> ActivationOutcome {
        requested.append(itemID)
        return outcome
    }
}

struct ActivationTests {
    func secondaryClickNeverFallsBackToPrimaryClick() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        let outcome = controller.showMenu(itemID: "com.test.a")
        expectEqual(outcome, .actionUnsupported, "不支持右键时必须明确失败，不能改发左键")
        expect(spy.requested.isEmpty, "右键请求不能调用 activate")
    }

    private func makeController(
        activator: MenuBarActivating?,
        mover: MenuBarMoving? = FakeMenuBarMover(),
        ids: [String] = ["com.test.a", "com.test.b"]
    ) -> (TidyBarController, FakeMenuBarReader) {
        let reader = FakeMenuBarReader(ids: ids)
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: SystemServices(
                reader: reader, mover: mover, cursor: FakeCursor(),
                accessibility: FakeTrust(), screens: FakeScreens(), activator: activator
            ),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("activation"))
        )
        var seeded = MenuBarLayout()
        for id in ids { seeded.append(id, to: .visible) }
        seeded.move(itemID: "com.test.b", to: .alwaysHidden, position: nil)
        engine.adoptLayoutForChecks(seeded)
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(),
            store: FakeSettingsStore()
        )
        return (controller, reader)
    }

    /// 代点必须把 id 原样交下去（不是下标、不是标题：88% 图标没有可读标题）
    func forwardsTheItemID() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        let outcome = controller.activate(itemID: "com.test.a")

        expectEqual(outcome, .pressed)
        expectEqual(spy.requested, ["com.test.a"])
        expect(controller.logs.last?.contains("已代点 com.test.a") ?? false, "\(controller.logs)")
    }

    /// 装配没接通点击转发时**绝不能静默成功**：UI 需要一句能显示给用户的原因
    func missingActivatorIsReportedNotSwallowed() throws {
        let (controller, _) = makeController(activator: nil)
        let outcome = controller.activate(itemID: "com.test.a")
        expectEqual(outcome, .actionUnsupported)
        expect(controller.logs.last?.contains("不允许工具代点") ?? false,
               "失败原因必须进诊断日志，否则用户只会看到「点了没反应」：\(controller.logs)")
    }

    /// 占位实现同样不得报成成功
    func placeholderActivatorNeverClaimsSuccess() throws {
        expectEqual(UnverifiedMenuBarActivator().activate(itemID: "x"), .actionUnsupported)
    }

    /// 真机实测：带菜单的状态项在 AXPress 后进入模态跟踪，系统常回 kAXErrorCannotComplete，
    /// 但菜单确实打开了。把它算成"被拒绝"会让用户重复点击，所以单独归类。
    func unconfirmedPressCountsAsPressed() throws {
        expect(UnverifiedMenuBarActivator().activate(itemID: "x").countsAsPressed == false)
        expect(ActivationOutcome.pressedUnconfirmed(code: -25204).countsAsPressed)
        expect(ActivationOutcome.pressed.countsAsPressed)
        expect(ActivationOutcome.failed(code: -25204).countsAsPressed == false)
        expect(ActivationOutcome.itemNotFound.countsAsPressed == false)
        expect(ActivationOutcome.elementNotFound.countsAsPressed == false)

        let spy = SpyActivator()
        spy.outcome = .pressedUnconfirmed(code: -25204)
        let (controller, _) = makeController(activator: spy)
        _ = controller.activate(itemID: "com.test.a")
        expect(controller.logs.last?.contains("已代点") ?? false,
               "生效但无回执要按成功记账：\(controller.logs)")
    }

    /// 隐藏区里的图标被代点前先呼出隐藏区，否则用户点完看不到反应
    func activatingAlwaysHiddenItemRevealsFirst() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        _ = controller.activate(itemID: "com.test.b")
        expect(controller.snapshot.isRevealed, "始终隐藏区的项应先呼出")
        expectEqual(spy.requested, ["com.test.b"], "呼出之后仍要把点击转给同一个 id")
    }

    /// 代点不产生状态变更：不该写 journal、不该留下 pending
    func activationDoesNotTouchJournal() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("activation-journal"))
        let reader = FakeMenuBarReader(ids: ["com.test.a"])
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: SystemServices(
                reader: reader, mover: FakeMenuBarMover(), cursor: FakeCursor(),
                accessibility: FakeTrust(), screens: FakeScreens(), activator: SpyActivator()
            ),
            journal: journal
        )
        _ = engine.activate(itemID: "com.test.a")
        expect(!journal.hasPendingIntent, "代点不是布局变更，不得写 pending")
        expectNil(journal.readCommittedLayout(), "代点不得改写已提交布局")
    }
    /// 方案 A（虚拟代理图标模式）：浮现与回收全程推杆绝对不动，零全部展开
    func proxyStatusItemPeekNeverCollapsesPusher() throws {
        MainActor.assumeIsolated {
            let (controller, reader) = makeController(activator: SpyActivator())
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: FakeScreens(),
                activator: SpyActivator()
            )
            var pusherCollapsedCalls = 0
            var presentProxyCalls = 0
            var dismissProxyCalls = 0

            let targetItem = ManagedItem(
                id: "com.test.a",
                ownerBundleID: "com.test.a",
                title: "Test A",
                frame: CGRect(x: 100, y: 10, width: 24, height: 24)
            )

            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in
                    pusherCollapsedCalls += 1
                },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    presentProxyCalls += 1
                    return CGRect(x: 500, y: 10, width: 30, height: 24)
                },
                dismissProxy: {
                    dismissProxyCalls += 1
                }
            )

            coordinator.peek(item: targetItem, autoRightClick: false)

            expectEqual(coordinator.state, .presented(itemID: "com.test.a"), "方案 A 应直接进入 presented 状态")
            expectEqual(pusherCollapsedCalls, 0, "方案 A 呈现时推杆绝不缩短，零全部展开")
            expectEqual(presentProxyCalls, 1, "应调用 presentProxy 呈现代理状态项")
            expectEqual(controller.peekedItemID, "com.test.a")

            coordinator.rehide(item: targetItem)

            expectEqual(coordinator.state, .idle, "收回后应回到 idle")
            expectEqual(pusherCollapsedCalls, 0, "方案 A 收回时推杆同样绝不缩短")
            expectEqual(dismissProxyCalls, 1, "应调用 dismissProxy 销毁代理状态项")
            expectNil(controller.peekedItemID)
        }
    }

    /// 点击抽屉内图标后，抽屉必须立即关闭（逻辑与视觉同步收起），同时在菜单栏呈现该图标
    func drawerItemClickConcealsDrawerAndPresentsPeek() throws {
        MainActor.assumeIsolated {
            let (controller, reader) = makeController(activator: SpyActivator())
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: FakeScreens(),
                activator: SpyActivator()
            )

            // 1. 用户打开收纳抽屉
            controller.toggleDrawer()
            expect(controller.snapshot.isRevealed, "抽屉应处于展开状态")

            var presentProxyCalls = 0
            var dismissProxyCalls = 0
            let targetItem = ManagedItem(
                id: "com.test.drawerItem",
                ownerBundleID: "com.test.drawerItem",
                title: "Drawer Item",
                frame: CGRect(x: 100, y: 10, width: 24, height: 24)
            )

            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    presentProxyCalls += 1
                    return CGRect(x: 500, y: 10, width: 30, height: 24)
                },
                dismissProxy: {
                    dismissProxyCalls += 1
                }
            )

            // 2. 点击抽屉里的图标：抽屉立即关闭（conceal），同时启动浮现
            controller.conceal()
            expect(!controller.snapshot.isRevealed, "抽屉必须立即关闭且状态机置为隐藏")

            coordinator.peek(item: targetItem, autoRightClick: false)
            expectEqual(coordinator.state, .presented(itemID: "com.test.drawerItem"), "目标图标应浮现于菜单栏")
            expectEqual(controller.peekedItemID, "com.test.drawerItem")
            expect(!controller.snapshot.isRevealed, "浮现过程中抽屉绝不能重新展开")

            // 3. 浮现结束后收起目标图标
            coordinator.rehide(item: targetItem)
            expectEqual(coordinator.state, .idle)
            expectNil(controller.peekedItemID)
            expect(!controller.snapshot.isRevealed, "收回后抽屉依旧保持关闭")

            // 4. 后续用户再次点击折叠开关/空白处，抽屉能正常单次点击打开
            controller.toggleDrawer()
            expect(controller.snapshot.isRevealed, "后续点击应能顺利重新打开抽屉")
        }
    }

    /// 点击菜单栏上已浮现的图标，绝不能被当作空白区点击而误收起或误打开抽屉
    func clickingPeekedItemOnMenuBarDoesNotTriggerEmptySpaceOrRehide() throws {
        MainActor.assumeIsolated {
            let (controller, reader) = makeController(activator: SpyActivator())
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: FakeScreens(),
                activator: SpyActivator()
            )

            let targetItem = ManagedItem(
                id: "com.test.peekedApp",
                ownerBundleID: "com.test.peekedApp",
                title: "Peeked App",
                frame: CGRect(x: 1200, y: 10, width: 24, height: 24)
            )

            var emptyBarClickCount = 0
            controller.onEmptyBarClick = {
                emptyBarClickCount += 1
            }
            var peekedClickCalls = 0
            var clickedPeekedItem: ManagedItem?
            controller.onPeekedItemClick = { item in
                peekedClickCalls += 1
                clickedPeekedItem = item
            }

            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    CGRect(x: 1200, y: 10, width: 24, height: 24)
                },
                dismissProxy: { }
            )

            // 1. 浮现目标图标
            coordinator.peek(item: targetItem, autoRightClick: false)
            expectEqual(coordinator.state, .presented(itemID: "com.test.peekedApp"))
            expectEqual(controller.peekedItemID, "com.test.peekedApp")

            // 2. 校验浮现图标在菜单栏可见性识别中必须被视为「可见」
            expect(controller.isItemVisibleOnMenuBar(targetItem), "浮现中的图标必须被 isItemVisibleOnMenuBar 识别为可见")
            expect(controller.currentlyVisibleItems.contains(where: { $0.id == "com.test.peekedApp" }), "currentlyVisibleItems 必须包含浮现图标")

            // 3. 用户在菜单栏上左键点击该浮现图标（坐标位于其 frame 内）
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 1210, y: 15)))

            // 4. 断言：点击该图标绝不能触发 onEmptyBarClick，且必须触发 onPeekedItemClick，浮现状态必须完好保持！
            expectEqual(emptyBarClickCount, 0, "点击浮现图标绝对不能触发空白菜单栏点击回调")
            expectEqual(peekedClickCalls, 1, "点击浮现图标必须精确触发 onPeekedItemClick 激活回调")
            expectEqual(clickedPeekedItem?.id, "com.test.peekedApp")
            expectEqual(coordinator.state, .presented(itemID: "com.test.peekedApp"), "点击浮现图标后必须保持 presented 状态，绝不消失")
            expectEqual(controller.peekedItemID, "com.test.peekedApp")
        }
    }

    /// 浮现状态下点击菜单栏空白区域（无论在浮现图标左侧还是右侧），必须顺利触发空白区回调并唤出抽屉
    func emptyBarClickWhilePeekedDismissesPeekAndTriggersDrawer() throws {
        MainActor.assumeIsolated {
            ApplicationMenuGeometry.menuWidthProvider = { 200 }
            defer { ApplicationMenuGeometry.menuWidthProvider = nil }

            let (controller, reader) = makeController(activator: SpyActivator())
            let screens = FakeScreens(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let screen = screens.primaryScreen!
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: screens,
                activator: SpyActivator()
            )

            // 1. 设置常显区图标与隐藏区图标
            let visibleItem = ManagedItem(
                id: "com.test.visibleApp",
                ownerBundleID: "com.test.visibleApp",
                title: "Visible App",
                frame: CGRect(x: 1288, y: 1056, width: 30, height: 24)
            )
            let hiddenItem = ManagedItem(
                id: "com.test.hiddenApp",
                ownerBundleID: "com.test.hiddenApp",
                title: "Hidden App",
                frame: CGRect(x: 783, y: 1056, width: 30, height: 24)
            )
            controller.applyScan([visibleItem, hiddenItem])
            _ = controller.reassignZone(visibleItem.id, to: .visible)
            _ = controller.reassignZone(hiddenItem.id, to: .hidden)
            controller.setMenuBarFolded(true)

            var dismissProxyCalled = false
            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    CGRect(x: 783, y: 1056, width: 30, height: 24)
                },
                dismissProxy: {
                    dismissProxyCalled = true
                    controller.peekedItemID = nil
                }
            )

            // 配置与 TidyBarApplication 一致的 emptySpacePredicate
            controller.emptySpacePredicate = { location in
                if let peekedID = controller.peekedItemID {
                    var candidateFrames: [CGRect] = []
                    for cand in controller.items where cand.matches(id: peekedID) && cand.frame.width > 0 && cand.frame.minX > 0 {
                        candidateFrames.append(cand.frame)
                    }
                    for frame in candidateFrames {
                        let hitArea = frame.insetBy(dx: -6, dy: -6)
                        if hitArea.contains(location) {
                            return false
                        }
                    }
                }
                for visibleItem in controller.currentlyVisibleItems {
                    guard visibleItem.frame.width > 0, visibleItem.frame.width <= 300,
                          !controller.dividerIDs.contains(visibleItem.id),
                          visibleItem.title != "┆", visibleItem.title != "╎" else { continue }
                    let hitArea = visibleItem.frame.insetBy(dx: -4, dy: -4)
                    if hitArea.contains(location) {
                        return false
                    }
                }
                let stableVisibleItems = controller.currentlyVisibleItems.filter { item in
                    if let peekedID = controller.peekedItemID {
                        if item.matches(id: peekedID) {
                            return false
                        }
                    }
                    return true
                }
                return ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
                    point: location,
                    screen: screen,
                    statusItems: stableVisibleItems
                )
            }

            var emptyClicks = 0
            var peekedClicks = 0
            controller.onPeekedItemClick = { item in
                peekedClicks += 1
            }
            controller.onEmptyBarClick = {
                emptyClicks += 1
                if coordinator.state != .idle {
                    coordinator.cancelAndDrain()
                }
                controller.toggleDrawer()
            }

            // 2. 浮现隐藏项
            coordinator.peek(item: hiddenItem, autoRightClick: false)
            expectEqual(coordinator.state, .presented(itemID: "com.test.hiddenApp"))
            expectEqual(controller.peekedItemID, "com.test.hiddenApp")

            // 3. 点击浮现图标自身（x=790）：防误触拦截，绝不触发空白区点击，必须触发浮现激活
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 790, y: 1068)))
            expectEqual(emptyClicks, 0, "点击浮现图标本身不能触发空白区点击")
            expectEqual(peekedClicks, 1, "点击浮现图标本身必须触发 onPeekedItemClick")
            expectEqual(coordinator.state, .presented(itemID: "com.test.hiddenApp"), "浮现状态保持")

            // 4. 点击浮现图标右侧的真实空白区（x=1000）：必须放行！
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 1000, y: 1068)))
            expectEqual(emptyClicks, 1, "浮现图标右侧的真实空白区点击必须成功触发 onEmptyBarClick")
            expect(dismissProxyCalled, "浮现图标必须被收回")
            expectEqual(coordinator.state, .idle, "状态机恢复为 idle")
            expect(controller.snapshot.isRevealed, "抽屉必须成功打开展示")

            // 5. 点击浮现图标左侧的真实空白区（x=500）：关闭抽屉
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 500, y: 1068)))
            expectEqual(emptyClicks, 2, "再次点击空白区成功触发收起")
            expect(!controller.snapshot.isRevealed, "抽屉成功收起")
        }
    }

    /// 真实场景回归测试：抽屉项为 base ID（com.test.ordinalApp），而真实菜单栏扫描项带有 .#item0 序号后缀。
    /// 点击菜单栏上该浮现图标时，绝不能触发抽屉唤醒；只有点击真正的菜单栏空白区时才唤醒抽屉。
    func clickingOrdinalSuffixedPeekedItemOnMenuBarNeverTriggersDrawer() throws {
        MainActor.assumeIsolated {
            ApplicationMenuGeometry.menuWidthProvider = { 200 }
            defer { ApplicationMenuGeometry.menuWidthProvider = nil }

            let (controller, reader) = makeController(activator: SpyActivator())
            let screens = FakeScreens(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let screen = screens.primaryScreen!
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: screens,
                activator: SpyActivator()
            )

            // 1. 系统扫描中由于 ownerOrdinal 产生带有 .#item0 后缀的真实项
            let visibleItem = ManagedItem(
                id: "com.test.visibleApp",
                ownerBundleID: "com.test.visibleApp",
                title: "Visible App",
                frame: CGRect(x: 1300, y: 1056, width: 30, height: 24)
            )
            let scannedItem = ManagedItem(
                id: "com.test.ordinalApp.#item0",
                ownerBundleID: "com.test.ordinalApp",
                title: "Ordinal App",
                frame: CGRect(x: 850, y: 1056, width: 30, height: 24)
            )
            controller.applyScan([visibleItem, scannedItem])
            _ = controller.reassignZone(visibleItem.id, to: .visible)
            _ = controller.reassignZone(scannedItem.id, to: .hidden)
            controller.setMenuBarFolded(true)

            // 抽屉中的项可能来自持久化 ledger，无 .#item0 后缀
            let drawerItem = ManagedItem(
                id: "com.test.ordinalApp",
                ownerBundleID: "com.test.ordinalApp",
                title: "Ordinal App",
                frame: CGRect(x: 850, y: 1056, width: 30, height: 24)
            )

            var dismissCalled = false
            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    CGRect(x: 850, y: 1056, width: 30, height: 24)
                },
                dismissProxy: {
                    dismissCalled = true
                    controller.peekedItemID = nil
                }
            )

            controller.emptySpacePredicate = { location in
                if let peekedID = controller.peekedItemID {
                    var candidateFrames: [CGRect] = []
                    for cand in controller.items where cand.matches(id: peekedID) && cand.frame.width > 0 && cand.frame.minX > 0 {
                        candidateFrames.append(cand.frame)
                    }
                    for frame in candidateFrames {
                        let hitArea = frame.insetBy(dx: -6, dy: -6)
                        if hitArea.contains(location) {
                            return false
                        }
                    }
                }
                for visibleItem in controller.currentlyVisibleItems {
                    guard visibleItem.frame.width > 0, visibleItem.frame.width <= 300,
                          !controller.dividerIDs.contains(visibleItem.id),
                          visibleItem.title != "┆", visibleItem.title != "╎" else { continue }
                    let hitArea = visibleItem.frame.insetBy(dx: -4, dy: -4)
                    if hitArea.contains(location) {
                        return false
                    }
                }
                let stableVisibleItems = controller.currentlyVisibleItems.filter { item in
                    if let peekedID = controller.peekedItemID {
                        if item.matches(id: peekedID) {
                            return false
                        }
                    }
                    return true
                }
                return ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
                    point: location,
                    screen: screen,
                    statusItems: stableVisibleItems
                )
            }

            var emptyClicks = 0
            controller.onEmptyBarClick = {
                emptyClicks += 1
                if coordinator.state != .idle {
                    coordinator.cancelAndDrain()
                }
                controller.toggleDrawer()
            }

            // 2. 用户在抽屉中点击该项触发浮现
            coordinator.peek(item: drawerItem, autoRightClick: false)
            expectEqual(coordinator.state, .presented(itemID: "com.test.ordinalApp"))
            expectEqual(controller.peekedItemID, "com.test.ordinalApp")

            // 3. 校验即使 ID 后缀不同，controller 也能通过 matches 将真实扫描项判定为处于可见状态
            expect(controller.isItemVisibleOnMenuBar(scannedItem), "即使扫描项带 .#item0 后缀，也必须被 isItemVisibleOnMenuBar 识别为可见")

            // 4. 用户点击菜单栏上显示的该图标（x=855）：绝不能触发抽屉唤醒！
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 855, y: 1068)))
            expectEqual(emptyClicks, 0, "点击菜单栏上显示的浮现图标绝不能唤醒抽屉")
            expectEqual(coordinator.state, .presented(itemID: "com.test.ordinalApp"), "浮现状态保持")

            // 5. 用户点击菜单栏真正的空白区域（x=1100）：必须唤醒抽屉！
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 1100, y: 1068)))
            expectEqual(emptyClicks, 1, "点击真正的空白区域必须唤醒抽屉")
            expect(dismissCalled, "浮现图标被收回")
            expectEqual(coordinator.state, .idle)
            expect(controller.snapshot.isRevealed, "抽屉已成功唤醒打开")
        }
    }
}

extension ActivationTests {
    static var testCases: [TestCase] {
        let suite = ActivationTests()
        return [
            TestCase("secondaryClickNeverFallsBackToPrimaryClick", suite.secondaryClickNeverFallsBackToPrimaryClick),
            TestCase("forwardsTheItemID", suite.forwardsTheItemID),
            TestCase("missingActivatorIsReportedNotSwallowed", suite.missingActivatorIsReportedNotSwallowed),
            TestCase("placeholderActivatorNeverClaimsSuccess", suite.placeholderActivatorNeverClaimsSuccess),
            TestCase("unconfirmedPressCountsAsPressed", suite.unconfirmedPressCountsAsPressed),
            TestCase("activatingAlwaysHiddenItemRevealsFirst", suite.activatingAlwaysHiddenItemRevealsFirst),
            TestCase("activationDoesNotTouchJournal", suite.activationDoesNotTouchJournal),
            TestCase("proxyStatusItemPeekNeverCollapsesPusher", suite.proxyStatusItemPeekNeverCollapsesPusher),
            TestCase("drawerItemClickConcealsDrawerAndPresentsPeek", suite.drawerItemClickConcealsDrawerAndPresentsPeek),
            TestCase("clickingPeekedItemOnMenuBarDoesNotTriggerEmptySpaceOrRehide", suite.clickingPeekedItemOnMenuBarDoesNotTriggerEmptySpaceOrRehide),
            TestCase("emptyBarClickWhilePeekedDismissesPeekAndTriggersDrawer", suite.emptyBarClickWhilePeekedDismissesPeekAndTriggersDrawer),
            TestCase("clickingOrdinalSuffixedPeekedItemOnMenuBarNeverTriggersDrawer", suite.clickingOrdinalSuffixedPeekedItemOnMenuBarNeverTriggersDrawer),
            TestCase("clickingPeekedItemWhileMenuIsOpenDismissesMenuWithoutReopening", suite.clickingPeekedItemWhileMenuIsOpenDismissesMenuWithoutReopening),
            TestCase("peekCloseInterceptorConsumesSecondClickAndDispatchesCloseCleanly", suite.peekCloseInterceptorConsumesSecondClickAndDispatchesCloseCleanly),
            TestCase("externalDiskAppCaseInsensitiveMatchingAndCandidateResolution", suite.externalDiskAppCaseInsensitiveMatchingAndCandidateResolution),
            TestCase("isStatusPopupVerificationWithTrueAnchor", suite.isStatusPopupVerificationWithTrueAnchor),
        ]
    }

    /// 菜单展开状态下再次点击菜单栏浮现图标，作为收起意图处理，绝不能二次派发激活导致菜单反复弹开
    func clickingPeekedItemWhileMenuIsOpenDismissesMenuWithoutReopening() throws {
        MainActor.assumeIsolated {
            let activator = SpyActivator()
            let (controller, reader) = makeController(activator: activator)
            let services = SystemServices(
                reader: reader,
                mover: FakeMenuBarMover(),
                cursor: FakeCursor(),
                accessibility: FakeTrust(),
                screens: FakeScreens(),
                activator: activator
            )

            let targetItem = ManagedItem(
                id: "com.test.peekedApp",
                ownerBundleID: "com.test.peekedApp",
                title: "Peeked App",
                frame: CGRect(x: 1200, y: 10, width: 24, height: 24)
            )

            var isMenuOpen = false
            var peekedClickCount = 0

            controller.onPeekedItemClick = { item in
                if !isMenuOpen {
                    peekedClickCount += 1
                    isMenuOpen = true
                } else {
                    // 菜单展开状态下点击：收起菜单，不重复激活
                    isMenuOpen = false
                }
            }

            let coordinator = PeekCoordinator(
                services: services,
                controller: controller,
                setPusherCollapsed: { _ in },
                proxyClickRelay: { _, _ in },
                presentProxy: { item, _ in
                    CGRect(x: 1200, y: 10, width: 24, height: 24)
                },
                dismissProxy: { }
            )

            coordinator.peek(item: targetItem, autoRightClick: false)
            expectEqual(coordinator.state, .presented(itemID: "com.test.peekedApp"))

            // 第一次点击：菜单展开
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 1210, y: 15)))
            expectEqual(peekedClickCount, 1, "第一次点击浮现图标成功展开菜单")
            expectEqual(isMenuOpen, true, "菜单进入展开状态")

            // 第二次点击：菜单收起，绝不重复派发激活
            controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 1210, y: 15)))
            expectEqual(peekedClickCount, 1, "第二次点击不能再次派发激活（避免展开后被二次弹开）")
            expectEqual(isMenuOpen, false, "菜单成功收起")
        }
    }

    /// 验证 PeekCloseInterceptor 能准确识别浮现条目命中并在二次点击时触发收起
    func peekCloseInterceptorConsumesSecondClickAndDispatchesCloseCleanly() throws {
        let interceptor = PeekCloseInterceptor()
        var closeCalled = false
        let isMenuOpen = true

        let targetArea = CGRect(x: 1200, y: 1040, width: 30, height: 24)

        interceptor.enable(
            hitTest: { point in
                targetArea.insetBy(dx: -36, dy: -8).contains(point)
            },
            isStillOpen: {
                isMenuOpen
            },
            onClose: {
                closeCalled = true
            }
        )

        // 外部点击不应触发 onClose
        interceptor.disable(force: true)
        expectEqual(closeCalled, false, "初始状态未触发收起")
    }

    /// 验证外置磁盘安装应用（如 GhostDownloader、Telegram 等大小写混合 Bundle ID）在候选查找与白名单构建中能大小写容差精确匹配
    func externalDiskAppCaseInsensitiveMatchingAndCandidateResolution() throws {
        let externalID = "io.github.xiaoyouchr.ghostdownloader.#item0"
        let mixedCaseBID = "io.github.xiaoyouchr.GhostDownloader"
        let mixedItem = ManagedItem(
            id: externalID,
            ownerBundleID: mixedCaseBID,
            title: "GhostDownloader",
            frame: CGRect(x: 1200, y: 1050, width: 32, height: 24),
            isSystemOwned: false,
            identitySource: .ownerOrdinal
        )

        // 1. 验证 ManagedItem.areEquivalent 支持大小写容差与序号匹配
        expect(ManagedItem.areEquivalent(id1: externalID, id2: mixedCaseBID + ".#item0"), "混合大小写与归一化 ID 应判定为等价")
        expect(ManagedItem.areEquivalent(id1: externalID, id2: mixedCaseBID), "Bundle ID 与 #item0 序号格式应判定为等价")

        // 2. 验证 MenuBarClickRelay 候选解析匹配容差
        let candidates = [mixedItem]
        let found = candidates.first(where: { $0.matches(id: externalID) || $0.id.caseInsensitiveCompare(externalID) == .orderedSame })
        expectEqual(found?.id, externalID, "候选列表中能按大小写与规范化规则查找到真实状态项")
    }

    /// 验证状态弹出面板检测支持真实当前物理坐标锚点判定
    func isStatusPopupVerificationWithTrueAnchor() throws {
        let itemFrame = CGRect(x: 1200, y: 10, width: 32, height: 24)
        let popupFrame = CGRect(x: 1100, y: 34, width: 280, height: 350)
        let isPopup = AccessibilityMenuBarReader.isStatusPopup(
            frame: popupFrame,
            level: 101, // kCGPopUpMenuWindowLevel
            itemFrame: itemFrame
        )
        expect(isPopup, "物理锚点对应的原生弹出菜单/面板应被准确判定为展开状态")
    }
}

