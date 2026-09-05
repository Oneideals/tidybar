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
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            // 占位：首字母，避免在缺少真实位图时面板空白难辨
            let label = String(item.title.prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
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
    private var lastAnchorX: CGFloat = 0

    public var onItemClick: ((ManagedItem) -> Void)? {
        didSet { panelView.onClick = onItemClick }
    }

    /// 给面板加一行反馈文字（代点失败原因等）。
    public func setActivationNotice(_ text: String?) {
        panelView.notice = text
    }

    public init(services: SystemServices) {
        self.screenObserver = services.screens
        super.init()
        panelView.wantsLayer = true
        panel.contentView = panelView
        screenObserver.addObserver { [weak self] in
            self?.repositionIfNeeded()
        }
    }

    public func show(items: [ManagedItem], screen: ScreenInfo?, anchorX: CGFloat) {
        guard let screen else { return }
        lastAnchorX = anchorX
        panelView.items = items
        let metrics = PanelGeometry.Metrics()
        let frame = PanelGeometry.adjustedForNotch(
            PanelGeometry.panelFrame(screen: screen, itemCount: items.count, metrics: metrics, anchorX: anchorX),
            screen: screen
        )
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()
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
