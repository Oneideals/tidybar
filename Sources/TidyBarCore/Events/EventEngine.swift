import Foundation
import AppKit

/// 事件引擎：优先事件驱动、轮询仅作兜底（报告 §4.3 空闲 CPU ≈ 0% 的前提）。
///
/// 三层监听（对标同类实现的 GlobalEventMonitor / LocalEventMonitor / RunLoop 监听分层）：
/// - global：App 失焦时也能收到菜单栏区域的鼠标事件（需辅助功能权限）
/// - local：面板自身展开时的交互（点击图标、关闭）
/// - throttled：悬停/滚动这类高频事件必须节流，否则空闲 CPU 会失控
public final class EventEngine {
    public struct Event: Equatable, Sendable {
        public let trigger: RevealTrigger
        public let location: CGPoint
        public init(trigger: RevealTrigger, location: CGPoint) {
            self.trigger = trigger
            self.location = location
        }
    }

    /// 高频事件节流窗口（秒）。Ice 的轮询默认 100ms；本项目事件驱动，200ms 足够顺滑。
    public let throttleInterval: TimeInterval

    /// 点击菜单栏区域 = 呼出；点击别处 = 收起
    public var onEvent: ((Event) -> Void)?
    public var onConcealRequest: (() -> Void)?

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var lastHandled: [RevealTrigger: TimeInterval] = [:]
    public private(set) var isRunning = false

    public init(throttleInterval: TimeInterval = 0.2) {
        self.throttleInterval = throttleInterval
    }

    // MARK: - 生命周期

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        globalMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self else { return }
                let mouseLoc = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSPointInRect(mouseLoc, $0.frame) } ?? NSScreen.main
                let screenTopY = screen?.frame.maxY ?? 0
                let menuBarHeight: CGFloat = 34
                switch EventEngine.classifyMenuBarHit(eventLocationY: mouseLoc.y, screenTopY: screenTopY, menuBarHeight: menuBarHeight) {
                case .insideMenuBar:
                    self.handle(.init(trigger: .emptyBarClick, location: mouseLoc))
                case .outsideMenuBar:
                    self.onConcealRequest?()
                }
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self else { return }
                // 右键只做收起判定，不触发 emptyBarClick——
                // 否则右键点折叠图标弹菜单的同时会误开抽屉
                self.onConcealRequest?()
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self else { return }
                let location = NSEvent.mouseLocation
                self.handle(.init(trigger: self.classify(hover: event), location: location), throttled: .hover)
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .otherMouseDragged]) { [weak self] event in
                guard let self else { return }
                self.handle(.init(trigger: .scrollOrSwipe, location: NSEvent.mouseLocation), throttled: .scrollOrSwipe)
            },
        ].compactMap { $0 }
    }

    public func stop() {
        guard isRunning else { return }
        (globalMonitors + localMonitors).forEach { NSEvent.removeMonitor($0) }
        globalMonitors = []
        localMonitors = []
        isRunning = false
    }

    // MARK: - 判定

    /// 纯函数：节流窗口内的同类事件只放行一次。时间由调用方注入，便于单测。
    public func passesThrottle(_ trigger: RevealTrigger, now: TimeInterval) -> Bool {
        guard trigger == .hover || trigger == .scrollOrSwipe else { return true }
        // 首次事件没有「上一次」，不得被当作 0 间隔吞掉
        if let last = lastHandled[trigger], now - last < throttleInterval { return false }
        lastHandled[trigger] = now
        return true
    }

    private func handle(_ event: Event, throttled trigger: RevealTrigger? = nil) {
        if let trigger, !passesThrottle(trigger, now: ProcessInfo.processInfo.systemUptime) {
            return
        }
        onEvent?(event)
    }

    /// 纯函数：点击落在菜单栏高度带内视为分隔符/空白区命中，否则视为「点别处」→ 收起请求。
    /// M1 接入真实图标快照后，会把判定细化到「命中哪个分隔符」。
    public static func classifyMenuBarHit(eventLocationY y: CGFloat, screenTopY: CGFloat?, menuBarHeight: CGFloat = 24) -> MenuBarHit {
        guard let screenTopY else { return .outsideMenuBar }
        return y > screenTopY - menuBarHeight ? .insideMenuBar : .outsideMenuBar
    }

    public enum MenuBarHit: Equatable {
        case insideMenuBar
        case outsideMenuBar
    }

    private func classify(hover event: NSEvent) -> RevealTrigger {
        _ = event
        return .hover
    }
}
