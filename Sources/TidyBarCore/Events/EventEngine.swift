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
    public var onMenuBarInteraction: (() -> Void)?
    public var onManualLayoutChange: (() -> Void)?
    private var manualMenuBarDrag = false

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var lastHandled: [RevealTrigger: TimeInterval] = [:]
    private let menuBarFrames: () -> [CGRect]
    public private(set) var isRunning = false

    public init(throttleInterval: TimeInterval = 0.2, menuBarFrames: @escaping () -> [CGRect] = {
        NSScreen.screens.map { screen in
            let measuredHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            let height = screen.safeAreaInsets.top > 0
                ? max(screen.safeAreaInsets.top, measuredHeight)
                : (measuredHeight > 0 ? measuredHeight : (NSStatusBar.system.thickness > 0 ? NSStatusBar.system.thickness : 24))
            return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                          width: screen.frame.width, height: height)
        }
    }) {
        self.throttleInterval = throttleInterval
        self.menuBarFrames = menuBarFrames
    }

    // MARK: - 生命周期

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        globalMonitors = [NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel,
                       .otherMouseDragged, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.receive(event)
        }].compactMap { $0 }
        localMonitors = [NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.receive(event)
            return event
        }].compactMap { $0 }
    }

    public func stop() {
        guard isRunning else { return }
        (globalMonitors + localMonitors).forEach { NSEvent.removeMonitor($0) }
        globalMonitors = []
        localMonitors = []
        isRunning = false
        manualMenuBarDrag = false
    }

    /// 原生事件统一入口：本工具的合成输入既不能触发手动整理，也不能改变显隐。
    public func receive(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != CGDragEventPoster.syntheticEventTag else { return }
        switch event.type {
        case .leftMouseDown:
            receive(.init(trigger: .emptyBarClick, location: NSEvent.mouseLocation))
        case .rightMouseDown:
            receiveRightClick(at: NSEvent.mouseLocation)
        case .mouseMoved:
            receive(.init(trigger: .hover, location: NSEvent.mouseLocation))
        case .scrollWheel, .otherMouseDragged:
            receive(.init(trigger: .scrollOrSwipe, location: NSEvent.mouseLocation))
        case .leftMouseDragged, .leftMouseUp:
            observeLayoutDrag(event)
        default:
            break
        }
    }

    private func observeLayoutDrag(_ event: NSEvent) {
        if event.type == .leftMouseDragged, event.modifierFlags.contains(.command),
           menuBarFrames().contains(where: { $0.contains(NSEvent.mouseLocation) }) {
            manualMenuBarDrag = true
        }
        if event.type == .leftMouseUp, manualMenuBarDrag {
            manualMenuBarDrag = false
            onManualLayoutChange?()
        }
    }

    /// 右键点击统一处理：带内右键同时通知交互与收起（PeekCoordinator 需要交互信号，
    /// 控制器仍需收起信号）；带外右键只触发收起。
    public func receiveRightClick(at location: CGPoint) {
        if menuBarFrames().contains(where: { $0.contains(location) }) {
            onMenuBarInteraction?()
            onConcealRequest?()
        } else {
            onConcealRequest?()
        }
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

    /// 全局监听与离线验证共用的入口：先命中菜单栏，再节流，最后发布。
    public func receive(_ event: Event, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if event.trigger != .hotkey, !menuBarFrames().contains(where: { $0.contains(event.location) }) {
            if event.trigger == .emptyBarClick { onConcealRequest?() }
            return
        }
        guard passesThrottle(event.trigger, now: uptime) else { return }
        onEvent?(event)
    }

    /// 纯函数：点击落在菜单栏高度带内视为分隔符/空白区命中，否则视为「点别处」→ 收起请求。
    /// M1 接入真实图标快照后，会把判定细化到「命中哪个分隔符」。
    public static func classifyMenuBarHit(eventLocationY y: CGFloat, screenTopY: CGFloat?, menuBarHeight: CGFloat = 24) -> MenuBarHit {
        guard let screenTopY else { return .outsideMenuBar }
        return y > screenTopY - menuBarHeight && y <= screenTopY ? .insideMenuBar : .outsideMenuBar
    }

    public enum MenuBarHit: Equatable {
        case insideMenuBar
        case outsideMenuBar
    }

}
