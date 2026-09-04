import Foundation
import CoreGraphics

/// 收纳面板几何（纯函数，报告 A3/B3 的刘海避让全部收敛在这里）。
///
/// 坐标系沿用 AppKit：原点左下角，y 向上增大。菜单栏占据屏幕顶部
/// `[frame.maxY - menuBarHeight, frame.maxY]`，面板应贴在菜单栏正下方。
public enum PanelGeometry {
    public struct Metrics: Equatable, Sendable {
        public let itemSide: CGFloat
        public let itemSpacing: CGFloat
        public let contentInset: CGFloat

        public init(itemSide: CGFloat = 26, itemSpacing: CGFloat = 6, contentInset: CGFloat = 8) {
            self.itemSide = itemSide
            self.itemSpacing = itemSpacing
            self.contentInset = contentInset
        }

        /// n 个图标所需内容宽度
        public func contentWidth(for itemCount: Int) -> CGFloat {
            guard itemCount > 0 else { return 0 }
            return CGFloat(itemCount) * itemSide + CGFloat(max(0, itemCount - 1)) * itemSpacing
        }

        public var rowHeight: CGFloat { itemSide + contentInset * 2 }
    }

    /// 面板 frame。
    /// - Parameters:
    ///   - screen: 目标屏幕信息
    ///   - itemCount: 待展示图标数
    ///   - metrics: 图标尺寸与间距
    ///   - anchorX: 期望水平中心（通常取分隔符位置）
    public static func panelFrame(
        screen: ScreenInfo,
        itemCount: Int,
        metrics: Metrics = Metrics(),
        anchorX: CGFloat
    ) -> CGRect {
        let contentWidth = metrics.contentWidth(for: itemCount) + metrics.contentInset * 2
        let desiredWidth = max(Minimums.panelWidth, contentWidth)
        let width = min(desiredWidth, max(Minimums.panelWidth, screen.frame.width - 2 * Margin.screenEdge))

        let topY = screen.frame.maxY - screen.menuBarHeight - Margin.gapBelowMenuBar
        let originY = topY - metrics.rowHeight

        // 以锚点居中，再夹紧到屏幕内
        let unclampedX = anchorX - width / 2
        let minX = screen.frame.minX + Margin.screenEdge
        let maxX = screen.frame.maxX - width - Margin.screenEdge
        let originX = maxX >= minX ? min(max(unclampedX, minX), maxX) : minX

        return CGRect(x: originX, y: originY, width: width, height: metrics.rowHeight)
    }

    /// 刘海避让：面板不得覆盖刘海区域（覆盖会导致阴影/圆角穿帮，且遮挡系统菜单）。
    /// 返回调整后的 frame——必要时整体左移或右移，移不开则收窄。
    public static func adjustedForNotch(_ panel: CGRect, screen: ScreenInfo) -> CGRect {
        guard let notchWidth = screen.notchWidth, notchWidth > 0 else { return panel }

        let notchLeft = screen.frame.midX - notchWidth / 2
        let notchRight = screen.frame.midX + notchWidth / 2
        // 面板贴菜单栏下沿，纵向与刘海区域重叠判定用刘海物理高度
        let notchBottom = screen.frame.maxY - Notch.physicalHeight
        guard panel.maxY > notchBottom, panel.minX < notchRight, panel.maxX > notchLeft else {
            return panel
        }

        let spaceRight = screen.frame.maxX - Margin.screenEdge - notchRight
        let spaceLeft = notchLeft - screen.frame.minX - Margin.screenEdge

        // 哪侧空间大就往哪侧靠
        if spaceRight >= panel.width {
            return CGRect(x: notchRight + Margin.screenEdge, y: panel.minY, width: panel.width, height: panel.height)
        }
        if spaceLeft >= panel.width {
            return CGRect(x: notchLeft - Margin.screenEdge - panel.width, y: panel.minY, width: panel.width, height: panel.height)
        }
        let usable = max(Minimums.panelWidth, max(spaceLeft, spaceRight) - Margin.screenEdge)
        let width = min(panel.width, usable)
        return spaceRight >= spaceLeft
            ? CGRect(x: notchRight + Margin.screenEdge, y: panel.minY, width: width, height: panel.height)
            : CGRect(x: notchLeft - Margin.screenEdge - width, y: panel.minY, width: width, height: panel.height)
    }

    /// 面板内第 index 个图标的绘制原点
    public static func itemOrigin(in panel: CGRect, index: Int, metrics: Metrics = Metrics()) -> CGPoint {
        CGPoint(
            x: panel.minX + metrics.contentInset + CGFloat(index) * (metrics.itemSide + metrics.itemSpacing),
            y: panel.minY + metrics.contentInset
        )
    }

    public enum Margin {
        /// 面板与菜单栏之间的呼吸间隙
        public static let gapBelowMenuBar: CGFloat = 4
        /// 面板距屏幕左右边缘的最小距离
        public static let screenEdge: CGFloat = 12
    }

    public enum Minimums {
        public static let panelWidth: CGFloat = 120
    }

    public enum Notch {
        /// 刘海向下凸出的物理高度（近似值；M0 需在真机上用 auxiliaryTop*Area 校准）。
        /// 注：正常贴菜单栏下沿的面板不会与刘海纵向重叠，此处兜底处理高面板/多行面板场景。
        public static let physicalHeight: CGFloat = 24
    }
}
