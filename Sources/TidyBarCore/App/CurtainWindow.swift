import AppKit
import CoreGraphics

/// 菜单栏掩护幕布窗口（报告 A3 / 需求一与需求二共用基础设施）。
///
/// 幕布在后台执行推杆归零（截图预热或拖拽图标浮现）期间升起，
/// 遮挡从屏幕左缘到 TidyBar 按钮左缘的菜单栏带，防止用户察觉到中间图标被推回屏内。
/// 关键属性：
/// 1. 不透明且位于 statusWindow 之上（level = statusWindow + 1）；
/// 2. ignoresMouseEvents = true，不抢点击；
/// 3. canJoinAllSpaces，跨虚拟桌面常驻；
/// 4. 在 ScreenCaptureKit 中作为 excludingWindows 被剔除，故能截到底层真实菜单栏。
public final class CurtainWindow: NSWindow {
    private final class CurtainView: NSView {
        var fillColor: NSColor

        init(frame: NSRect, fillColor: NSColor) {
            self.fillColor = fillColor
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            fillColor.setFill()
            bounds.fill()

            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let separatorColor = isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.12)
            separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1.0).fill()
        }
    }

    public init(screen: NSScreen, toggleMinX: CGFloat, cachedBitmaps: [CGImage] = []) {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(24, screenFrame.maxY - visibleFrame.maxY)
        let menuBarY = screenFrame.maxY - menuBarHeight

        let leftX = visibleFrame.minX
        let width = max(0, toggleMinX - leftX)
        let frame = CGRect(x: leftX, y: menuBarY, width: width, height: menuBarHeight)

        let color = Self.resolveColor(cachedBitmaps: cachedBitmaps)

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        self.isOpaque = true
        self.backgroundColor = color
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = CurtainView(frame: NSRect(origin: .zero, size: frame.size), fillColor: color)
        self.contentView = view
    }

    /// 颜色推导：优先取位图角点中位色，缓存为空时取系统菜单栏背景色近似值。
    private static func resolveColor(cachedBitmaps: [CGImage]) -> NSColor {
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let sample = cachedBitmaps.first, let pixelColor = sampleCornerColor(sample) {
            return pixelColor
        }
        return isDark
            ? NSColor(calibratedWhite: 0.12, alpha: 1.0)
            : NSColor(calibratedWhite: 0.96, alpha: 1.0)
    }

    private static func sampleCornerColor(_ image: CGImage) -> NSColor? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data),
              image.width > 0, image.height > 0 else { return nil }
        // 采样左上角 (0, 0)
        let bpp = image.bitsPerPixel / 8
        if bpp >= 4 {
            let r = CGFloat(ptr[0]) / 255.0
            let g = CGFloat(ptr[1]) / 255.0
            let b = CGFloat(ptr[2]) / 255.0
            let a = CGFloat(ptr[3]) / 255.0
            if a > 0.5 {
                return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
            }
        }
        return nil
    }
}
