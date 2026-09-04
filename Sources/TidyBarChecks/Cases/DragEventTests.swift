import Foundation
import CoreGraphics
import TidyBarCore

/// 拖拽事件纪律的离线回归。
///
/// 为什么值得单独钉：这类 bug 在真机上表现为"用户的 ⌘ 卡住了 / 光标自己乱跑"，
/// 一旦发生就是不可挽回的差评（Bartender 5/6 在 Tahoe 上正是这个死法）。
/// 真机探针只能证明"这次没事"，用录制型投递器才能断言"中止时一个事件都没发"
/// 和"任何失败路径都抬起了 ⌘"。
struct DragEventDisciplineTests {
    private func makeMover(
        poster: DragEventPosting,
        cursor: FakeCursor,
        items: [ManagedItem],
        supported: Bool = true,
        stepCount: Int = 4
    ) -> AccessibilityMenuBarMover {
        AccessibilityMenuBarMover(
            reader: FakeMenuBarReader(items: items),
            cursor: cursor,
            poster: poster,
            sentinel: EventSentinel(driftTolerance: 6, minIntervalBetweenOperations: 0.05),
            config: AccessibilityMenuBarMover.Config(
                stepCount: stepCount,
                settleInterval: 0,          // 单测里不真等
                initialHoldInterval: 0,
                maxLagPoints: 30,
                // 本文件断言的是「⌘ 事件纪律」，因此显式打开按键模式；
                // 生产默认已改为不发按键（真机证明鼠标事件自带 flags 才是必需的）
                postsPhysicalCommandKey: true,
                isConfirmedSupportedOS: supported
            )
        )
    }

    private var icon: ManagedItem { TestItems.item("com.test.icon", centerX: 600, centerY: 1_188) }

    // MARK: 成功路径

    func postsEventsInCorrectOrder() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, cursor: FakeCursor(), items: [icon])

        try mover.move(itemID: icon.id, toX: 600)

        let kinds = poster.posted.compactMap { event -> String? in
            switch event {
            case .warp: return "warp"
            case .commandDown: return "commandDown"
            case .mouseDown: return "mouseDown"
            case .mouseDragged: return "mouseDragged"
            case .mouseUp: return "mouseUp"
            case .commandUp: return "commandUp"
            case .settle: return nil
            }
        }
        expectEqual(kinds.first, "warp", "先把光标放到起点")
        expectEqual(kinds.dropFirst().first, "commandDown", "⌘ 必须按下后才拖")
        expectEqual(Array(kinds.dropFirst(2).prefix(2)), ["mouseDown", "mouseDragged"])
        expectEqual(kinds.last, "commandUp", "最后必须抬起 ⌘")
        expectEqual(kinds.filter { $0 == "commandUp" }.count, 1, "⌘ 只能抬起一次")
        expectEqual(kinds.filter { $0 == "commandDown" }.count, 1)
        expectEqual(poster.dragPoints.count, 6, "1 次按下 + 4 步拖动 + 1 次抬起")
        expectEqual(mover.consecutiveSuccesses, 1)
    }

    func dragsLandOnRequestedTarget() throws {
        let cursor = FakeCursor()
        // 用会同步光标的投递器：真实系统里光标就是跟着事件走的，
        // 落点复核（postflight）读的就是这个值
        let poster = DriftInjectingPoster(cursor: cursor, driftAfter: .max)
        let mover = makeMover(poster: poster, cursor: cursor, items: [icon])

        let landing = try mover.move(itemID: icon.id, toX: 700)
        expectEqual(landing, CGPoint(x: 700, y: 1_188))
        expect(poster.contains("mouseUp"), "抬起事件必须发出")
    }

    // MARK: 一个事件都不发的路径

    func refusesToTouchAnythingOnUnsupportedOS() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, cursor: FakeCursor(), items: [icon], supported: false)

        do {
            _ = try mover.move(itemID: icon.id, toX: 700)
            try record("未确认支持的 OS 上必须拒绝工作")
        } catch let error as MenuBarMoveError {
            if case .unsupportedOS = error {} else { try record("错误类型应为 unsupportedOS，实际 \(error)") }
        }
        expect(poster.posted.isEmpty, "拒绝时不能发出任何输入事件")
    }

    func refusesWhenItemGone() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, cursor: FakeCursor(), items: [icon])

        do {
            _ = try mover.move(itemID: "com.test.vanished", toX: 700)
            try record("图标消失时必须报错")
        } catch let error as MenuBarMoveError {
            if case .itemVanished(let id) = error {
                expectEqual(id, "com.test.vanished")
            } else { try record("错误类型应为 itemVanished，实际 \(error)") }
        }
        expect(poster.posted.isEmpty, "找不到目标时一个事件都不发")
    }

    func yieldsWhenUserHoldsMouseButton() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, cursor: FakeCursor(pressed: true), items: [icon])

        do {
            _ = try mover.move(itemID: icon.id, toX: 700)
            try record("用户按住鼠标时必须让位")
        } catch let error as MenuBarMoveError {
            expect(isSentinelAbort(error, .userInteracting), "应判定为用户正在操作，实际 \(error)")
        }
        // 这条是整个验证项 2 最重要的断言：抢在用户之前发事件就是"光标劫持"
        expect(poster.posted.isEmpty, "用户按住鼠标时不得发出任何事件")
    }

    func yieldsWhenCursorIsNotWhereWeLeftIt() throws {
        let poster = RecordingDragEventPoster()
        // 光标被人挪到别处：预检就该发现（不是等到飞行中才发现）
        let mover = makeMover(poster: poster, cursor: FakeCursor(location: CGPoint(x: 120, y: 40)), items: [icon])

        do {
            _ = try mover.move(itemID: icon.id, toX: 700)
            try record("光标漂移时必须中止")
        } catch let error as MenuBarMoveError {
            guard case .abortedBySentinel(.cursorDrift) = error else {
                try record("应判定为光标漂移，实际 \(error)")
                return
            }
        }
        // 允许 warp + settle（放光标不算动手），但绝不能按下 ⌘ 或鼠标键
        expect(!poster.contains("commandDown"), "光标没放稳前不得按下 ⌘")
        expect(!poster.contains("mouseDown"), "光标没放稳前不得按下鼠标键")
        expectEqual(poster.posted.count, 2, "只应留下 warp + settle")
    }

    // MARK: 失败也必须干净退出

    func releasesCommandWhenCursorDriftsMidDrag() throws {
        let cursor = FakeCursor()
        let poster = DriftInjectingPoster(cursor: cursor, driftAfter: 2)
        let mover = makeMover(poster: poster, cursor: cursor, items: [icon], stepCount: 6)

        do {
            _ = try mover.move(itemID: icon.id, toX: 700)
            try record("飞行途中光标被挪走时必须中止")
        } catch let error as MenuBarMoveError {
            guard case .abortedBySentinel(.cursorDrift) = error else {
                try record("应为光标漂移中止，实际 \(error)")
                return
            }
        }
        // 这三条防止最坏后果：⌘ 卡在按下状态、鼠标卡在按下状态
        expect(poster.contains("commandUp"), "中止时也必须抬起 ⌘")
        expect(poster.contains("mouseUp"), "中止时也必须抬起鼠标键")
        expectEqual(mover.consecutiveSuccesses, 0, "中止不得计入成功")
        expectEqual(mover.totalAborts, 1)
    }

    func releasesCommandWhenSystemRejectsPost() throws {
        let poster = RecordingDragEventPoster()
        poster.failAt = 3 // 投递序号：0=warp 1=settle 2=commandDown 3=mouseDown
        let mover = makeMover(poster: poster, cursor: FakeCursor(), items: [icon])

        do {
            _ = try mover.move(itemID: icon.id, toX: 700)
            try record("系统拒绝投递时应中止")
        } catch is MenuBarMoveError {}

        expect(poster.contains("commandUp"), "投递失败也必须抬起 ⌘")
        expect(!poster.contains("mouseDragged"), "mouseDown 失败后不该继续拖")
    }

    // MARK: 坐标符号

    func posterFlipsVerticalAxisForCGEvents() {
        // 事件坐标用左上原点；符号写反时事件会飞到屏幕另一头（多屏负原点机器上尤其致命）
        let converted = CGDragEventPoster.cgPoint(for: CGPoint(x: 600, y: 1_053), primaryScreenHeight: 1_080)
        expectEqual(converted, CGPoint(x: 600, y: 27))

        // 矩形换算翻的是顶边：AppKit 的 origin 是底边，CG 的 origin 是顶边
        let cgRect = CGRect(x: 600, y: 3, width: 24, height: 24)
        let appKit = ScreenCoordinateSpace.cgToAppKit(cgRect, primaryScreenHeight: 1_080)
        expectEqual(appKit, CGRect(x: 600, y: 1_053, width: 24, height: 24))
        expectEqual(ScreenCoordinateSpace.appKitToCG(appKit, primaryScreenHeight: 1_080), cgRect, "两次换算必须互逆")
    }

    // MARK: 闸门

    func successCounterResetsOnFirstAbort() throws {
        let cursor = FakeCursor()
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, cursor: cursor, items: [icon], stepCount: 2)
        _ = try mover.move(itemID: icon.id, toX: 600)
        expectEqual(mover.consecutiveSuccesses, 1)

        cursor.isPrimaryButtonPressed = true
        do {
            _ = try mover.move(itemID: icon.id, toX: 600)
        } catch is MenuBarMoveError {}
        expectEqual(mover.consecutiveSuccesses, 0, "一次中止就要打断连续计数，否则 100 次闸门形同虚设")
    }
}

/// 中途把"光标"挪走，用来验证飞行途中能发现被劫持
final class DriftInjectingPoster: DragEventPosting {
    private let cursor: FakeCursor
    private let after: Int
    private(set) var dragged = 0
    private(set) var postedKinds: [String] = []

    init(cursor: FakeCursor, driftAfter: Int) {
        self.cursor = cursor
        self.after = driftAfter
    }

    @discardableResult
    func post(_ event: DragEvent) -> Bool {
        switch event {
        case .mouseDragged(let point):
            dragged += 1
            cursor.currentLocation = point
            if dragged > after {
                // 外力把光标拽走 200pt
                cursor.currentLocation = CGPoint(x: point.x - 200, y: point.y - 120)
            }
            postedKinds.append("mouseDragged")
        case .mouseDown(let point):
            cursor.currentLocation = point
            postedKinds.append("mouseDown")
        case .mouseUp(let point):
            cursor.currentLocation = point
            postedKinds.append("mouseUp")
        case .warp(let point):
            cursor.currentLocation = point
            postedKinds.append("warp")
        case .commandDown: postedKinds.append("commandDown")
        case .commandUp: postedKinds.append("commandUp")
        case .settle: break
        }
        return true
    }

    func contains(_ kind: String) -> Bool { postedKinds.contains(kind) }
}

func isSentinelAbort(_ error: MenuBarMoveError, _ verdict: EventSentinel.Verdict) -> Bool {
    if case .abortedBySentinel(let actual) = error, actual == verdict { return true }
    return false
}

/// 引擎与 mover 的职责分界：光标纪律归 mover，结果复核归引擎。
/// 这条断言守的是验证项 3 暴露的那个主路径 bug——引擎在 warp 之前拿光标比位置，
/// 结果任何真实变更都被自己判成"漂移中止"。
struct EngineGuardDivisionTests {
    func engineWorksEvenWhenCursorStartsElsewhere() throws {
        // 光标停在屏幕中央（真实用户的常态）。引擎不得因此拒绝工作——
        // 这正是验证项 3 抓到的主路径故障：旧实现在 warp 之前拿光标比位置，永远判"漂移中止"
        let cursor = FakeCursor(location: CGPoint(x: 700, y: 300))
        let recorder = RecordingDragEventPoster()
        let reader = FakeMenuBarReader(items: [TestItems.item("com.test.a", centerX: 600, centerY: 1_188)])
        let mover = AccessibilityMenuBarMover(
            reader: reader, cursor: cursor, poster: recorder,
            config: AccessibilityMenuBarMover.Config(stepCount: 4, settleInterval: 0, initialHoldInterval: 0,
                                                    maxPlacementDriftPoints: 400, postsPhysicalCommandKey: true,
                                                    isConfirmedSupportedOS: true)
        )
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("engine-guards"))
        var initial = MenuBarLayout()
        initial.append("com.test.a", to: .visible)
        let engine = LayoutEngine(layout: initial, services: makeServices(reader: reader, mover: mover), journal: journal)

        do {
            try engine.apply(itemID: "com.test.a", to: .hidden, targetX: 640)
        } catch let error as LayoutEngine.EngineError {
            if case .sentinelAborted(.cursorDrift) = error {
                try record("引擎仍在拿光标位置做预检 → 主路径永远中止（验证项 3 的原始 bug）")
            }
        }
        expect(recorder.contains("warp") || recorder.contains("mouseDown"), "没被预检挡住才会发出事件")
    }

    func engineReportsSilentNoOpAsFailure() throws {
        // macOS 会把落在空隙里的拖拽静默忽略：事件全发完了图标却不动。
        // 引擎必须靠"结果复核"发现这件事，绝不能当成功写进已提交布局
        let cursor = FakeCursor()
        let reader = FakeMenuBarReader(items: [TestItems.item("com.test.b", centerX: 600, centerY: 1_188)])
        let inert = FakeMenuBarMover()          // appliesMovement 默认 true，这里造一个不动的
        inert.appliesMovement = false
        inert.coupledReader = reader
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("engine-noop"))
        var initial = MenuBarLayout()
        initial.append("com.test.b", to: .visible)
        let engine = LayoutEngine(layout: initial, services: makeServices(reader: reader, mover: inert), journal: journal)

        do {
            try engine.apply(itemID: "com.test.b", to: .hidden, targetX: 780)
            try record("图标没动却上报成功 → 会把没发生的变更写进已提交布局")
        } catch let error as LayoutEngine.EngineError {
            if case .noVisibleEffect = error {} else { try record("应为 noVisibleEffect，实际 \(error)") }
        }
        expectNil(journal.readCommittedLayout(), "失败的变更不得提交")
        expectNil(journal.readPendingIntent(), "主动回滚要清掉意图；孤儿意图只应来自没来得及收尾的强杀")
    }

    func resultCheckRejectsSilentNoOp() {
        let moved = MenuBarDropTarget.didMove(
            before: CGRect(x: 600, y: 1_053, width: 24, height: 24),
            after: CGRect(x: 644, y: 1_053, width: 24, height: 24),
            towardX: 660
        )
        expect(moved, "朝目标移动应判为成功")
        expect(!MenuBarDropTarget.didMove(
            before: CGRect(x: 600, y: 1_053, width: 24, height: 24),
            after: CGRect(x: 600, y: 1_053, width: 24, height: 24),
            towardX: 660), "纹丝不动必须判为失败（静默忽略）")
        expect(!MenuBarDropTarget.didMove(
            before: CGRect(x: 600, y: 1_053, width: 24, height: 24),
            after: CGRect(x: 560, y: 1_053, width: 24, height: 24),
            towardX: 660), "反向移动不得算成功")
    }
}

extension EngineGuardDivisionTests {
    static var testCases: [TestCase] {
        let suite = EngineGuardDivisionTests()
        return [
            TestCase("engineWorksEvenWhenCursorStartsElsewhere", suite.engineWorksEvenWhenCursorStartsElsewhere),
            TestCase("engineReportsSilentNoOpAsFailure", suite.engineReportsSilentNoOpAsFailure),
            TestCase("resultCheckRejectsSilentNoOp", suite.resultCheckRejectsSilentNoOp),
        ]
    }
}

extension DragEventDisciplineTests {
    static var testCases: [TestCase] {
        let suite = DragEventDisciplineTests()
        return [
            TestCase("postsEventsInCorrectOrder", suite.postsEventsInCorrectOrder),
            TestCase("dragsLandOnRequestedTarget", suite.dragsLandOnRequestedTarget),
            TestCase("refusesToTouchAnythingOnUnsupportedOS", suite.refusesToTouchAnythingOnUnsupportedOS),
            TestCase("refusesWhenItemGone", suite.refusesWhenItemGone),
            TestCase("yieldsWhenUserHoldsMouseButton", suite.yieldsWhenUserHoldsMouseButton),
            TestCase("yieldsWhenCursorIsNotWhereWeLeftIt", suite.yieldsWhenCursorIsNotWhereWeLeftIt),
            TestCase("releasesCommandWhenCursorDriftsMidDrag", suite.releasesCommandWhenCursorDriftsMidDrag),
            TestCase("releasesCommandWhenSystemRejectsPost", suite.releasesCommandWhenSystemRejectsPost),
            TestCase("posterFlipsVerticalAxisForCGEvents", suite.posterFlipsVerticalAxisForCGEvents),
            TestCase("successCounterResetsOnFirstAbort", suite.successCounterResetsOnFirstAbort),
        ]
    }
}
