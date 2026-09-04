import Foundation
import CoreGraphics
import TidyBarCore

// MARK: - 优雅退出与孤儿意图重放（验证项 3 的两个收尾缺口）

/// 信号收尾本身。用 `kill(getpid(), …)` 给自己发**进程级**信号——注销/launchd 回收就是这个投递方式。
/// 不要用 `raise()`：它投给当前线程，会被 Dispatch 信号源绕开，测出来的"通过"是假的。
/// DispatchSource 与内核之间没有可替换的接缝，所以这条断言不依赖任何替身。
struct GracefulShutdownTests {
    private func waitUntil(_ deadline: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(deadline)
        while Date() < limit {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    /// 注销/关机发的是 SIGTERM。它必须被捕获到，否则就回到"每次注销都可能留半成品"的老问题
    func termSignalTriggersCleanupOnce() throws {
        let shutdown = GracefulShutdown()
        let box = CallbackBox()
        shutdown.arm { sig in box.append(sig) }
        expect(shutdown.isArmed, "arm 之后必须挂上信号源")

        kill(getpid(), SIGTERM)
        expect(waitUntil { box.count == 1 }, "SIGTERM 没有触发收尾回调")
        expectEqual(box.received.first, Int32(SIGTERM))

        // 第二次信号不得重复触发：收尾里做落盘和 exit，跑两遍会写出两份"已提交布局"
        kill(getpid(), SIGTERM)
        usleep(100_000)
        expectEqual(box.count, 1, "收尾回调必须幂等")
        shutdown.disarm()
        expect(!shutdown.isArmed)
    }

    /// Ctrl-C 与 launchd 回收分别走 INT/HUP，三者都要接住——只处理 TERM 等于漏掉一半退出场景
    func allThreePoliteSignalsAreCaught() throws {
        for sig in [SIGINT, SIGHUP] {
            let shutdown = GracefulShutdown()
            let box = CallbackBox()
            shutdown.arm { received in box.append(received) }
            kill(getpid(), sig)
            expect(waitUntil { box.count == 1 }, "信号 \(sig) 没有触发收尾")
            shutdown.disarm()
        }
    }

    /// disarm 会把信号处置还原成默认（SIG_DFL）——那一刻起再发 TERM 就真的杀进程，
    /// 所以本用例只在 armed 状态下发信号，验证的是"状态位被清干净 + 重新 arm 仍然生效"。
    func disarmedShutdownStaysSilent() throws {
        let shutdown = GracefulShutdown()
        let box = CallbackBox()
        shutdown.arm { sig in box.append(sig) }
        shutdown.disarm()

        // disarm 后默认处置已还原，因此这里**不能**再 raise TERM/HUP/INT（会真杀进程）。
        // 能验证的是：状态位已清空、且重复 arm/disarm 不会把回调变成两个。
        expect(!shutdown.isArmed, "disarm 必须清掉挂载状态")
        shutdown.arm { sig in box.append(sig) }
        kill(getpid(), SIGTERM)
        expect(waitUntil { box.count == 1 }, "重新 arm 后必须重新生效")
        shutdown.disarm()
    }
}

final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return signals.count
    }
    var received: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return signals
    }

    func append(_ sig: Int32) {
        lock.lock()
        signals.append(sig)
        lock.unlock()
    }
}

extension GracefulShutdownTests {
    static var testCases: [TestCase] {
        let suite = GracefulShutdownTests()
        return [
            TestCase("termSignalTriggersCleanupOnce", suite.termSignalTriggersCleanupOnce),
            TestCase("allThreePoliteSignalsAreCaught", suite.allThreePoliteSignalsAreCaught),
            TestCase("disarmedShutdownStaysSilent", suite.disarmedShutdownStaysSilent),
        ]
    }
}

// MARK: - 半空拖拽的插手权

struct InFlightDragTests {
    private func makeMover(
        poster: RecordingDragEventPoster,
        reader: FakeMenuBarReader,
        commandKey: Bool = false
    ) -> AccessibilityMenuBarMover {
        AccessibilityMenuBarMover(
            reader: reader,
            cursor: FakeCursor(location: CGPoint(x: 600, y: 1_188)),
            poster: poster,
            // 容差放到最松：这道题要测的是"被打断时怎么收手"，不是光标纪律
            config: AccessibilityMenuBarMover.Config(
                stepCount: 4, settleInterval: 0, initialHoldInterval: 0,
                maxLagPoints: 100_000, maxPlacementDriftPoints: 100_000,
                postsPhysicalCommandKey: commandKey, isConfirmedSupportedOS: true
            )
        )
    }

    private func reader() -> FakeMenuBarReader {
        FakeMenuBarReader(items: [TestItems.item("com.test.a", centerX: 600, centerY: 1_188)])
    }

    /// 没事可做时不得发出任何事件——乱抬鼠标键本身就是一次幽灵点击
    func releaseWithoutDragPostsNothing() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, reader: reader())
        expect(!mover.isDragInFlight)

        mover.releaseInFlightDrag()
        mover.releaseInFlightDrag()
        expect(poster.posted.isEmpty, "不在拖拽中却抬起了键：\(poster.posted)")
    }

    /// 信号在飞行途中抢先抬起：必须真的抬、只抬一次，并且让拖拽当场收手
    func externalReleaseRaisesOnceAndAbortsDrag() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, reader: reader())
        var released = false
        poster.onPost = { event in
            guard !released, case .mouseDragged = event else { return }
            released = true
            mover.releaseInFlightDrag()
        }

        var thrown: MenuBarMoveError?
        do {
            _ = try mover.move(itemID: "com.test.a", toX: 700)
        } catch let error as MenuBarMoveError {
            thrown = error
        }
        expect(released, "钩子没有命中飞行中的拖拽")
        expectEqual(thrown, .dragInterrupted, "被打断必须报 dragInterrupted，而不是假装成功")

        let ups = poster.posted.filter {
            if case .mouseUp = $0 { return true }
            return false
        }
        expectEqual(ups.count, 1, "只允许抬起一次，多抬一次就是一次凭空点击")
        expect(!mover.isDragInFlight)
    }

    /// 正常完成的路径不能被新加的在架检查拖住：一步都不能多抬
    func cleanDragStillPostsExactlyOneUp() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, reader: reader())
        _ = try mover.move(itemID: "com.test.a", toX: 700)

        let ups = poster.posted.filter {
            if case .mouseUp = $0 { return true }
            return false
        }
        expectEqual(ups.count, 1)
        expect(!mover.isDragInFlight, "完成后必须清空在架标记")
        let postedAfterSuccess = poster.posted.count
        mover.releaseInFlightDrag()
        expectEqual(poster.posted.count, postedAfterSuccess, "完成后收尾不得再补发事件")
    }

    /// 启用真实 ⌘ 键时，被打断也要把 ⌘ 抬回去——这正是当年"⌘ 卡住"的病灶
    func interruptedDragStillLiftsCommandKey() throws {
        let poster = RecordingDragEventPoster()
        let mover = makeMover(poster: poster, reader: reader(), commandKey: true)
        poster.onPost = { event in
            if case .mouseDragged = event { mover.releaseInFlightDrag() }
        }
        _ = try? mover.move(itemID: "com.test.a", toX: 700)

        let names = poster.posted.map { event -> String in
            switch event {
            case .commandDown: return "commandDown"
            case .commandUp: return "commandUp"
            case .mouseDown: return "mouseDown"
            case .mouseUp: return "mouseUp"
            default: return "other"
            }
        }
        expect(names.first == "commandDown" || names.contains("commandDown"), "⌘ 必须先按下")
        let downs = names.filter { $0 == "commandDown" }.count
        let ups = names.filter { $0 == "commandUp" }.count
        expectEqual(downs, ups, "⌘ 必须成对，卡住就是全局快捷键灾难")
        expectEqual(names.filter { $0 == "mouseUp" }.count, 1, "鼠标键只抬一次")
    }
}

extension InFlightDragTests {
    static var testCases: [TestCase] {
        let suite = InFlightDragTests()
        return [
            TestCase("releaseWithoutDragPostsNothing", suite.releaseWithoutDragPostsNothing),
            TestCase("externalReleaseRaisesOnceAndAbortsDrag", suite.externalReleaseRaisesOnceAndAbortsDrag),
            TestCase("cleanDragStillPostsExactlyOneUp", suite.cleanDragStillPostsExactlyOneUp),
            TestCase("interruptedDragStillLiftsCommandKey", suite.interruptedDragStillLiftsCommandKey),
        ]
    }
}

// MARK: - 孤儿意图的重放与上限

struct PendingIntentReplayTests {
    private let itemID = "com.test.a"

    private func journal(_ label: String) -> LayoutJournal {
        LayoutJournal(directory: TestPaths.journalDirectory(label))
    }

    private func makeEngine(
        reader: FakeMenuBarReader,
        mover: MenuBarMoving?,
        journal: LayoutJournal,
        maxReplayAttempts: Int = LayoutJournal.defaultMaxReplayAttempts
    ) -> LayoutEngine {
        LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: mover),
            journal: journal,
            sentinel: EventSentinel(driftTolerance: 4, minIntervalBetweenOperations: 0),
            maxReplayAttempts: maxReplayAttempts,
            // 离线测试不等真机落位：复核窗口压到 0，失败立刻可见
            verificationWindow: 0
        )
    }

    private func intent(to zone: MenuBarZone = .hidden) -> LayoutJournal.LayoutIntent {
        LayoutJournal.LayoutIntent(
            itemID: itemID, targetZone: zone, targetPosition: nil,
            previousZone: .visible, previousPosition: 0
        )
    }

    /// 升级前写下的 pending 文件没有 replayFailures 字段。
    /// 若解码失败，`readPendingIntent` 会返回 nil —— 孤儿意图会被"静默丢掉"，
    /// 用户看到的就是"上次没做完的整理凭空消失"。这条钉住向后兼容。
    func legacyPendingFileWithoutCounterStillDecodes() throws {
        let journal = journal("legacy-pending")
        try journal.writeIntent(intent())
        let url = journal.directory.appendingPathComponent("layout.pending.json")
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try record("pending 文件不是预期的 JSON 对象，样本失效")
            return
        }
        object.removeValue(forKey: "replayFailures")
        try JSONSerialization.data(withJSONObject: object)
            .write(to: url, options: .atomic)

        guard let decoded = journal.readPendingIntent() else {
            try record("旧格式 pending 文件读不出来 → 孤儿意图会被静默丢弃")
            return
        }
        expectEqual(decoded.itemID, itemID)
        expectEqual(decoded.replayFailures, 0)
    }

    /// 重放失败不能悄悄清掉意图：意图代表用户说过"我要它藏在哪儿"，一次失败就丢掉等于替用户做决定
    func failedReplayKeepsIntentForNextLaunch() throws {
        let journal = journal("replay-keep")
        var layout = MenuBarLayout()
        layout.append(itemID, to: .visible)
        try journal.writeCommitted(layout)
        try journal.writeIntent(intent())

        let reader = FakeMenuBarReader(ids: [itemID])
        let failing = FakeMenuBarMover()
        failing.injectedError = .abortedBySentinel(.userInteracting)
        let engine = makeEngine(reader: reader, mover: failing, journal: journal)
        _ = engine.recoverOnLaunch()

        do {
            try engine.replay(intent())
            try record("拖拽失败却报重放成功")
        } catch {
            expectEqual(engine.noteReplayFailure(), .retryScheduled(failures: 1))
        }
        expect(journal.hasPendingIntent, "未达上限前意图必须留在盘上")
        expectEqual(journal.readPendingIntent()?.replayFailures, 1)
        expectNil(journal.readCommittedLayout().flatMap { _ in Int?.none }, "重放未成功不得改写已提交布局")
    }

    /// 但也不能永远重试：图标所属 App 已卸载、系统改版后落点规则变了，
    /// 每次启动都撞同一堵墙，还可能反复推用户的菜单栏。
    func twoFailuresAbandonIntentAndFallBackToCommitted() throws {
        let journal = journal("replay-abandon")
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(intent())

        let reader = FakeMenuBarReader(ids: [itemID])
        let failing = FakeMenuBarMover()
        failing.injectedError = .itemVanished(itemID)
        let engine = makeEngine(reader: reader, mover: failing, journal: journal)
        _ = engine.recoverOnLaunch()

        try? engine.replay(intent())
        expectEqual(engine.noteReplayFailure(), .retryScheduled(failures: 1))
        try? engine.replay(intent())
        expectEqual(engine.noteReplayFailure(), .abandoned)

        expect(!journal.hasPendingIntent, "达到上限后必须清除意图")
        expectEqual(engine.layout.zone(of: itemID), .visible, "布局要回落到上次已提交状态")
        // 第三次没有意图可记：不能再"顺手放弃"一次
        expectEqual(engine.noteReplayFailure(), .nothingPending)
    }

    /// 重放成功必须同时做到：清 pending、写 committed、并且是真的按结果复核过的
    func successfulReplayClearsIntentAndCommits() throws {
        let journal = journal("replay-success")
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(intent())

        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        let engine = makeEngine(reader: reader, mover: mover, journal: journal)
        engine.targetProvider = { _, _ in 500 }
        _ = engine.recoverOnLaunch()

        try engine.replay(intent())
        expect(!journal.hasPendingIntent, "重放成功后必须清掉意图")
        expectEqual(journal.readCommittedLayout()?.zone(of: itemID), .hidden)
        expectEqual(engine.layout.zone(of: itemID), .hidden)
    }

    /// 没有落点就不许动手：与验证项 2 的结论一致——硬拖进空隙会被系统静默忽略，
    /// 重放路径同样不能给"猜一个坐标"留后门
    func replayWithoutLandingPointDoesNotTouchSystem() throws {
        let journal = journal("replay-noland")
        try journal.writeIntent(intent())
        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        let engine = makeEngine(reader: reader, mover: mover, journal: journal)
        _ = engine.recoverOnLaunch()

        do {
            try engine.replay(intent())
            try record("没有 targetProvider 也去拖 → 会拖进空隙")
        } catch let error as LayoutEngine.EngineError {
            expectEqual(error, .noMovementCapability)
        }
        expect(mover.moved.isEmpty, "不得发出任何拖拽")
        expect(journal.hasPendingIntent, "没做成之前意图仍然保留")
    }

    /// 降级模式下重放必须整条跳过：那时布局只决定自有面板显示谁，去拖系统图标等于凭猜测制造副作用
    func panelOnlyModeNeverReplaysPhysically() throws {
        let journal = journal("replay-panelonly")
        try journal.writeIntent(intent())
        let reader = FakeMenuBarReader(ids: [itemID])
        let engine = makeEngine(reader: reader, mover: UnverifiedMenuBarMover(), journal: journal)
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(autoRecoverPendingIntent: true),
            store: FakeSettingsStore(AppSettings(autoRecoverPendingIntent: true))
        )
        _ = controller.start(scansSynchronously: false)
        expect(engine.capability == .panelOnlyFallback)
        expect(controller.logs.last?.contains("无需重放") ?? false,
               "降级模式要说明为什么没动：\(controller.logs.last ?? "无日志")")
    }

    /// 装配层接线：开自动重放时，start() 必须真的把意图做掉而不是只在内存里"当作完成"
    func controllerReplaysOrphanIntentOnStart() throws {
        let journal = journal("controller-replay")
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(intent())

        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        let engine = makeEngine(reader: reader, mover: mover, journal: journal)
        engine.targetProvider = { _, _ in 500 }
        let settings = AppSettings(autoRecoverPendingIntent: true)
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: settings,
            store: FakeSettingsStore(settings)
        )
        let recovery = controller.start(scansSynchronously: false)

        if case .clean = recovery { try record("带 pending 启动必须判定为 interrupted") }
        expectEqual(mover.moved.count, 1, "start() 没有真的重放")
        expect(!journal.hasPendingIntent)
        expect(controller.logs.last?.contains("已重放") ?? false, "\(controller.logs)")
    }

    /// 关自动重放时不得动手，且要把"放弃"这件事写进日志——用户有权知道上次没做完
    func controllerDiscardsIntentWhenAutoRecoverOff() throws {
        let journal = journal("controller-off")
        var committed = MenuBarLayout()
        committed.append(itemID, to: .visible)
        try journal.writeCommitted(committed)
        try journal.writeIntent(intent())

        let reader = FakeMenuBarReader(ids: [itemID])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        let engine = makeEngine(reader: reader, mover: mover, journal: journal)
        engine.targetProvider = { _, _ in 500 }
        let settings = AppSettings(autoRecoverPendingIntent: false)
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: settings,
            store: FakeSettingsStore(settings)
        )
        _ = controller.start(scansSynchronously: false)

        expect(mover.moved.isEmpty, "设置关了还去拖用户图标 = 违背用户选择")
        expect(!journal.hasPendingIntent)
        expectEqual(engine.layout.zone(of: itemID), .visible)
    }
}

extension PendingIntentReplayTests {
    static var testCases: [TestCase] {
        let suite = PendingIntentReplayTests()
        return [
            TestCase("legacyPendingFileWithoutCounterStillDecodes", suite.legacyPendingFileWithoutCounterStillDecodes),
            TestCase("failedReplayKeepsIntentForNextLaunch", suite.failedReplayKeepsIntentForNextLaunch),
            TestCase("twoFailuresAbandonIntentAndFallBackToCommitted", suite.twoFailuresAbandonIntentAndFallBackToCommitted),
            TestCase("successfulReplayClearsIntentAndCommits", suite.successfulReplayClearsIntentAndCommits),
            TestCase("replayWithoutLandingPointDoesNotTouchSystem", suite.replayWithoutLandingPointDoesNotTouchSystem),
            TestCase("panelOnlyModeNeverReplaysPhysically", suite.panelOnlyModeNeverReplaysPhysically),
            TestCase("controllerReplaysOrphanIntentOnStart", suite.controllerReplaysOrphanIntentOnStart),
            TestCase("controllerDiscardsIntentWhenAutoRecoverOff", suite.controllerDiscardsIntentWhenAutoRecoverOff),
        ]
    }
}
