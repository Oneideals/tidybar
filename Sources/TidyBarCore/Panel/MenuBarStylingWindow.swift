import AppKit

/// 菜单栏个性化样式配置（报告 E1）。
public struct MenuBarStyleConfig: Codable, Equatable, Sendable {
    public var cornerRadius: CGFloat
    public var showBorder: Bool
    public var borderColorHex: String
    public var tintColorHex: String
    public var opacity: Double

    public init(
        cornerRadius: CGFloat = 8,
        showBorder: Bool = true,
        borderColorHex: String = "#FFFFFF22",
        tintColorHex: String = "#00000033",
        opacity: Double = 0.85
    ) {
        self.cornerRadius = cornerRadius
        self.showBorder = showBorder
        self.borderColorHex = borderColorHex
        self.tintColorHex = tintColorHex
        self.opacity = opacity
    }
}

/// 菜单栏个性化装饰窗口（报告 E1）。
///
/// 核心工程设计守则：
/// 1. `ignoresMouseEvents = true`：所有鼠标点击、拖拽事件完全穿透，绝不抢走图标焦点；
/// 2. 窗口等级处于系统菜单栏正下方，只负责在背景层渲染圆角/胶囊/边框样式；
/// 3. 无高频刷新，仅在屏幕尺寸变化或设置变更时重绘，空闲 CPU 严格维持 0.0%。
public final class MenuBarStylingWindow: NSWindow {
    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        canHide = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// 菜单栏个性化绘制视图。
public final class MenuBarStylingView: NSView {
    public var config: MenuBarStyleConfig = MenuBarStyleConfig() {
        didSet { needsDisplay = true }
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let insetBounds = bounds.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: insetBounds, xRadius: config.cornerRadius, yRadius: config.cornerRadius)

        // 填充半透明胶囊背景
        let fillColor = NSColor(white: 0.15, alpha: CGFloat(config.opacity * 0.45))
        fillColor.setFill()
        path.fill()

        // 描画细微内边框
        if config.showBorder {
            let strokeColor = NSColor.white.withAlphaComponent(0.18)
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// 菜单栏样式控制器：负责生命周期与屏幕尺寸跟随。
public final class MenuBarStylingController {
    private var window: MenuBarStylingWindow?
    private let view = MenuBarStylingView()

    public init() {
        view.wantsLayer = true
    }

    /// 根据开关状态与屏幕几何同步窗口显示
    public func update(enabled: Bool, screen: ScreenInfo?) {
        guard enabled, let screen = screen else {
            window?.orderOut(nil)
            return
        }

        let menuBarHeight = screen.menuBarHeight > 0 ? screen.menuBarHeight : 24
        let screenFrame = screen.frame
        let targetFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + screenFrame.height - menuBarHeight,
            width: screenFrame.width,
            height: menuBarHeight
        )

        if window == nil {
            let win = MenuBarStylingWindow()
            win.contentView = view
            self.window = win
        }

        guard let win = window else { return }
        win.setFrame(targetFrame, display: true)
        if !win.isVisible {
            win.orderFront(nil)
        }
    }
}
