import AppKit
import ApplicationServices
import CoreGraphics

/// 前台应用左侧文字菜单（ + 应用名 + 文件/编辑/显示/窗口/帮助等）与多屏幕几何计算。
/// 确保只有点击文字菜单和右侧状态栏图标中间的真正空白区域才触发抽屉/折叠。
public enum ApplicationMenuGeometry {

    /// 读取当前前台应用的主菜单在屏幕上占据的水平跨度（从屏幕左边缘算起的有效宽度）
    public static func readFrontmostAppMenuWidth() -> CGFloat? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.04) // 40ms 超时，绝不阻塞交互主循环

        var menuBarVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarVal) == .success,
              let menuBar = menuBarVal, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            return nil
        }

        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement], !children.isEmpty else {
            return nil
        }

        var minX: CGFloat = .infinity
        var maxX: CGFloat = 0
        for child in children {
            var posVal: AnyObject?
            var sizeVal: AnyObject?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posVal) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeVal) == .success,
                  let posVal, let sizeVal else { continue }
            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue((posVal as! AXValue), .cgPoint, &pos)
            AXValueGetValue((sizeVal as! AXValue), .cgSize, &size)

            minX = min(minX, pos.x)
            maxX = max(maxX, pos.x + size.width)
        }

        if maxX > minX && minX < .infinity {
            // 如果是在多屏中报告的坐标（minX >= 50），计算相对跨度；如果在主屏附近（minX < 50），直接取 maxX
            let width = minX < 50 ? maxX : ((maxX - minX) + 14)
            return width
        }
        return nil
    }

    /// 获取前台应用在指定屏幕上的文字主菜单占据的最大 X 边界（水平坐标）。
    /// 如果 AX 暂时不可用，使用保守的安全下限（默认至少 280pt，确保绝不误触菜单文字）。
    public static func frontmostApplicationMenuMaxX(on screen: ScreenInfo) -> CGFloat {
        if let liveWidth = readFrontmostAppMenuWidth(), liveWidth > 50 {
            return screen.frame.minX + max(260, liveWidth)
        }
        // 保守安全兜底：Apple 图标 + 应用名 + 基础菜单至少占 280pt
        return screen.frame.minX + 280
    }

    /// 判定点击位置是否真正落在「左侧文字菜单与右侧菜单栏图标之间的空白区域」。
    /// 全面覆盖刘海屏、非刘海屏以及多屏幕复杂排列（包括负坐标屏幕）场景。
    public static func isPointInsideEmptyMenuBarSpace(
        point: CGPoint,
        screen: ScreenInfo,
        statusItems: [ManagedItem],
        ignoredItemIDs: Set<String> = []
    ) -> Bool {
        // 1. 垂直带判定：必须落在该屏幕的真实菜单栏高度范围内（带 ±2pt 容差）
        let menuBarTop = screen.frame.maxY
        let menuBarBottom = screen.frame.maxY - screen.menuBarHeight
        guard point.y >= menuBarBottom - 2 && point.y <= menuBarTop + 2 else {
            return false
        }

        // 2. 水平屏幕范围判定：必须在该屏幕物理宽度内
        guard point.x >= screen.frame.minX && point.x <= screen.frame.maxX else {
            return false
        }

        // 3. 避让刘海（硬件实体区）：仅在有刘海的内建屏上生效
        if let notchWidth = screen.notchWidth, notchWidth > 0 {
            let notchLeft = screen.frame.midX - notchWidth / 2 - 4
            let notchRight = screen.frame.midX + notchWidth / 2 + 4
            if point.x >= notchLeft && point.x <= notchRight {
                return false
            }
        }

        // 4. 避让左侧文字主菜单（ + 软件菜单文字区）
        let appMenuMaxX = frontmostApplicationMenuMaxX(on: screen)
        // 留 6pt 呼吸空隙，绝不能点到最后一个菜单项文字边缘误触发抽屉
        if point.x <= appMenuMaxX + 6 {
            return false
        }

        // 5. 过滤出物理落在当前屏幕上且位于左侧菜单右方的可见/交互图标
        let onScreenItems = statusItems.filter { item in
            guard item.frame.width > 0 && item.frame.width <= 300 else { return false }
            if ignoredItemIDs.contains(item.id) { return false }
            if item.title == "┆" || item.title == "╎" { return false }
            return item.frame.minX >= appMenuMaxX && item.frame.minX < screen.frame.maxX
        }
        if let leftmostStatusItemX = onScreenItems.map(\.frame.minX).min() {
            // 如果点在右侧状态项最左端之后（包括图标间细微缝隙），绝不判定为中央空白区
            if point.x >= leftmostStatusItemX - 4 {
                return false
            }
        }

        // 6. 其它任意命中当前任何已识别有效 items 的情况（双重防护）
        let directHitItems = statusItems.filter { item in
            guard item.frame.width > 0 && item.frame.width <= 300 else { return false }
            if ignoredItemIDs.contains(item.id) { return false }
            if item.title == "┆" || item.title == "╎" { return false }
            return true
        }
        if directHitItems.contains(where: { $0.frame.contains(point) }) {
            return false
        }

        // 严格满足：在左侧文字菜单右侧，且在右侧状态项左侧，且非刘海区
        return true
    }
}
