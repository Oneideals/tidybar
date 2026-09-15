import AppKit
import CoreGraphics

/// 幕布截图扫描器（解决冷启动后折叠状态下位图永远缺失的根因）。
///
/// 工作原理：
/// 1. 在屏幕录制已授权、无其他独占任务（非物理拖拽中、非代点中、非浮现中）时启动；
/// 2. 在屏幕顶部升起不透明的 CurtainWindow（覆盖从屏幕左缘到 TidyBar 按钮左缘），用户完全看不见背后的变动；
/// 3. 通知上层收起推杆（push separator length = 0），隐藏区图标重回屏内；
/// 4. 等待 60ms 布局消化，让 WindowServer 完成跨进程窗口重排；
/// 5. 后台队列调用 reader.discoverItems() 拿到所有收纳项的真实屏幕坐标；
/// 6. 主线程调用 panelController.prewarmBitmaps(for: excludingWindowNumbers: [curtainWindowID])，由 ScreenCaptureKit 穿透幕布完成截图；
/// 7. 撑回推杆（10,000pt），撤销幕布，回调完成。
/// 8. 设有 2.5 秒看门狗，任何异常或超时均强制撤幕布并撑回推杆，避免界面卡死。
@MainActor
public final class CaptureSweep {
    public enum State: Equatable, Sendable {
        case idle
        case running
    }

    public private(set) var state: State = .idle
    private var curtain: CurtainWindow?
    private var watchdogTimer: Timer?

    private let services: SystemServices
    private let panelController: TidyBarPanelController
    private let setPusherCollapsed: (Bool) -> Void
    private let toggleMinXProvider: () -> CGFloat
    private let isBusyProvider: () -> Bool

    public init(
        services: SystemServices,
        panelController: TidyBarPanelController,
        setPusherCollapsed: @escaping (Bool) -> Void,
        toggleMinXProvider: @escaping () -> CGFloat,
        isBusyProvider: @escaping () -> Bool
    ) {
        self.services = services
        self.panelController = panelController
        self.setPusherCollapsed = setPusherCollapsed
        self.toggleMinXProvider = toggleMinXProvider
        self.isBusyProvider = isBusyProvider
    }

    private var pendingCompletions: [() -> Void] = []

    /// 触发幕布截图扫描。若当前正在扫描，合并请求并在完成后一并回调。
    public func run(items: [ManagedItem], completion: @escaping () -> Void = {}) {
        pendingCompletions.append(completion)
        guard state == .idle else { return }

        guard panelController.hasCaptureAuthorization,
              !isBusyProvider(),
              NSEvent.pressedMouseButtons == 0 else {
            drainCompletions()
            return
        }

        let needed = items.filter { panelController.cachedImages(for: [$0])[$0.id] == nil }
        guard !needed.isEmpty else {
            drainCompletions()
            return
        }

        state = .running

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let toggleX = toggleMinXProvider()
        let cached = Array(panelController.cachedImages(for: items).values)
        let curtainWindow = CurtainWindow(screen: screen, toggleMinX: toggleX, cachedBitmaps: cached)
        self.curtain = curtainWindow
        curtainWindow.orderFrontRegardless()

        let curtainID = CGWindowID(curtainWindow.windowNumber)

        // 升幕布后，将推杆归零（收起推杆）
        setPusherCollapsed(true)

        // 挂 2.5 秒看门狗
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.abortSweep()
            }
        }

        // 等待 60ms 布局消化，避免读到屏外负坐标
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.state == .running else { return }

            let reader = self.services.reader
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let live = reader.discoverItems()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state == .running else { return }
                    let freshNeeded = live.filter { item in
                        needed.contains { $0.id == item.id || ($0.ownerBundleID == item.ownerBundleID && $0.title == item.title) }
                        && item.frame.width > 0 && item.centerX > 0
                    }

                    if freshNeeded.isEmpty {
                        self.finishSweep()
                        return
                    }

                    self.panelController.prewarmBitmaps(
                        for: freshNeeded,
                        excludingWindowNumbers: [curtainID],
                        isValid: { [weak self] in self?.state == .running }
                    ) { [weak self] in
                        self?.finishSweep()
                    }
                }
            }
        }
    }

    private func finishSweep() {
        guard state == .running else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        setPusherCollapsed(false)
        curtain?.orderOut(nil)
        curtain = nil
        state = .idle

        drainCompletions()
    }

    private func abortSweep() {
        guard state == .running else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        setPusherCollapsed(false)
        curtain?.orderOut(nil)
        curtain = nil
        state = .idle

        drainCompletions()
    }

    private func drainCompletions() {
        let callbacks = pendingCompletions
        pendingCompletions.removeAll()
        callbacks.forEach { $0() }
    }
}
