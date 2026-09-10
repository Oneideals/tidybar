import Foundation
import CoreGraphics
import TidyBarCore

private final class RelayCursor: CursorReading {
    var currentLocation = CGPoint(x: 500, y: 1100)
    var isPrimaryButtonPressed = false
    var isSecondaryButtonPressed = false
    var isSessionInteractive = true
    var displayConfiguration: [CGDirectDisplayID: CGRect]? = [1: CGRect(x: 0, y: 0, width: 1920, height: 1200)]
    var userIdleTime: TimeInterval = .infinity
}

private final class RelayReader: MenuBarReading {
    var item = TestItems.item("target", centerX: 600)
    var hit: MenuBarHitOutcome = .verified
    var duringHit: (() -> Void)?
    var menuSamples: [Bool?] = [false]
    var reads = 0
    var discoverCount = 0
    var onDiscover: (() -> Void)?
    func discoverItems() -> [ManagedItem] {
        discoverCount += 1
        onDiscover?()
        return [item]
    }
    func currentFrame(of item: ManagedItem) -> CGRect? { self.item.frame }
    func hitTest(expected item: ManagedItem?, at point: CGPoint) -> MenuBarHitOutcome {
        duringHit?()
        return hit
    }
    func isMenuPresented(for item: ManagedItem) -> Bool? {
        reads += 1
        return menuSamples.count > 1 ? menuSamples.removeFirst() : menuSamples.first ?? nil
    }
}

struct ClickRelayTests {
    private let screens = FakeScreens(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1200)).screens

    @MainActor private func waitFor(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(predicate(), "后台点击或菜单观察没有完成")
    }

    func primaryAndSecondaryUseDifferentNativeButtons() throws {
        MainActor.assumeIsolated {
            for button in [MenuBarClickRelay.Button.primary, .secondary] {
                let reader = RelayReader(), cursor = RelayCursor()
                var events: [CGEvent] = []
                let relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 0,
                    eventSink: { event in
                        events.append(event)
                        cursor.currentLocation = CGPoint(x: event.location.x,
                            y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
                        return true
                    })
                var result: ActivationOutcome?
                var feedback: [ActivationOutcome] = []
                expect(relay.start(.init(item: reader.item, button: button, cursor: cursor), screens: screens,
                    onActivation: { feedback.append($0) }, completion: { result = $0 }))
                waitFor { result != nil }
                let secondary = button == .secondary
                expectEqual(events.map(\.type), [.mouseMoved, secondary ? .rightMouseDown : .leftMouseDown,
                                                secondary ? .rightMouseUp : .leftMouseUp])
                expect(events.allSatisfy { $0.flags.isEmpty }, "代理点击不得带 Command 或其他修饰键")
                expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == CGDragEventPoster.syntheticEventTag })
                expectEqual(events.last?.getIntegerValueField(.mouseEventButtonNumber), secondary ? 1 : 0)
                expectEqual(result, .pressed)
                expectEqual(feedback, [.pressed], "没有可见菜单证据时不得报告菜单已打开")
                expect(!relay.isRunning)
            }
        }
    }

    func waitsForUnfoldedFramesAndStillYieldsToUserInput() throws {
        MainActor.assumeIsolated {
            for interrupted in [false, true] {
                let reader = RelayReader(), cursor = RelayCursor()
                reader.item.frame.origin.x = -1400
                reader.onDiscover = {
                    if reader.discoverCount >= 3 { reader.item.frame.origin.x = 588 }
                    if interrupted && reader.discoverCount == 2 { cursor.currentLocation.x += 30 }
                }
                var events: [CGEventType] = [], result: ActivationOutcome?
                let relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 0,
                    eventSink: { event in
                        expect(reader.item.frame.minX >= 0, "展开稳定前不能投递点击")
                        events.append(event.type)
                        cursor.currentLocation = CGPoint(x: event.location.x,
                            y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
                        return true
                    })
                relay.start(.init(item: reader.item, button: .secondary, cursor: cursor), screens: screens,
                            onActivation: { _ in }, completion: { result = $0 })
                waitFor { result != nil }
                expectEqual(result, interrupted ? .interrupted : .pressed)
                expectEqual(events, interrupted ? [] : [.mouseMoved, .rightMouseDown, .rightMouseUp])
            }
        }
    }

    func rejectsStaleOrUnsafeTargetsBeforeMouseDown() throws {
        MainActor.assumeIsolated {
            for scenario in ["occluded", "folded", "held-secondary", "locked", "pointer-moved", "screen-changed", "typing"] {
                let reader = RelayReader(), cursor = RelayCursor()
                let request = MenuBarClickRelay.Request(item: reader.item, button: .secondary, cursor: cursor)
                switch scenario {
                case "occluded": reader.hit = .occluded
                case "folded": reader.item.frame.origin.x = -1400
                case "held-secondary": cursor.isSecondaryButtonPressed = true
                case "locked": cursor.isSessionInteractive = false
                case "pointer-moved": reader.duringHit = { cursor.currentLocation.x += 30 }
                case "screen-changed": reader.duringHit = { cursor.displayConfiguration = [:] }
                case "typing": reader.duringHit = { cursor.userIdleTime = -1 }
                default: break
                }
                var emitted = 0, result: ActivationOutcome?
                let relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 0,
                                             eventSink: { _ in emitted += 1; return true })
                relay.start(request, screens: screens, onActivation: { _ in }, completion: { result = $0 })
                waitFor { result != nil }
                expectEqual(emitted, 0, "目标或用户输入变化后不能发送任何鼠标事件：\(scenario)")
                expect(result?.countsAsPressed == false, scenario)
            }
        }
    }

    func cancellationAfterDownStillReleasesTheSameButton() throws {
        MainActor.assumeIsolated {
            let reader = RelayReader(), cursor = RelayCursor()
            var events: [CGEventType] = []
            let movedPointer = CGPoint(x: 810, y: 900)
            var releasePoint: CGPoint?
            var relay: MenuBarClickRelay!
            relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 0,
                eventSink: { event in
                    events.append(event.type)
                    cursor.currentLocation = CGPoint(x: event.location.x,
                        y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
                    if event.type == .rightMouseDown {
                        cursor.currentLocation = movedPointer
                        cursor.displayConfiguration = [:]
                        DispatchQueue.main.sync { relay.cancel() }
                    }
                    if event.type == .rightMouseUp { releasePoint = cursor.currentLocation }
                    return true
                })
            var result: ActivationOutcome?
            relay.start(.init(item: reader.item, button: .secondary, cursor: cursor), screens: screens,
                        onActivation: { _ in }, completion: { result = $0 })
            waitFor { result != nil }
            expectEqual(result, .interrupted)
            expectEqual(events, [.mouseMoved, .rightMouseDown, .rightMouseUp], "取消后必须释放同一右键，且只释放一次")
            expectEqual(releasePoint, movedPointer, "中断或换屏后须在当前光标位置释放，不能跳回旧图标坐标")
            var drained = false
            relay.cancelAndDrain { drained = true }
            waitFor { drained }
            expect(!relay.isRunning)
        }
    }

    func incompleteMenuInspectionIsUnknownInsteadOfClosed() throws {
        let exhausted = AccessibilityMenuBarReader.visibleMenuInTree(roots: [0], nodeLimit: 2) { node in
            (node == 3, node < 3 ? [node + 1] : [])
        }
        expectNil(exhausted, "菜单可能在未读完的分支中，预算耗尽不能表示关闭")
        let failed = AccessibilityMenuBarReader.visibleMenuInTree(roots: [0, 1]) { node in
            node == 1 ? nil : (false, [])
        }
        expectNil(failed, "AX 暂时失败不能变成已确认关闭")
        expectEqual(AccessibilityMenuBarReader.visibleMenuInTree(roots: [0]) { _ in (false, []) }, false)
        expectEqual(AccessibilityMenuBarReader.visibleMenuInTree(roots: [0, 1]) { node in
            node == 0 ? nil : (true, [])
        }, true, "可见菜单证据不应被其他读取失败掩盖")
    }

    func nativeStatusPopoversAreRecognizedAsOpenMenus() throws {
        // AdGuard 真机：右键打开的是自绘的 360×670 原生面板，而非 AXMenu。
        let icon = CGRect(x: 831, y: 3, width: 26, height: 24)
        let popup = CGRect(x: 823, y: 31, width: 360, height: 670)
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        expect(AccessibilityMenuBarReader.isStatusPopup(frame: popup, level: level, itemFrame: icon))
        expect(!AccessibilityMenuBarReader.isStatusPopup(frame: popup, level: 0, itemFrame: icon),
               "普通应用窗口不能永久占住菜单访问")
        expect(!AccessibilityMenuBarReader.isStatusPopup(frame: icon, level: level, itemFrame: icon))
        expect(!AccessibilityMenuBarReader.isStatusPopup(frame: popup.offsetBy(dx: -700, dy: 0), level: level, itemFrame: icon))
        expect(!AccessibilityMenuBarReader.isStatusPopup(frame: popup.offsetBy(dx: 0, dy: 300), level: level, itemFrame: icon))
    }

    func prolongedUnknownMenuStateReleasesTheInputQueueWithoutClaimingClosure() throws {
        MainActor.assumeIsolated {
            let reader = RelayReader(), cursor = RelayCursor()
            reader.menuSamples = [true, nil]
            let relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 0.1,
                eventSink: { event in
                    cursor.currentLocation = CGPoint(x: event.location.x,
                        y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
                    return true
                })
            var result: ActivationOutcome?
            relay.start(.init(item: reader.item, button: .secondary, cursor: cursor), screens: screens,
                        onActivation: { _ in }, completion: { result = $0 })
            let deadline = Date().addingTimeInterval(0.8)
            while result == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            expectEqual(result, .menuObservationUnavailable, "菜单状态一直未知时也应有界交还控制，不能伪装成已关闭")
            expect(!relay.isRunning)
            var drained = false
            relay.cancelAndDrain { drained = true }
            waitFor { drained }
        }
    }

    func keepsMenuAccessUntilVisibleMenuCloses() throws {
        MainActor.assumeIsolated {
            let reader = RelayReader(), cursor = RelayCursor()
            reader.menuSamples = [false, true, true, false, true, false, false]
            let relay = MenuBarClickRelay(reader: reader, cursor: cursor, settleInterval: 0, observationTimeout: 1,
                eventSink: { event in
                    cursor.currentLocation = CGPoint(x: event.location.x,
                        y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
                    return true
                })
            var result: ActivationOutcome?, feedback: [ActivationOutcome] = []
            relay.start(.init(item: reader.item, button: .secondary, cursor: cursor), screens: screens,
                onActivation: { outcome in
                    feedback.append(outcome)
                    expect(relay.isRunning, "菜单打开的反馈不得提前释放访问会话")
                }, completion: { result = $0 })
            waitFor { result != nil }
            expectEqual(result, .menuPresented)
            expectEqual(feedback, [.pressed, .menuPresented])
            expectEqual(reader.reads, 7, "单帧菜单缺失可能是子菜单切换，必须确认关闭后才收起")
        }
    }
}

extension ClickRelayTests {
    static var testCases: [TestCase] {
        let suite = ClickRelayTests()
        return [
            TestCase("primaryAndSecondaryUseDifferentNativeButtons", suite.primaryAndSecondaryUseDifferentNativeButtons),
            TestCase("waitsForUnfoldedFramesAndStillYieldsToUserInput", suite.waitsForUnfoldedFramesAndStillYieldsToUserInput),
            TestCase("rejectsStaleOrUnsafeTargetsBeforeMouseDown", suite.rejectsStaleOrUnsafeTargetsBeforeMouseDown),
            TestCase("cancellationAfterDownStillReleasesTheSameButton", suite.cancellationAfterDownStillReleasesTheSameButton),
            TestCase("keepsMenuAccessUntilVisibleMenuCloses", suite.keepsMenuAccessUntilVisibleMenuCloses),
            TestCase("incompleteMenuInspectionIsUnknownInsteadOfClosed", suite.incompleteMenuInspectionIsUnknownInsteadOfClosed),
            TestCase("nativeStatusPopoversAreRecognizedAsOpenMenus", suite.nativeStatusPopoversAreRecognizedAsOpenMenus),
            TestCase("prolongedUnknownMenuStateReleasesTheInputQueueWithoutClaimingClosure", suite.prolongedUnknownMenuStateReleasesTheInputQueueWithoutClaimingClosure),
        ]
    }
}
