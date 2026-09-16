import AppKit
import CoreGraphics

/// 统一图标呈现形式：已验证的菜单栏真实截图，或受控中性占位符。
public enum IconPresentation: Equatable, Sendable {
    case bitmap(CGImage)
    case placeholder(reason: PlaceholderReason)
}

/// 占位原因（明确表达状态，绝不伪造彩色 App 图标）。
public enum PlaceholderReason: Equatable, Sendable {
    case captureNotAuthorized     // 未授权屏幕录制
    case notCapturedYet           // 已授权，尚未截到
    case itemNotRunning           // 台账项，当前不在菜单栏（frame == .zero）
}

/// 统一图标呈现样式与绘制标准。
public enum MenuBarIconStyle {
    public static let glyphHeight: CGFloat = 22
    public static let placeholderWidth: CGFloat = 22
    public static let cornerRadius: CGFloat = 5

    /// 纯函数：由条目与位图查找结果决定呈现方式。
    /// 判定顺序固定：
    /// 判定顺序：
    /// 1. bitmap != nil -> bitmap（只要有真实位图，无论是折叠收纳态还是后台项均优先展示真实截图）
    /// 2. !captureAuthorized -> captureNotAuthorized
    /// 3. item.frame == .zero -> itemNotRunning
    /// 4. 否则 -> notCapturedYet
    public static func presentation(for item: ManagedItem, bitmap: CGImage?, captureAuthorized: Bool) -> IconPresentation {
        if let bitmap {
            return .bitmap(bitmap)
        }
        if !captureAuthorized {
            return .placeholder(reason: .captureNotAuthorized)
        }
        if item.frame == .zero {
            return .placeholder(reason: .itemNotRunning)
        }
        return .placeholder(reason: .notCapturedYet)
    }

    /// 由呈现方式与容器矩形算出绘制矩形：位图按截图比例等比缩放到 glyphHeight。
    public static func glyphRect(for presentation: IconPresentation, in container: CGRect) -> CGRect {
        switch presentation {
        case .bitmap(let image):
            let imgWidth = CGFloat(image.width)
            let imgHeight = max(1, CGFloat(image.height))
            let targetHeight = min(container.height, glyphHeight)
            let rawWidth = (imgWidth / imgHeight) * targetHeight
            // 自适应宽度：单图标通常为 22pt，文字/监控长条（如网速、温度、日历）自适应延伸至上限 80pt，防止无限延展
            let targetWidth = min(max(glyphHeight, rawWidth), 80)
            let x = container.midX - targetWidth / 2
            let y = container.midY - targetHeight / 2
            return CGRect(x: x, y: y, width: targetWidth, height: targetHeight)
        case .placeholder:
            let width = min(container.width, placeholderWidth)
            let height = min(container.height, glyphHeight)
            let x = container.midX - width / 2
            let y = container.midY - height / 2
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// 统一绘制：位图等比绘制；占位画虚线圆角框加淡色首字母。
    public static func draw(_ presentation: IconPresentation, for item: ManagedItem, in container: CGRect) {
        let rect = glyphRect(for: presentation, in: container)
        switch presentation {
        case .bitmap(let image):
            let size = CGSize(width: image.width, height: image.height)
            let nsImage = NSImage(cgImage: image, size: size)
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            clip.addClip()
            let imgWidth = CGFloat(image.width)
            let imgHeight = max(1, CGFloat(image.height))
            let naturalWidth = (imgWidth / imgHeight) * rect.height
            if naturalWidth > rect.width + 1 {
                // 超宽异形图居中裁剪绘制，防止横向被压缩挤扁
                let drawRect = CGRect(x: rect.midX - naturalWidth / 2, y: rect.minY, width: naturalWidth, height: rect.height)
                nsImage.draw(in: drawRect)
            } else {
                nsImage.draw(in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()

        case .placeholder:
            // 虚线圆角框（在暗色托盘中保持优雅可见度）
            let strokeColor = NSColor.white.withAlphaComponent(0.28)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = 1.0
            let dashes: [CGFloat] = [3.0, 2.0]
            path.setLineDash(dashes, count: 2, phase: 0.0)
            strokeColor.setStroke()
            path.stroke()

            // 首字母提取（优先 title，其次 ownerBundleID，无则 "·"）
            let letter: String
            let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmedTitle.first, !first.isWhitespace {
                letter = String(first).uppercased()
            } else if let bundleID = item.ownerBundleID?.split(separator: ".").last, let first = bundleID.first {
                letter = String(first).uppercased()
            } else {
                letter = "·"
            }

            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let textColor = NSColor.white.withAlphaComponent(0.65)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let strSize = str.size()
            let strRect = CGRect(
                x: rect.midX - strSize.width / 2,
                y: rect.midY - strSize.height / 2,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect)
        }
    }
}

/// 适用于设置面板 Inspector、搜索面板等独立控件的统一图标视图。
public final class MenuBarIconGlyphView: NSView {
    public var item: ManagedItem? { didSet { needsDisplay = true } }
    public var presentation: IconPresentation = .placeholder(reason: .notCapturedYet) { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let item else { return }
        MenuBarIconStyle.draw(presentation, for: item, in: bounds)
    }
}
