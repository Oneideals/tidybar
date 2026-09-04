import Foundation
import Foundation
import CoreGraphics
import TidyBarCore

struct EventSentinelTests {
    private let sentinel = EventSentinel(driftTolerance: 4, minIntervalBetweenOperations: 0.05)

    func preflightPassesOnQuietSystem() throws {
        let verdict = sentinel.preflight(
            expectedCursor: CGPoint(x: 600, y: 1_188),
            actualCursor: CGPoint(x: 600, y: 1_188),
            isMouseDown: false,
            elapsedSinceLastOperation: 1
        )
        expect(verdict == .clear)
    }

    func userHoldingMouseButtonWins() throws {
        let verdict = sentinel.preflight(
            expectedCursor: CGPoint(x: 600, y: 1_188),
            actualCursor: CGPoint(x: 600, y: 1_188),
            isMouseDown: true,
            elapsedSinceLastOperation: 1
        )
        expect(verdict == .userInteracting)
    }

    /// 20pt 漂移：正是「幽灵点击 / 光标被劫持」的信号，必须中止
    func cursorDriftIsDetected() throws {
        let verdict = sentinel.preflight(
            expectedCursor: CGPoint(x: 600, y: 1_188),
            actualCursor: CGPoint(x: 620, y: 1_188),
            isMouseDown: false,
            elapsedSinceLastOperation: 1
        )
        guard case .cursorDrift(let distance, _) = verdict else {
            try record("应判定为光标漂移，实际：\(verdict)")
            return
        }
        expect(abs(distance - 20) < 0.001)
    }

    func rapidOperationsAreThrottled() throws {
        let verdict = sentinel.preflight(
            expectedCursor: .zero,
            actualCursor: .zero,
            isMouseDown: false,
            elapsedSinceLastOperation: 0.01
        )
        expect(verdict == .throttled)
    }

    func toleranceBoundaryIsInclusive() throws {
        // 恰好等于容差应放行，避免边界抖动
        let atLimit = sentinel.preflight(
            expectedCursor: CGPoint(x: 600, y: 1_188),
            actualCursor: CGPoint(x: 604, y: 1_188),
            isMouseDown: false,
            elapsedSinceLastOperation: 1
        )
        expect(atLimit == .clear)
    }

    func postflightCatchesWrongLanding() throws {
        let verdict = sentinel.postflight(cursorAfterEvent: CGPoint(x: 400, y: 1_188), expectedLanding: CGPoint(x: 600, y: 1_188))
        expect(verdict != .clear)
    }
}

struct LayoutJournalTests {
    private var layout: MenuBarLayout {
        var layout = MenuBarLayout()
        layout.append("com.test.a", to: .visible)
        layout.append("com.test.b", to: .hidden)
        return layout
    }

    func committedRoundTrip() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("committed"))
        try journal.writeCommitted(layout)

        expect(journal.readCommittedLayout() == layout)
        expect(!journal.hasPendingIntent)
    }

    func recoveryDistinguishesCleanFromInterrupted() throws {
        switch LayoutJournal.recover(committed: layout, pending: nil) {
        case .clean(let restored):
            expect(restored == layout)
        case .interrupted:
            try record("无 pending 时应为 clean")
        }

        let intent = LayoutJournal.LayoutIntent(
            itemID: "com.test.b",
            targetZone: .hidden,
            targetPosition: nil,
            previousZone: .visible,
            previousPosition: 0
        )
        switch LayoutJournal.recover(committed: layout, pending: intent) {
        case .clean:
            try record("存在孤儿意图时不得当作 clean 启动")
        case .interrupted(let recovered, let committed):
            expect(recovered == intent)
            expect(committed == layout)
        }
    }

    /// 重放意图：崩溃前「想把 b 移到隐藏区」的意图必须优先于系统当前状态
    func applyingIntentRebuildsIntendedLayout() throws {
        var layout = MenuBarLayout()
        layout.append("com.test.b", to: .visible)
        layout.append("com.test.a", to: .visible)

        let intent = LayoutJournal.LayoutIntent(
            itemID: "com.test.b",
            targetZone: .hidden,
            targetPosition: nil,
            previousZone: .visible,
            previousPosition: 0
        )
        let replayed = LayoutJournal.applying(intent, to: layout)

        expect(replayed.items(in: .visible) == ["com.test.a"])
        expect(replayed.items(in: .hidden) == ["com.test.b"])
    }

    func pendingFileIsClearedOnlyAfterCommit() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("pending"))
        let intent = LayoutJournal.LayoutIntent(itemID: "x", targetZone: .hidden, targetPosition: nil, previousZone: nil, previousPosition: nil)

        try journal.writeIntent(intent)
        expect(journal.hasPendingIntent)
        expect(journal.readPendingIntent()?.itemID == "x")

        try journal.clearPendingIntent()
        expect(!journal.hasPendingIntent)
        // 重复清除不应抛错
        try journal.clearPendingIntent()
    }
}

extension EventSentinelTests {
    static var testCases: [TestCase] {
        let suite = EventSentinelTests()
        return [
            TestCase("preflightPassesOnQuietSystem", suite.preflightPassesOnQuietSystem),
            TestCase("userHoldingMouseButtonWins", suite.userHoldingMouseButtonWins),
            TestCase("cursorDriftIsDetected", suite.cursorDriftIsDetected),
            TestCase("rapidOperationsAreThrottled", suite.rapidOperationsAreThrottled),
            TestCase("toleranceBoundaryIsInclusive", suite.toleranceBoundaryIsInclusive),
            TestCase("postflightCatchesWrongLanding", suite.postflightCatchesWrongLanding),
        ]
    }
}

extension LayoutJournalTests {
    static var testCases: [TestCase] {
        let suite = LayoutJournalTests()
        return [
            TestCase("committedRoundTrip", suite.committedRoundTrip),
            TestCase("recoveryDistinguishesCleanFromInterrupted", suite.recoveryDistinguishesCleanFromInterrupted),
            TestCase("applyingIntentRebuildsIntendedLayout", suite.applyingIntentRebuildsIntendedLayout),
            TestCase("pendingFileIsClearedOnlyAfterCommit", suite.pendingFileIsClearedOnlyAfterCommit),
        ]
    }
}
