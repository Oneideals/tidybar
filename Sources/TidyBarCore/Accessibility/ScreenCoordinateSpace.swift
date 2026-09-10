import Foundation
import CoreGraphics

/// 坐标系转换。辅助功能 API 报的是 CG/全局坐标（原点＝主屏左上角，y 向下），
/// 而 AppKit 的 NSScreen.frame 是左下角原点、y 向上。布局与拖拽必须只用一套坐标，
/// 否则在多屏/负原点机器上会把图标拖到屏幕外——这正是"看起来能跑但一碰就错"的经典坑。
public enum ScreenCoordinateSpace {
    /// CG（左上原点，y 向下）→ AppKit（左下原点，y 向上）
    /// - Parameter primaryScreenHeight: 主屏高度（NSScreen.screens[0].frame.height）
    public static func cgToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit → CG，cgToAppKit 的逆运算
    public static func appKitToCG(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 一个图标在 AppKit 坐标下的顶边（菜单栏判定用）
    public static func topEdgeInAppKit(_ rect: CGRect) -> CGFloat {
        rect.maxY
    }

    /// 该图标是否落在某块屏幕的菜单栏带内（AppKit 坐标）
    public static func isWithinMenuBar(_ rect: CGRect, screen: ScreenInfo, tolerance: CGFloat = 12) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let menuBarBand = CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - screen.menuBarHeight - tolerance,
            width: screen.frame.width,
            height: screen.menuBarHeight + tolerance * 2
        )
        // 菜单栏图标高度可能略大于 menuBarHeight（含阴影），用中心点判定更稳
        return menuBarBand.contains(CGPoint(x: rect.midX, y: rect.midY))
    }
}
