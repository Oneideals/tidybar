import Foundation
import CoreGraphics
import TidyBarCore

struct MenuBarArrangementTests {
    private let controls = DividerGeometry.Controls(leftDivider: "left", rightDivider: "right", toggle: "toggle")
    private let screen = ScreenInfo(identifier: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 1200),
                                    menuBarHeight: 24, notchWidth: nil, isBuiltin: false)
    private var layout: MenuBarLayout { MenuBarLayout(zones: ["hidden": ["hidden"], "visible": ["visible"]]) }
    private var before: [ManagedItem] {
        [TestItems.item("left", centerX: 100), TestItems.item("hidden", centerX: 200),
         TestItems.item("toggle", centerX: 300), TestItems.item("right", centerX: 400),
         TestItems.item("visible", centerX: 500), TestItems.item("clock", centerX: 700, isSystemOwned: true)]
    }
    private var after: [ManagedItem] {
        [TestItems.item("left", centerX: 100), TestItems.item("hidden", centerX: 200),
         TestItems.item("right", centerX: 300), TestItems.item("toggle", centerX: 400),
         TestItems.item("visible", centerX: 500), TestItems.item("clock", centerX: 700, isSystemOwned: true)]
    }

    func foldingKeepsZoneOrderAndExcludesSystemProxies() throws {
        var physical = after
        physical.insert(TestItems.item("second-hidden", centerX: 250), at: 2)
        let visible = TestItems.item("surge", centerX: 1673, centerY: 1065, side: 24)
        let proxy = ManagedItem(id: "proxy", ownerBundleID: "com.apple.controlcenter", title: "Control Center",
                                frame: CGRect(x: 1631, y: 1050, width: 84, height: 30), isSystemOwned: true)
        physical += [visible, proxy]
        let saved = MenuBarLayout(zones: ["hidden": ["second-hidden", "hidden", "clock"], "visible": ["visible", "surge"]])
        expectEqual(DividerGeometry.foldingOrder(items: physical, layout: saved, controls: controls),
                    ["left", "hidden", "second-hidden", "right", "toggle", "visible", "clock", "surge"])
        expect(DividerGeometry.isCorrectlyPartitioned(items: physical, layout: saved, controls: controls),
               "同区次序不同、系统旧分区与重复代理不能否定已经正确的隐藏边界")
        expect(!DividerGeometry.physicalItems(physical).contains { $0.id == "proxy" })
        expect(DividerGeometry.physicalItems(physical).contains { $0.id == "clock" })
        expectEqual(DividerGeometry.arrangementOrder(items: physical, layout: saved,
                    leftDivider: "left", rightDivider: "right", toggle: "toggle").prefix(3).map { $0 },
                    ["left", "second-hidden", "hidden"], "显式档案排序仍沿用已保存的顺序")
    }

    func explicitReorderIgnoresSystemProxySlots() throws {
        let own = Bundle.main.bundleIdentifier ?? "local.tidybar.app"
        var observed = after.map { item in
            controls.ids.contains(item.id)
                ? ManagedItem(id: item.id, ownerBundleID: own, title: item.title, frame: item.frame) : item
        }
        observed += [TestItems.item("surge", centerX: 600),
                     ManagedItem(id: "proxy", ownerBundleID: "com.apple.controlcenter", title: "proxy",
                                 frame: CGRect(x: 560, y: 1173, width: 80, height: 30), isSystemOwned: true)]
        let reader = FakeMenuBarReader(items: observed)
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["hidden": ["hidden"], "visible": ["visible", "surge", "clock"]]),
                                  services: makeServices(reader: reader, mover: mover),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("proxy-reorder")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan(observed)
        controller.dividerIDs = ["left", "right"]
        controller.dividerCenters = (100, 300)
        expect(controller.reassignZone("visible", to: .visible, position: 1))
        expectEqual(mover.moved.first?.x, 614, "落点必须是 Surge 的真实右缘，不能是 Control Center 代理帧右缘")
    }

    // 假件通过信号量与完成回调交接，重现目标状态项必须由主线程消费事件的情况。
    private final class MainLoopMover: MenuBarMoving, @unchecked Sendable {
        let reader: FakeMenuBarReader
        let result: [ManagedItem]
        var didUseWorker = false
        var didHandleOnMain = false
        init(reader: FakeMenuBarReader, result: [ManagedItem]) { self.reader = reader; self.result = result }
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            didUseWorker = !Thread.isMainThread
            guard didUseWorker else { throw MenuBarMoveError.dragInterrupted }
            let consumed = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                self.didHandleOnMain = true
                self.reader.items = self.result
                consumed.signal()
            }
            guard consumed.wait(timeout: .now() + 3) == .success else { throw MenuBarMoveError.dragInterrupted }
            return CGPoint(x: x, y: 1188)
        }
    }

    @MainActor private func pump(until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    func arrangementLeavesTheTargetMainLoopAvailable() throws {
        MainActor.assumeIsolated {
            let reader = FakeMenuBarReader(items: before)
            let mover = MainLoopMover(reader: reader, result: after)
            let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
            var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
            expect(operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                   defaultZone: .hidden, screens: [screen]) { outcome = $0 })
            expect(operation.isRunning)
            expect(pump { outcome != nil }, "后台投递期间主线程必须能处理状态项的布局更新")
            if case .success = outcome {} else { expect(false, "整理应成功：\(String(describing: outcome))") }
            expect(mover.didUseWorker && mover.didHandleOnMain)
            expect(!operation.isRunning)
        }
    }

    private final class PausedMover: MenuBarMoving, DragReleasing, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        private var moving = false
        var isDragInFlight = false
        var releaseDuringMove = false
        var releaseCount = 0
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            moving = true
            isDragInFlight = true
            entered.signal()
            _ = finish.wait(timeout: .now() + 2)
            moving = false
            return CGPoint(x: x, y: 1188)
        }
        func releaseInFlightDrag() {
            releaseDuringMove = moving
            isDragInFlight = false
            releaseCount += 1
        }
    }

    func cancellationDrainsInputBeforeCompleting() throws {
        MainActor.assumeIsolated {
            let mover = PausedMover()
            let operation = MenuBarArrangement(reader: FakeMenuBarReader(items: before), mover: mover, cursor: FakeCursor())
            var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
            var drained = false
            expect(operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                   defaultZone: .hidden, screens: [screen]) { outcome = $0 })
            expectEqual(mover.entered.wait(timeout: .now() + 1), .success)
            expect(!operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                    defaultZone: .hidden, screens: [screen]) { _ in }, "不能同时开启第二条输入序列")
            operation.cancelAndDrain { drained = true }
            expect(!drained, "不能在后台仍投递输入时提前完成退出")
            mover.finish.signal()
            expect(pump { drained && outcome != nil })
            if case .failure(.cancelled) = outcome {} else { expect(false, "取消后不能报告整理成功") }
            expect(!mover.releaseDuringMove)
            expectEqual(mover.releaseCount, 1)
            expect(!mover.isDragInFlight && !operation.isRunning)
        }
    }

    func arrangementResultRefreshesFramesWithoutReleasingTheBusyGuard() throws {
        let before = TestItems.item("hidden", centerX: -1400)
        let after = TestItems.item("hidden", centerX: 600)
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("arrangement-capture-snapshot"))
        let layout = MenuBarLayout(zones: ["hidden": [before.id]])
        try journal.writeCommitted(layout)
        let engine = LayoutEngine(layout: layout, services: makeServices(mover: nil), journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan([before])
        controller.setPhysicalLayoutBusy(true)
        controller.acceptArrangementResult([after])
        expect(controller.isPhysicalLayoutBusy, "预热结束前不能开放另一条物理移动路径")
        expectEqual(controller.drawerItems.first?.frame, after.frame, "预热必须获得整理后的可见帧，不能继续用折叠坐标")
        expect(!controller.reassignZone(before.id, to: .visible))
        controller.applyScan([before])
        expectEqual(controller.drawerItems.first?.frame, after.frame, "旧的后台扫描在忙碌期间仍须拒绝")
        expectEqual(journal.readCommittedLayout(), layout, "接受物理结果不改变用户分配")
        controller.setPhysicalLayoutBusy(false)
        controller.acceptArrangementResult([before])
        expectEqual(controller.drawerItems.first?.frame, after.frame, "会话已完成后不可接受过期的整理结果")
    }

    func controllerRejectsConflictingOperationsWhileArranging() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("arrangement-busy"))
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a"]]),
                                  services: makeServices(mover: nil), journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan([TestItems.item("a")])
        controller.setPhysicalLayoutBusy(true)
        expect(!controller.reassignZone("a", to: .hidden))
        controller.applyScan([TestItems.item("b")])
        expectEqual(controller.snapshot.items.map(\.id), ["a"])
        expectEqual(engine.layout.zone(of: "a"), .visible)
        expect(!journal.hasPendingIntent)
        expectEqual(controller.activate(itemID: "a"), .busy)
        expectEqual(controller.showMenu(itemID: "a"), .busy)
        controller.setPhysicalLayoutBusy(false)
        expect(controller.reassignZone("a", to: .hidden))
        expectEqual(journal.readCommittedLayout()?.zone(of: "a"), .hidden)
    }

    func crossScreenItemsNeverEnterTheSameArrangement() throws {
        MainActor.assumeIsolated {
            // 高低不同和顶边相同的副屏都不能混入主屏 x 序列。
            for height: CGFloat in [600, 1200] {
                let second = ScreenInfo(identifier: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: height),
                                        menuBarHeight: 24, notchWidth: nil, isBuiltin: false)
                var observed = before
                observed[1] = TestItems.item("hidden", centerX: 2000, centerY: height - 12)
                let mover = FakeMenuBarMover()
                let operation = MenuBarArrangement(reader: FakeMenuBarReader(items: observed), mover: mover, cursor: FakeCursor())
                var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
                expect(operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                       defaultZone: .hidden, screens: [screen, second]) { outcome = $0 })
                expect(pump { outcome != nil })
                if case .failure(.unsupportedDisplayLayout) = outcome {} else { expect(false, "必须明确拒绝跨菜单栏排序") }
                expect(mover.moved.isEmpty, "跨屏项目不能触发任何移动")
            }
        }
    }

    func settlingItemsSettleBeforeArrangement() throws {
        MainActor.assumeIsolated {
            // 折叠状态下处于负 x 坐标的图标，在恢复整理时应等待其归位，而不是直接报跨屏错误
            var displaced = before
            displaced[1] = TestItems.item("hidden", centerX: -200) // 处于左侧负坐标
            let settled = before
            let reader = FakeMenuBarReader(items: displaced)
            let mover = MainLoopMover(reader: reader, result: after)
            let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
            var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
            expect(operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                   defaultZone: .hidden, screens: [screen]) { outcome = $0 })
            // 模拟 50ms 后系统完成了坐标归位
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                reader.items = settled
            }
            expect(pump { outcome != nil })
            if case .success = outcome {} else { expect(false, "处于折叠负坐标的图标在归位后应成功整理：\(String(describing: outcome))") }
        }
    }

    private final class PartialMover: MenuBarMoving {
        let reader: FakeMenuBarReader
        let swapsSameZonePeers: Bool
        var moves = 0
        init(reader: FakeMenuBarReader, swapsSameZonePeers: Bool) {
            self.reader = reader; self.swapsSameZonePeers = swapsSameZonePeers
        }
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            moves += 1
            var items = MenuBarEnumeration.sortedLeftToRight(reader.items)
            let frames = items.map(\.frame)
            if swapsSameZonePeers { items.swapAt(0, 3) }
            else if let source = items.firstIndex(where: { $0.id == itemID }), source > 0 { items.swapAt(source, source - 1) }
            for index in items.indices { items[index].frame = frames[index] }
            reader.items = items
            return CGPoint(x: x, y: 1188)
        }
    }

    private func checkPartialArrangement(swapsSameZonePeers: Bool) {
        MainActor.assumeIsolated {
            let observed = ["fs", "left", "hidden", "orb", "right", "toggle", "visible"].enumerated().map {
                TestItems.item($0.element, centerX: CGFloat(($0.offset + 1) * 100))
            }
            let reader = FakeMenuBarReader(items: observed)
            let mover = PartialMover(reader: reader, swapsSameZonePeers: swapsSameZonePeers)
            let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
            let saved = MenuBarLayout(zones: ["alwaysHidden": ["fs", "orb"], "hidden": ["hidden"], "visible": ["visible"]])
            var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
            expect(operation.start(layout: saved, controls: controls, expectedItems: ["fs", "orb", "hidden", "visible"],
                                   defaultZone: .hidden, screens: [screen]) { outcome = $0 })
            expect(pump { outcome != nil })
            if swapsSameZonePeers {
                if case .failure(.stalled) = outcome {} else { expect(false, "同区互换没有改善分区，必须停止") }
                expectEqual(mover.moves, 1, "不能交替移动 FS/Orb 直到步骤上限")
            } else {
                if case .success = outcome {} else { expect(false, "真正减少分区错序的部分落位应继续收敛") }
                expectEqual(mover.moves, 2)
            }
        }
    }

    func sameZoneSwapsCannotKeepArrangementRunning() throws { checkPartialArrangement(swapsSameZonePeers: true) }
    func partialMovesMustImproveTheWholePartition() throws { checkPartialArrangement(swapsSameZonePeers: false) }

    func toggleSeparatesVisibleAndHiddenItemsInBothModes() throws {
        MainActor.assumeIsolated {
            let saved = MenuBarLayout(zones: ["hidden": ["hidden"], "visible": ["visible"]])
            let expected = ["left", "hidden", "right", "toggle", "visible", "clock"]
            let scenarios: [([String], Int)] = [
                (["left", "hidden", "right", "visible", "toggle", "clock"], 1),
                (["left", "right", "toggle", "hidden", "visible", "clock"], 2),
            ]
            for restoreSavedOrder in [false, true] {
                for (original, expectedMoves) in scenarios {
                    let items = original.enumerated().map {
                        TestItems.item($0.element, centerX: CGFloat(($0.offset + 1) * 100), isSystemOwned: $0.element == "clock")
                    }
                    let reader = FakeMenuBarReader(items: items)
                    let mover = PartialMover(reader: reader, swapsSameZonePeers: false)
                    let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
                    var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
                    expect(operation.start(layout: saved, controls: controls, expectedItems: ["hidden", "visible"],
                                           defaultZone: .hidden, screens: [screen], restoreSavedOrder: restoreSavedOrder) { outcome = $0 })
                    expect(pump { outcome != nil })
                    if case .success(let observed) = outcome {
                        expectEqual(MenuBarEnumeration.sortedLeftToRight(observed).map(\.id), expected,
                                    "常显项必须在按钮右侧，展开的隐藏项必须在按钮左侧")
                    } else { expect(false, "按钮分界应经有限移动恢复：\(String(describing: outcome))") }
                    expectEqual(mover.moves, expectedMoves, "错误按钮分界不能零移动报成功，也不能反复整理")
                    expect(!operation.isRunning)
                }
            }
        }
    }

    func savedOrderRestorationMovesWithinAlreadyCorrectZones() throws {
        MainActor.assumeIsolated {
            let original = ["left", "a", "b", "c", "right", "toggle", "visible", "clock"]
            let expected = ["left", "c", "b", "a", "right", "toggle", "visible", "clock"]
            let items = original.enumerated().map {
                TestItems.item($0.element, centerX: CGFloat(($0.offset + 1) * 100), isSystemOwned: $0.element == "clock")
            }
            let reader = FakeMenuBarReader(items: items)
            let mover = PartialMover(reader: reader, swapsSameZonePeers: false)
            let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
            let saved = MenuBarLayout(zones: ["hidden": ["c", "b", "a"], "visible": ["visible"]])
            var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
            expect(operation.start(layout: saved, controls: controls, expectedItems: ["a", "b", "c", "visible"],
                                   defaultZone: .hidden, screens: [screen], restoreSavedOrder: true) { outcome = $0 })
            expect(pump { outcome != nil })
            if case .success(let observed) = outcome {
                expectEqual(MenuBarEnumeration.sortedLeftToRight(observed).map(\.id), expected,
                            "显式恢复不能因分区已正确就跳过同区排序")
            } else { expect(false, "每次只挪一格但减少完整逆序时应继续收敛：\(String(describing: outcome))") }
            expectEqual(mover.moves, 3, "三项反序应通过三个相邻移动恢复，不能零移动报成功")
            expect(!operation.isRunning)
        }
    }

    private final class SettlingMover: MenuBarMoving {
        let reader: FakeMenuBarReader
        let settled: [ManagedItem]
        let refusals: Int
        var calls = 0
        init(reader: FakeMenuBarReader, settled: [ManagedItem], refusals: Int) {
            self.reader = reader; self.settled = settled; self.refusals = refusals
        }
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            calls += 1
            if calls <= refusals { throw MenuBarMoveError.targetNotInteractable }
            reader.items = settled
            return CGPoint(x: x, y: 1188)
        }
    }

    func animationRetriesAreBoundedAndCanRecover() throws {
        MainActor.assumeIsolated {
            for refusals in [1, 3] {
                let reader = FakeMenuBarReader(items: before)
                let mover = SettlingMover(reader: reader, settled: after, refusals: refusals)
                let operation = MenuBarArrangement(reader: reader, mover: mover, cursor: FakeCursor())
                var outcome: Result<[ManagedItem], MenuBarArrangement.Failure>?
                expect(operation.start(layout: layout, controls: controls, expectedItems: ["hidden", "visible"],
                                       defaultZone: .hidden, screens: [screen]) { outcome = $0 })
                expect(pump { outcome != nil })
                if refusals == 1 {
                    if case .success = outcome {} else { expect(false, "动画稳定后应重新规划并完成") }
                    expectEqual(mover.calls, 2)
                } else {
                    if case .failure(.moveFailed(_, .targetNotInteractable)) = outcome {} else { expect(false) }
                    expectEqual(mover.calls, 3, "持续被挡住最多重读两次，不能无限重试")
                }
            }
        }
    }

    func systemStateChangesDoNotChangeManagedAssignments() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("managed-change")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: AppSettings(), store: FakeSettingsStore())
        let own = Bundle.main.bundleIdentifier ?? "local.tidybar.app"
        controller.applyScan([TestItems.item("a"), TestItems.item("clock-old", isSystemOwned: true),
                              ManagedItem(id: "toggle-old", ownerBundleID: own, title: "☰", frame: .zero)])
        let original = controller.managedZoneAssignments
        controller.applyScan([TestItems.item("a"), TestItems.item("clock-new", isSystemOwned: true),
                              ManagedItem(id: "toggle-new", ownerBundleID: own, title: "▶", frame: .zero)])
        expectEqual(controller.managedZoneAssignments, original, "系统状态文案和自有按钮变化不应重新展开菜单栏")
    }

    private final class SessionCursor: CursorReading {
        var currentLocation = CGPoint(x: 600, y: 1188)
        var isPrimaryButtonPressed = false
        var isSessionInteractive = false
        var displayConfiguration: [CGDirectDisplayID: CGRect]? = [1: CGRect(x: 0, y: 0, width: 1440, height: 1200)]
    }

    func lockedSessionNeverPostsInput() throws {
        let cursor = SessionCursor()
        let poster = RecordingDragEventPoster()
        let mover = AccessibilityMenuBarMover(reader: FakeMenuBarReader(ids: ["a"]), cursor: cursor,
                                              poster: poster, config: .init(isConfirmedSupportedOS: true))
        expect(throws: MenuBarMoveError.sessionUnavailable) { try mover.move(itemID: "a", toX: 700) }
        expect(poster.posted.isEmpty, "锁屏时连光标 warp 也不能发出")

        cursor.isSessionInteractive = true
        poster.onPost = { event in
            if case .mouseDown = event { cursor.isSessionInteractive = false }
        }
        expect(throws: MenuBarMoveError.sessionUnavailable) { try mover.move(itemID: "a", toX: 700) }
        expect(poster.contains("mouseUp"), "拖拽途中锁屏仍须释放已按下的鼠标")
        expect(!mover.isDragInFlight)
        expectEqual(mover.consecutiveSuccesses, 0)
    }

    func recoveryWaitsForAnInteractiveSession() throws {
        let cursor = SessionCursor()
        let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("b", centerX: 640)])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("locked-recovery"))
        try journal.writeCommitted(MenuBarLayout(zones: ["visible": ["a"], "hidden": ["b"]]))
        try journal.writeIntent(.init(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                      previousZone: .visible, previousPosition: 0))
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(reader: reader, mover: mover, cursor: cursor),
                                  journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: AppSettings(), store: FakeSettingsStore())
        controller.start()
        expect(mover.moved.isEmpty)
        expectEqual(journal.readPendingIntent()?.replayFailures, 0, "锁屏等待不能消耗恢复次数")
        cursor.isSessionInteractive = true
        controller.applyScan(reader.items)
        expectEqual(mover.moved.count, 1)
        expect(!journal.hasPendingIntent)
    }

    func inFlightCancellationAndDisplayChangesStopInput() throws {
        for (physicalCommand, changesDisplay) in [(false, false), (false, true), (true, false), (true, true)] {
            let cursor = SessionCursor(); cursor.isSessionInteractive = true
            let poster = RecordingDragEventPoster()
            let mover: MenuBarMoving = AccessibilityMenuBarMover(reader: FakeMenuBarReader(ids: ["a"]), cursor: cursor,
                poster: poster, config: .init(settleInterval: 0, initialHoldInterval: 0,
                    postsPhysicalCommandKey: physicalCommand, isConfirmedSupportedOS: true))
            var cancelled = false
            poster.onPost = { event in
                let shouldInterrupt: Bool
                switch event {
                case .commandDown: shouldInterrupt = physicalCommand
                case .mouseDown: shouldInterrupt = !physicalCommand
                default: shouldInterrupt = false
                }
                if shouldInterrupt {
                    if changesDisplay {
                        cursor.displayConfiguration = [1: CGRect(x: 0, y: 0, width: 1440, height: 1440)]
                        cursor.currentLocation = CGPoint(x: 600, y: 1428)
                    } else { cancelled = true }
                }
            }
            expect(throws: MenuBarMoveError.dragInterrupted) {
                try mover.move(itemID: "a", toX: 700, isCancelled: { cancelled })
            }
            expect(!poster.contains("mouseDragged"), "取消或换屏后不能再投递拖动事件")
            if physicalCommand {
                expect(!poster.contains("mouseDown"), "真实 Command 按下后取消也不能再发鼠标按下")
                expect(poster.contains("commandUp"), "已按下的真实 Command 必须释放")
            } else {
                expectEqual(poster.lastUp, cursor.currentLocation, "使用当前真实位置释放按下，而不是旧显示器坐标")
            }
            expect((mover as? DragReleasing)?.isDragInFlight == false)
        }
    }

    func accessibilityUpgradeDoesNotRequireReconstructingController() throws {
        let trust = FakeTrust(); trust.isTrusted = false
        let services = SystemServices(reader: FakeMenuBarReader(ids: ["a"]), mover: FakeMenuBarMover(),
                                      cursor: FakeCursor(), accessibility: trust, screens: FakeScreens())
        let engine = LayoutEngine(layout: MenuBarLayout(), services: services,
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("permission-upgrade")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: AppSettings(), store: FakeSettingsStore())
        expectEqual(controller.capability, .panelOnlyFallback)
        trust.isTrusted = true
        controller.refreshItems()
        expectEqual(controller.capability, .fullDrag, "授权后应刷新可用能力，不继续用旧降级状态")
        engine.markDraggingUnsupported()
        controller.refreshItems()
        expectEqual(controller.capability, .panelOnlyFallback, "权限刷新不能重新开启被系统拒绝的移动器")
    }
}

extension MenuBarArrangementTests {
    static var testCases: [TestCase] {
        let suite = MenuBarArrangementTests()
        return [
            TestCase("arrangementResultRefreshesFramesWithoutReleasingTheBusyGuard", suite.arrangementResultRefreshesFramesWithoutReleasingTheBusyGuard),
            TestCase("foldingKeepsZoneOrderAndExcludesSystemProxies", suite.foldingKeepsZoneOrderAndExcludesSystemProxies),
            TestCase("explicitReorderIgnoresSystemProxySlots", suite.explicitReorderIgnoresSystemProxySlots),
            TestCase("arrangementLeavesTheTargetMainLoopAvailable", suite.arrangementLeavesTheTargetMainLoopAvailable),
            TestCase("cancellationDrainsInputBeforeCompleting", suite.cancellationDrainsInputBeforeCompleting),
            TestCase("controllerRejectsConflictingOperationsWhileArranging", suite.controllerRejectsConflictingOperationsWhileArranging),
            TestCase("crossScreenItemsNeverEnterTheSameArrangement", suite.crossScreenItemsNeverEnterTheSameArrangement),
            TestCase("settlingItemsSettleBeforeArrangement", suite.settlingItemsSettleBeforeArrangement),
            TestCase("sameZoneSwapsCannotKeepArrangementRunning", suite.sameZoneSwapsCannotKeepArrangementRunning),
            TestCase("partialMovesMustImproveTheWholePartition", suite.partialMovesMustImproveTheWholePartition),
            TestCase("toggleSeparatesVisibleAndHiddenItemsInBothModes", suite.toggleSeparatesVisibleAndHiddenItemsInBothModes),
            TestCase("savedOrderRestorationMovesWithinAlreadyCorrectZones", suite.savedOrderRestorationMovesWithinAlreadyCorrectZones),
            TestCase("animationRetriesAreBoundedAndCanRecover", suite.animationRetriesAreBoundedAndCanRecover),
            TestCase("systemStateChangesDoNotChangeManagedAssignments", suite.systemStateChangesDoNotChangeManagedAssignments),
            TestCase("lockedSessionNeverPostsInput", suite.lockedSessionNeverPostsInput),
            TestCase("recoveryWaitsForAnInteractiveSession", suite.recoveryWaitsForAnInteractiveSession),
            TestCase("inFlightCancellationAndDisplayChangesStopInput", suite.inFlightCancellationAndDisplayChangesStopInput),
            TestCase("accessibilityUpgradeDoesNotRequireReconstructingController", suite.accessibilityUpgradeDoesNotRequireReconstructingController),
        ]
    }
}
