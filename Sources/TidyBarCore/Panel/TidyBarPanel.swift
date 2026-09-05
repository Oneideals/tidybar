import AppKit

/// 收纳面板（对标 Ice Bar / Bartender Bar，报告 A3）。
/// 无边框透明 NSPanel，窗口层级压在菜单栏之上，失焦不抢主界面焦点。
public final class TidyBarPanel: NSPanel {
    public init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        ignoresMouseEvents = false
        // 面板不显示在窗口切换器里
        isExcludedFromWindowsMenu = true
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

/// 面板内容：骨架阶段以占位方块呈现，真实图标位图在 M1 接入 NSStatusItem 截图后替换。
public final class TidyBarPanelView: NSView {
    public var items: [ManagedItem] = [] {
        didSet { needsDisplay = true }
    }
    /// 一行操作反馈（例如"这个 App 不允许工具代点"）。空表示不显示。
    public var notice: String? {
        didSet { needsDisplay = true }
    }
    /// 真实缩略图，键为图标 id。缺项表示尚未抓到（或被拒授权），此时画占位。
    public var images: [String: CGImage] = [:] {
        didSet { needsDisplay = true }
    }
    public var onClick: ((ManagedItem) -> Void)?

    override public func draw(_ dirtyRect: NSRect) {
        let metrics = PanelGeometry.Metrics()
        let background = NSColor.controlBackgroundColor.withAlphaComponent(0.96)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        background.setFill()
        path.fill()

        if let notice, !notice.isEmpty {
            // 提示占一行高度，绘制在条目下方；放不下就退回不画（宁可少一行字也不压住图标）
            let noteAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = notice.size(withAttributes: noteAttributes)
            let y = bounds.minY + 2
            if bounds.height > metrics.itemSide + size.height + 10 {
                notice.draw(
                    at: CGPoint(x: bounds.midX - size.width / 2, y: y),
                    withAttributes: noteAttributes
                )
            }
        }

        for (index, item) in items.enumerated() {
            let origin = PanelGeometry.itemOrigin(in: bounds, index: index, metrics: metrics)
            let rect = CGRect(x: origin.x, y: origin.y, width: metrics.itemSide, height: metrics.itemSide)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let inset = rect.insetBy(dx: 2.5, dy: 2.5)
            if let image = images[item.id] {
                // 1. 真实屏幕录制截图优先（如果有 ScreenCaptureKit 授权且已抓到）
                NSGraphicsContext.current?.cgContext.draw(image, in: inset)
            } else {
                // 2. 真实 App 原生高清图标（从系统应用包读取，零授权秒开）
                let appIcon = AppIconResolver.resolve(for: item)
                appIcon.draw(in: inset)
            }
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let metrics = PanelGeometry.Metrics()
        let point = convert(event.locationInWindow, from: nil)
        for (index, item) in items.enumerated() {
            let origin = PanelGeometry.itemOrigin(in: bounds, index: index, metrics: metrics)
            let rect = CGRect(x: origin.x, y: origin.y, width: metrics.itemSide, height: metrics.itemSide)
            if rect.contains(point) {
                onClick?(item)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// 面板显隐控制：几何计算 + 屏幕参数变化时自动重新定位（报告 A3 第 3 条机制）。
public final class TidyBarPanelController: NSObject {
    public let panel = TidyBarPanel()
    private let panelView = TidyBarPanelView()
    private let screenObserver: ScreenObserving
    private let capturer: MenuBarIconCapturing
    private let bitmaps: IconBitmapStore
    private var lastAnchorX: CGFloat = 0
    /// 正在抓的项。心跳每 0.25s 会重绘一次面板，没有这个闸门就会把同一批图标反复送去屏幕录制。
    private var inFlight: Set<String> = []

    public var onItemClick: ((ManagedItem) -> Void)? {
        didSet { panelView.onClick = onItemClick }
    }

    /// 内存压力时调用：位图全部丢弃，下次呼出面板按需重抓。
    /// 缓存自己实现了 `removeAll`，但**没人调它**就等于没有上限——
    /// "20MB 以内"这件事必须由一条真实的清理路径来保证。
    public func purgeBitmaps() {
        bitmaps.purge()
        panelView.images = [:]
    }

    /// 当前位图缓存占用（字节），供性能面板与用例断言。
    public var bitmapCacheBytes: Int { bitmaps.currentBytes }

    /// 给面板加一行反馈文字（代点失败原因等）。
    public func setActivationNotice(_ text: String?) {
        panelView.notice = text
    }

    public init(
        services: SystemServices,
        capturer: MenuBarIconCapturing = UnverifiedMenuBarIconCapturer(),
        bitmaps: IconBitmapStore = IconBitmapStore()
    ) {
        self.screenObserver = services.screens
        self.capturer = capturer
        self.bitmaps = bitmaps
        super.init()
        panelView.wantsLayer = true
        panel.contentView = panelView
        screenObserver.addObserver { [weak self] in
            self?.repositionIfNeeded()
        }
    }

    /// 缓存里现成可用的位图（位置没变的才算）。
    public func cachedImages(for items: [ManagedItem]) -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for item in items {
            if let image = bitmaps.image(for: item) { result[item.id] = image }
        }
        return result
    }

    /// 只为"缺的项"发起抓图。抓完回填并交给 `onBitmapsReady` 重绘——
    /// 每次呼出面板都全量重抓等于持续做屏幕录制，白耗电。
    public func requestMissingBitmaps(for items: [ManagedItem], onBitmapsReady: @escaping () -> Void) {
        let missing = bitmaps.needsCapture(items).filter { !inFlight.contains($0.id) }
        guard !missing.isEmpty, capturer.isAuthorized else { return }
        inFlight.formUnion(missing.map(\.id))
        let scale = screenObserver.primaryScreen.map { $0.scaleFactor } ?? 2
        let inFlightFor = Set(missing.map(\.id))
        let group = DispatchGroup()
        var incoming: [(ManagedItem, CGImage)] = []
        let lock = NSLock()
        for item in missing {
            group.enter()
            capturer.capture(frame: item.frame, scale: scale) { outcome in
                if case .success(let image) = outcome {
                    lock.lock()
                    incoming.append((item, image))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.inFlight.subtract(inFlightFor)
            var changed = false
            for (item, image) in incoming {
                self.bitmaps.ingest(image, for: item)
                changed = true
            }
            if changed { onBitmapsReady() }
        }
    }

    public func show(items: [ManagedItem], screen: ScreenInfo?, anchorX: CGFloat) {
        guard let screen else { return }
        lastAnchorX = anchorX
        bitmaps.retain(alive: Set(items.map(\.id)))
        panelView.images = cachedImages(for: items)
        panelView.items = items
        let metrics = PanelGeometry.Metrics()
        let frame = PanelGeometry.adjustedForNotch(
            PanelGeometry.panelFrame(screen: screen, itemCount: items.count, metrics: metrics, anchorX: anchorX),
            screen: screen
        )
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()

        requestMissingBitmaps(for: items) { [weak self] in
            guard let self, self.isVisible else { return }
            self.panelView.images = self.cachedImages(for: items)
        }
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    private func repositionIfNeeded() {
        guard isVisible else { return }
        show(items: panelView.items, screen: screenObserver.primaryScreen, anchorX: lastAnchorX)
    }
}
