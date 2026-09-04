import Foundation
import CoreGraphics

/// ⌘ 拖拽的目标位计算。
///
/// 参数扫描（docs/findings/02-drag.md）实测：hold 时长、插值步数对成功率**没有影响**，
/// 唯一决定因素是**落点是否踩在另一个图标的槽位上**——拖进空隙时系统静默忽略，
/// 既不报错也不移动，是最难排查的一类失败（工具以为成功了，用户看到图标没动）。
///
/// 所以目标 X 必须由"当前图标顺序"推导出来，绝不能是"往左/往右 N 像素"这种任意值。
public enum MenuBarDropTarget {
    /// 在从左到右排列的可见图标中，把某项移到 toIndex 位置，返回应拖到的 X（目标邻居中心）。
    /// - Parameters:
    ///   - ordered: 同一区域内**已经可见**的图标，按 x 升序（reader 结果直接可用）
    ///   - movingIndex: 待移动图标在 ordered 中的下标
    ///   - toIndex: 期望的目标下标（0...count-1）
    /// - Returns: 目标中心 X；nil 表示这次移动没有合法落点，调用方**必须放弃而不是硬拖**
    public static func targetX(
        in ordered: [ManagedItem],
        moving movingIndex: Int,
        to toIndex: Int
    ) -> CGFloat? {
        guard ordered.indices.contains(movingIndex), ordered.indices.contains(toIndex) else { return nil }
        guard movingIndex != toIndex else { return nil }   // 原地不动，别浪费一次拖拽

        // 往前插：落在目标位置图标的中心；往后插：落在目标图标的右缘附近，
        // 因为 macOS 用"你越过了谁的中线"来决定最终顺序，越过右缘最稳
        let anchor = ordered[toIndex]
        if toIndex < movingIndex {
            return anchor.frame.midX
        }
        return anchor.frame.maxX + 2
    }

    /// 把一次"隐藏到下一个分区"的意图翻译成合法落点：
    /// 隐藏区第一个图标右侧 = 目标；若目标区域为空则没有可踩的槽位。
    public static func targetX(
        forHiding item: ManagedItem,
        neighborsInTargetZone neighbors: [ManagedItem]
    ) -> CGFloat? {
        guard let last = neighbors.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return nil }
        return last.frame.maxX + 2
    }

    /// 判定一次拖拽是否真的改变了顺序（比"坐标变了"更可靠：落回原位也算没成）。
    public static func didReorder<Item: Equatable>(before: [Item], after: [Item]) -> Bool {
        before != after
    }
}
