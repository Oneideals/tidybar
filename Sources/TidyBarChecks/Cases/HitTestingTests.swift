import CoreGraphics
import Foundation
import TidyBarCore

struct HitTestingTests {
    func observationTokensDoNotChangeIdentityOrPersist() throws {
        let discovery = ManagedItem.Discovery(ownerBundleID: "com.test.same", axTitle: "same",
            frame: CGRect(x: 100, y: 1176, width: 24, height: 24), isSystemOwned: false, identitySource: .axTitle)
        let first = discovery.item, second = discovery.item
        expectNotNil(first.observationToken)
        expectNotEqual(first.observationToken, second.observationToken)
        expectEqual(first, second, "AX 观测换代不应改变界面值或持久化身份")
        let restored = try JSONDecoder().decode(ManagedItem.self, from: JSONEncoder().encode(first))
        expectNil(restored.observationToken)
        expectEqual(restored, first)
        let deduplicated = MenuBarEnumeration.deduplicatedIDs(from: [first, second])
        expectEqual(deduplicated[1].observationToken, second.observationToken, "同名后缀不得丢失其具体 AX 绑定")
    }
    private final class Reader: MenuBarReading {
        var a = TestItems.item("a")
        var b = TestItems.item("b", centerX: 700)
        var verdict: (ManagedItem?, CGPoint) -> MenuBarHitOutcome = { _, _ in .verified }
        var checked: [(String?, CGPoint)] = []
        var currentFrames: [String: CGRect] = [:]
        func discoverItems() -> [ManagedItem] { [a, b] }
        func currentFrame(of item: ManagedItem) -> CGRect? { currentFrames[item.id] ?? item.frame }
        func hitTest(expected item: ManagedItem?, at point: CGPoint) -> MenuBarHitOutcome {
            checked.append((item?.id, point))
            return verdict(item, point)
        }
    }

    func blockedEndpointsNeverPostInput() throws {
        for sourceBlocked in [true, false] {
            for outcome in [MenuBarHitOutcome.occluded, .unavailable] {
                let reader = Reader()
                reader.verdict = { item, _ in item?.id == (sourceBlocked ? "a" : "b") ? outcome : .verified }
                let poster = RecordingDragEventPoster()
                let mover = AccessibilityMenuBarMover(reader: reader, cursor: FakeCursor(), poster: poster,
                    config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
                expect(throws: sourceBlocked ? .sourceNotInteractable("a") : MenuBarMoveError.targetNotInteractable) {
                    try mover.move(itemID: "a", toX: 700, expectedTargets: [reader.b], isCancelled: { false })
                }
                expect(poster.posted.isEmpty, "命中帮助菜单、兄弟项或未知节点时，不能按坐标盲发输入")
            }
        }
    }

    func sourceMustStillBeReachableAfterWarp() throws {
        let reader = Reader()
        let poster = RecordingDragEventPoster()
        let mover = AccessibilityMenuBarMover(reader: reader, cursor: FakeCursor(), poster: poster,
            config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
        poster.onPost = { event in
            if case .warp = event { reader.verdict = { item, _ in item?.id == "a" ? .occluded : .verified } }
        }
        expect(throws: MenuBarMoveError.sourceNotInteractable("a")) {
            try mover.move(itemID: "a", toX: 700, expectedTargets: [reader.b], isCancelled: { false })
        }
        expect(!poster.contains("mouseDown") && !poster.contains("commandDown"))
        expect(reader.checked.contains { $0.0 == "b" && $0.1.x == 700 }, "验证的是实际投递点")
        expect(!mover.isDragInFlight)
    }

    func inputChangesDuringHitTestingPreventMouseDown() throws {
        for physicalCommand in [false, true] {
            for change in ["button", "cursor", "cancel"] {
                let reader = Reader()
                let cursor = FakeCursor()
                let poster = RecordingDragEventPoster()
                let mover = AccessibilityMenuBarMover(reader: reader, cursor: cursor, poster: poster,
                    config: .init(settleInterval: 0, initialHoldInterval: 0,
                                  postsPhysicalCommandKey: physicalCommand, isConfirmedSupportedOS: true))
                var targetChecks = 0
                var cancelled = false
                reader.verdict = { item, _ in
                    if item?.id == "b" {
                        targetChecks += 1
                        if targetChecks == (physicalCommand ? 3 : 2) {
                            if change == "button" { cursor.isPrimaryButtonPressed = true }
                            if change == "cursor" { cursor.currentLocation.x += 40 }
                            if change == "cancel" { cancelled = true }
                        }
                    }
                    return .verified
                }
                expectThrows {
                    try mover.move(itemID: "a", toX: 700, expectedTargets: [reader.b], isCancelled: { cancelled })
                }
                expect(!poster.contains("mouseDown"), "AX 查询期间的 \(change) 必须在按下前重新检查")
                expect(!mover.isDragInFlight)
                if physicalCommand { expect(poster.contains("commandUp")) }
            }
        }
    }

    func pressDuringInitialHitTestPreventsEvenWarp() throws {
        let reader = Reader()
        let cursor = FakeCursor()
        let poster = RecordingDragEventPoster()
        let mover = AccessibilityMenuBarMover(reader: reader, cursor: cursor, poster: poster,
            config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
        reader.verdict = { item, _ in
            if item?.id == "b" { cursor.isPrimaryButtonPressed = true }
            return .verified
        }
        expect(throws: MenuBarMoveError.abortedBySentinel(.userInteracting)) {
            try mover.move(itemID: "a", toX: 700, expectedTargets: [reader.b], isCancelled: { false })
        }
        expect(poster.posted.isEmpty, "首次 AX 查询期间用户按住鼠标，连光标也不能移动")
    }

    func landingUsesTheCurrentAnchorFrame() throws {
        for afterAnchor in [false, true] {
            let reader = Reader()
            reader.currentFrames["b"] = CGRect(x: 738, y: 1176, width: 44, height: 24)
            reader.verdict = { item, _ in item?.id == "b" ? .occluded : .verified }
            let poster = RecordingDragEventPoster()
            let mover = AccessibilityMenuBarMover(reader: reader, cursor: FakeCursor(), poster: poster,
                config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
            let oldTarget = afterAnchor ? reader.b.frame.maxX + 2 : reader.b.centerX
            expect(throws: MenuBarMoveError.targetNotInteractable) {
                try mover.move(itemID: "a", toX: oldTarget, expectedTargets: [reader.b], isCancelled: { false })
            }
            expect(reader.checked.contains { $0.0 == "b" && $0.1.x == (afterAnchor ? 784 : 760) },
                   "目标整体平移、宽度改变后，不能继续命中旧坐标")
            expect(poster.posted.isEmpty)
        }
    }

    func refreshedAnchorOnAnotherDisplayNeverPostsInput() throws {
        for offset: CGFloat in [-1440, 1440] {
            for afterAnchor in [false, true] {
                let reader = Reader()
                reader.currentFrames["b"] = reader.b.frame.offsetBy(dx: offset, dy: 0)
                let cursor = FakeCursor()
                cursor.displayConfiguration = [
                    1: CGRect(x: 0, y: 0, width: 1440, height: 1200),
                    2: CGRect(x: offset, y: 0, width: 1440, height: 1200)
                ]
                let poster = RecordingDragEventPoster()
                let mover = AccessibilityMenuBarMover(reader: reader, cursor: cursor, poster: poster,
                    config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
                let oldTarget = afterAnchor ? reader.b.frame.maxX + 2 : reader.b.centerX
                expect(throws: MenuBarMoveError.targetNotInteractable) {
                    try mover.move(itemID: "a", toX: oldTarget, expectedTargets: [reader.b], isCancelled: { false })
                }
                expect(poster.posted.isEmpty, "拓扑未变但锚点移到另一屏时，连光标也不能移动")
            }
        }
    }

    func refreshedAnchorWithinTheSameDisplayCanMove() throws {
        for secondary in [false, true] {
            let reader = Reader()
            if secondary {
                reader.a = TestItems.item("a", centerX: 2000, centerY: 988)
                reader.b = TestItems.item("b", centerX: 2100, centerY: 988)
            }
            let currentFrame = reader.b.frame.offsetBy(dx: 38, dy: 0)
            reader.currentFrames["b"] = currentFrame
            let cursor = FakeCursor()
            cursor.displayConfiguration = [
                1: CGRect(x: 0, y: 0, width: 1440, height: 1200),
                2: CGRect(x: 1440, y: 200, width: 1200, height: 900)
            ]
            let poster = RecordingDragEventPoster()
            poster.onPost = { event in
                switch event {
                case .warp(let point), .mouseDown(let point), .mouseDragged(let point), .mouseUp(let point):
                    cursor.currentLocation = point
                default: break
                }
            }
            let mover = AccessibilityMenuBarMover(reader: reader, cursor: cursor, poster: poster,
                config: .init(settleInterval: 0, initialHoldInterval: 0, isConfirmedSupportedOS: true))
            let landing = try mover.move(itemID: "a", toX: reader.b.centerX,
                                         expectedTargets: [reader.b], isCancelled: { false })
            expectEqual(landing, CGPoint(x: currentFrame.midX, y: reader.a.frame.midY),
                        "主屏或偏移副屏内的有效坐标刷新仍应完成")
            expect(poster.contains("mouseDown") && poster.contains("mouseUp"))
        }
    }

    static var testCases: [TestCase] {
        let suite = Self()
        return [TestCase("observationTokensDoNotChangeIdentityOrPersist", suite.observationTokensDoNotChangeIdentityOrPersist),
                TestCase("blockedEndpointsNeverPostInput", suite.blockedEndpointsNeverPostInput),
                TestCase("sourceMustStillBeReachableAfterWarp", suite.sourceMustStillBeReachableAfterWarp),
                TestCase("inputChangesDuringHitTestingPreventMouseDown", suite.inputChangesDuringHitTestingPreventMouseDown),
                TestCase("pressDuringInitialHitTestPreventsEvenWarp", suite.pressDuringInitialHitTestPreventsEvenWarp),
                TestCase("landingUsesTheCurrentAnchorFrame", suite.landingUsesTheCurrentAnchorFrame),
                TestCase("refreshedAnchorOnAnotherDisplayNeverPostsInput", suite.refreshedAnchorOnAnotherDisplayNeverPostsInput),
                TestCase("refreshedAnchorWithinTheSameDisplayCanMove", suite.refreshedAnchorWithinTheSameDisplayCanMove)]
    }
}
