import CoreGraphics
import Foundation

/// 分隔符几何（报告 A2）：两条分隔符把菜单栏切成 常驻 / 收纳 / 始终隐藏 三段。
///
/// 为什么分隔符必须是**我们自己的图标**：那样"拖动分隔符"用的就是我们已验过的 ⌘ 拖拽能力，
/// 用户重排的是本工具的图标，不需要为了挪边界去搬动别人的图标。
/// 位置也靠读回来（AX 帧），不靠我们自己记账——系统是最终真相，记住了反而出偏差。
public enum DividerGeometry {
    /// 一条分隔符的 x（取帧中心，比较稳定：宽度会随长度变化）
    public static func center(of divider: ManagedItem) -> CGFloat { divider.frame.midX }

    /// 给定两条分隔符的中心 x，判断某个 x 落在哪个区。
    ///
    /// 约定（对齐 Ice 的心智模型）：从右往左是 常驻 → 收纳 → 始终隐藏。
    /// `left` / `right` 为 nil 表示那条分隔符还没被摆出来——此时**保守地**判为常驻：
    /// 没有边界就没有"收起来"这回事，宁可什么都不藏，也不要凭猜测把用户的图标藏掉。
    public static func zone(forX x: CGFloat, leftEdge: CGFloat?, rightEdge: CGFloat?) -> MenuBarZone {
        guard let rightEdge else { return .visible }
        if x > rightEdge { return .visible }
        guard let leftEdge else { return .hidden }
        return x > leftEdge ? .hidden : .alwaysHidden
    }

    /// 由当前现场顺序 + 分隔符位置，算出每个图标应属的分区。
    /// 返回 `id → zone`，只包含真正被分隔符管辖的项（分隔符自身不参与）。
    public static func assignments(
        of items: [ManagedItem],
        dividers: [ManagedItem],
        defaultZone: MenuBarZone
    ) -> [String: MenuBarZone] {
        let edges = dividers.map(center(of:)).sorted()
        let leftEdge = edges.count >= 2 ? edges.first : nil
        let rightEdge = edges.last

        var result: [String: MenuBarZone] = [:]
        for item in items {
            // 分隔符本身是我们自己的图标，绝不能被自己划进隐藏区——那会把自己藏掉
            if dividers.contains(where: { $0.id == item.id }) { continue }
            result[item.id] = zone(forX: item.frame.midX, leftEdge: leftEdge, rightEdge: rightEdge)
        }
        _ = defaultZone
        return result
    }

    /// 把某图标分配到某个区时，**合法的落点 x**。
    ///
    /// 这条是"接管模式下菜单改分区静默不生效"的根因修复：引擎需要一个踩在别人槽位上的坐标，
    /// 拖进空隙 macOS 会不报错也不动（findings/02）。所以落点必须由目标区里**最靠边界的邻居**
    /// 反推，而不是拍一个像素数。
    ///
    /// 返回 nil 表示"给不出合法落点"（该区还没有任何邻居，或分隔符没摆出来）：
    /// 调用方要如实失败并说明缺什么，不许退化成"随便猜一个 x"。
    public static func landingX(
        for itemID: String,
        to zone: MenuBarZone,
        ordered: [ManagedItem],
        leftEdge: CGFloat?,
        rightEdge: CGFloat?,
        dividerIDs: Set<String> = []
    ) -> CGFloat? {
        guard let movedIndex = ordered.firstIndex(where: { $0.id == itemID }) else { return nil }
        // 邻居按同一条序列取，索引才对得上；被移动项自己不算邻居
        let members = ordered.enumerated()
            .filter { entry in
                entry.element.id != itemID
                    // 分隔符是边界不是住户。把它当邻居，落点会算到边界外侧：
                    // 图标既没进目标区，又多冒一次 ⌘ 拖拽。
                    && !dividerIDs.contains(entry.element.id)
                    && DividerGeometry.zone(
                        forX: entry.element.frame.midX, leftEdge: leftEdge, rightEdge: rightEdge
                    ) == zone
            }
            .map(\.offset)
        guard let first = members.min(), let last = members.max() else { return nil }

        let target: Int
        if movedIndex < first {
            target = first          // 从左边越进这个区
        } else if movedIndex > last {
            target = last           // 从右边越进这个区
        } else {
            return nil              // 本来就在这个区里，别浪费一次拖拽
        }
        return MenuBarDropTarget.targetX(in: ordered, moving: movedIndex, to: target)
    }
}
