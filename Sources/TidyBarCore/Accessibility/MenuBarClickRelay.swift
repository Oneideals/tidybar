import Foundation
import CoreGraphics

/// 抽屉只代理一次完整点击。真实输入与菜单关闭检测均在串行队列，不阻塞 AppKit 菜单跟踪。
@MainActor
public final class MenuBarClickRelay {
    public enum Button: Sendable { case primary, secondary }

    public struct Request: Sendable {
        public let item: ManagedItem
        public let button: Button
        let pointer: CGPoint
        let displays: [CGDirectDisplayID: CGRect]?
        let uptime: TimeInterval

        public init(item: ManagedItem, button: Button, cursor: CursorReading) {
            self.item = item
            self.button = button
            pointer = cursor.currentLocation
            displays = cursor.displayConfiguration
            uptime = ProcessInfo.processInfo.systemUptime
        }
    }

    private struct IO: @unchecked Sendable {
        let reader: MenuBarReading
        let cursor: CursorReading
        let send: (CGEvent) -> Bool
    }
    private let io: IO
    private let queue = DispatchQueue(label: "local.tidybar.click-relay", qos: .userInitiated)
    private let settleInterval: TimeInterval
    private let observationTimeout: TimeInterval
    private var active: Progress?
    public var isRunning: Bool { active != nil }
    public var hasSentClick: Bool { (active?.completedUnitCount ?? 0) > 0 }

    public init(reader: MenuBarReading, cursor: CursorReading,
                settleInterval: TimeInterval = 0.04, observationTimeout: TimeInterval = 1.5,
                eventSink: @escaping (CGEvent) -> Bool = { $0.post(tap: .cghidEventTap); return true }) {
        io = IO(reader: reader, cursor: cursor, send: eventSink)
        self.settleInterval = settleInterval
        self.observationTimeout = observationTimeout
    }

    @discardableResult
    public func start(_ request: Request, screens: [ScreenInfo],
                      onActivation: @escaping @MainActor (ActivationOutcome) -> Void,
                      completion: @escaping @MainActor (ActivationOutcome) -> Void) -> Bool {
        guard active == nil else { return false }
        let progress = Progress(totalUnitCount: 1)
        active = progress
        let io = self.io, settle = settleInterval, timeout = observationTimeout
        queue.async {
            let result = Self.click(request, screens: screens, io: io, progress: progress,
                                    settle: settle, timeout: timeout) { outcome in
                DispatchQueue.main.async { onActivation(outcome) }
            }
            DispatchQueue.main.async {
                guard self.active === progress else { return }
                self.active = nil
                completion(result)
            }
        }
        return true
    }

    public func cancel() { active?.cancel() }

    public func cancelAndDrain(_ completion: @escaping @MainActor () -> Void) {
        cancel()
        queue.async { DispatchQueue.main.async { completion() } }
    }

    nonisolated private static func click(_ request: Request, screens: [ScreenInfo], io: IO,
                                          progress: Progress, settle: TimeInterval, timeout: TimeInterval,
                                          notify: (ActivationOutcome) -> Void) -> ActivationOutcome {
        func sessionIsCurrent() -> Bool {
            !progress.isCancelled && io.cursor.isSessionInteractive
                && io.cursor.displayConfiguration == request.displays
        }
        func pointerIsAt(_ point: CGPoint) -> Bool {
            let current = io.cursor.currentLocation
            return hypot(current.x - point.x, current.y - point.y) <= 6
        }
        func buttonsReleased() -> Bool { !io.cursor.isPrimaryButtonPressed && !io.cursor.isSecondaryButtonPressed }
        func requestIsCurrent() -> Bool {
            sessionIsCurrent() && buttonsReleased() && pointerIsAt(request.pointer)
                && io.cursor.userIdleTime + 0.05 >= ProcessInfo.processInfo.systemUptime - request.uptime
        }
        guard requestIsCurrent() else { return .interrupted }
        // NSStatusItem.length 与短应用菜单都异步生效；等待两次相同的可点击帧，再发送输入。
        let preparationDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        var previousFrame: CGRect?
        var prepared: (ManagedItem, CGRect)?
        var failure: ActivationOutcome = .notInteractable
        repeat {
            guard requestIsCurrent() else { return .interrupted }
            let candidates = request.item.ownerBundleID.map { io.reader.items(ownedBy: $0) } ?? io.reader.discoverItems()
            if let item = candidates.first(where: { $0.id == request.item.id }) {
                guard item.ownerBundleID == request.item.ownerBundleID,
                      item.identitySource != .ownerOrdinal || (item.ownerItemCount == request.item.ownerItemCount
                            && item.ordinalInOwner == request.item.ordinalInOwner) else { return .elementNotFound }
                failure = .notInteractable
                if let frame = io.reader.currentFrame(of: item),
                   let screen = screens.first(where: { IconCaptureGeometry.isVisibleMenuBarFrame(frame, on: $0) }),
                   screen.notchWidth.map({ $0 <= 0 || abs(frame.midX - screen.frame.midX) > $0 / 2 }) ?? true,
                   io.reader.hitTest(expected: item, at: CGPoint(x: frame.midX, y: frame.midY)) == .verified,
                   io.reader.currentFrame(of: item) == frame {
                    if previousFrame == frame { prepared = (item, frame); break }
                    previousFrame = frame
                } else { previousFrame = nil }
            } else { previousFrame = nil; failure = .itemNotFound }
            if ProcessInfo.processInfo.systemUptime >= preparationDeadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        guard requestIsCurrent() else { return .interrupted }
        guard let (item, frame) = prepared else { return failure }
        let point = CGPoint(x: frame.midX, y: frame.midY)

        let secondary = request.button == .secondary
        let source = CGEventSource(stateID: .combinedSessionState)
        let cgPoint = CGDragEventPoster.cgPoint(for: point, primaryScreenHeight: CGDisplayBounds(CGMainDisplayID()).height)
        func event(_ type: CGEventType) -> CGEvent? {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cgPoint,
                                      mouseButton: secondary ? .right : .left) else { return nil }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: CGDragEventPoster.syntheticEventTag)
            return event
        }
        guard let move = event(.mouseMoved), let down = event(secondary ? .rightMouseDown : .leftMouseDown),
              let up = event(secondary ? .rightMouseUp : .leftMouseUp) else { return .failed(code: -1) }
        guard io.send(move) else { return .failed(code: -1) }
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        guard sessionIsCurrent(), buttonsReleased(), pointerIsAt(point) else { return .interrupted }
        guard io.reader.currentFrame(of: item) == frame,
              io.reader.hitTest(expected: item, at: point) == .verified else { return .notInteractable }
        guard sessionIsCurrent(), buttonsReleased(), pointerIsAt(point) else { return .interrupted }
        var owesMouseUp = true
        func release() -> Bool {
            if !sessionIsCurrent() || !pointerIsAt(point) {
                up.location = CGDragEventPoster.cgPoint(for: io.cursor.currentLocation,
                    primaryScreenHeight: CGDisplayBounds(CGMainDisplayID()).height)
            }
            return io.send(up)
        }
        defer { if owesMouseUp { _ = release() } }
        progress.completedUnitCount = 1
        guard io.send(down) else { return .failed(code: -1) }
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        // 取消/锁屏也须释放由我们按下的键，不能把释放排在可取消步骤之后。
        guard release() else { return .failed(code: -1) }
        owesMouseUp = false
        guard sessionIsCurrent() else { return .interrupted }
        notify(.pressed)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var observedMenu = false, absentSamples = 0
        var unknownSince: TimeInterval?
        repeat {
            guard sessionIsCurrent() else { return .interrupted }
            let state = io.reader.isMenuPresented(for: item)
            let now = ProcessInfo.processInfo.systemUptime
            if let visible = state {
                unknownSince = nil
                if visible {
                    if !observedMenu { notify(.menuPresented) }
                    observedMenu = true
                    absentSamples = 0
                } else if observedMenu {
                    absentSamples += 1
                    if absentSamples >= 2 { return .menuPresented }
                }
            } else {
                absentSamples = 0
                if unknownSince == nil { unknownSince = now }
                if now - unknownSince! >= max(0.2, timeout) { return .menuObservationUnavailable }
            }
            if !observedMenu && now >= deadline { return state == nil ? .menuObservationUnavailable : .pressed }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
    }
}
