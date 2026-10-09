import CoreGraphics
import Foundation

/// 分隔符几何（报告 A2）：两条分隔符把菜单栏切成 常驻 / 收纳 / 始终隐藏 三段。
///
/// 为什么分隔符必须是**我们自己的图标**：那样"拖动分隔符"用的就是我们已验过的 ⌘ 拖拽能力，
/// 用户重排的是本工具的图标，不需要为了挪边界去搬动别人的图标。
/// 位置也靠读回来（AX 帧），不靠我们自己记账——系统是最终真相，记住了反而出偏差。
public enum DividerGeometry {
    public struct Controls: Sendable {
        public let leftDivider: String?
        public let rightDivider: String?
        public let toggle: String
        public var ids: Set<String> { Set([leftDivider, rightDivider, toggle].compactMap { $0 }) }

        public init(leftDivider: String? = nil, rightDivider: String? = nil, toggle: String) {
            self.leftDivider = leftDivider
            self.rightDivider = rightDivider
            self.toggle = toggle
        }
    }

    /// Control Center 会暴露包住第三方项的代理帧；它不能再占一个物理槽位。
    public static func physicalItems(_ items: [ManagedItem]) -> [ManagedItem] {
        let users = items.filter { !$0.isSystemOwned }
        return MenuBarEnumeration.sortedLeftToRight(items.filter { item in
            !item.isSystemOwned || !users.contains {
                $0.ownerBundleID != item.ownerBundleID && item.frame.contains($0.frame)
                    && abs(item.centerX - $0.centerX) < 1
            }
        })
    }

    /// 普通折叠只做稳定分组；档案中的显式次序仍由 arrangementOrder 处理。
    public static func foldingOrder(items: [ManagedItem], layout: MenuBarLayout,
                                    controls: Controls, defaultZone: MenuBarZone = .hidden,
                                    exempt: Set<String> = []) -> [String] {
        let ordered = physicalItems(items).filter { !controls.ids.contains($0.id) }
        func members(_ zone: MenuBarZone) -> [String] {
            ordered.filter {
                if exempt.contains($0.id) { return zone == .visible }
                return ($0.isSystemOwned ? .visible : layout.zone(of: $0.id) ?? defaultZone) == zone
            }.map(\.id)
        }
        var result = members(.alwaysHidden)
        if let left = controls.leftDivider { result.append(left) }
        result.append(contentsOf: members(.hidden))
        if let right = controls.rightDivider { result.append(right) }
        if controls.leftDivider != nil || controls.rightDivider != nil {
            result.append(controls.toggle)
            result.append(contentsOf: members(.visible))
        } else {
            let physical = physicalItems(items)
            let visibleSet = Set(members(.visible))
            for item in physical {
                if item.id == controls.toggle || visibleSet.contains(item.id) {
                    result.append(item.id)
                }
            }
            if !result.contains(controls.toggle) {
                result.append(controls.toggle)
            }
        }
        return result
    }

    public static func isCorrectlyPartitioned(items: [ManagedItem], layout: MenuBarLayout,
                                              controls: Controls, defaultZone: MenuBarZone = .hidden,
                                              exempt: Set<String> = []) -> Bool {
        let ordered = physicalItems(items)
        if let leftID = controls.leftDivider, let rightID = controls.rightDivider,
           let left = ordered.first(where: { $0.id == leftID })?.centerX,
           let right = ordered.first(where: { $0.id == rightID })?.centerX,
           let toggle = ordered.first(where: { $0.id == controls.toggle })?.centerX {
            guard left < right, right < toggle else { return false }
        } else {
            let hiddenMaxX = ordered.filter {
                !exempt.contains($0.id) &&
                !$0.isSystemOwned &&
                $0.id != controls.toggle &&
                (layout.zone(of: $0.id) ?? defaultZone) != .visible
            }.map(\.centerX).max() ?? -1
            let visibleMinX = ordered.filter {
                !exempt.contains($0.id) &&
                $0.id != controls.toggle &&
                ($0.isSystemOwned || (layout.zone(of: $0.id) ?? defaultZone) == .visible)
            }.map(\.frame.minX).min() ?? CGFloat.infinity
            guard hiddenMaxX < visibleMinX else { return false }
        }
        return partitionDisorder(items: ordered, layout: layout, controls: controls, defaultZone: defaultZone, exempt: exempt) == 0
    }

    /// 同区交换不算进展；只有整条分区级别序列的逆序减少才允许继续投递。
    public static func partitionDisorder(items: [ManagedItem], layout: MenuBarLayout,
                                         controls: Controls, defaultZone: MenuBarZone = .hidden,
                                         exempt: Set<String> = []) -> Int {
        let ranks = physicalItems(items).map { item -> Int in
            if let left = controls.leftDivider, item.id == left { return 1 }
            if let right = controls.rightDivider, item.id == right { return 3 }
            if controls.leftDivider != nil || controls.rightDivider != nil {
                if item.id == controls.toggle { return 4 }
            }
            if exempt.contains(item.id) { return 5 }
            if item.id == controls.toggle { return 5 }
            switch item.isSystemOwned ? .visible : layout.zone(of: item.id) ?? defaultZone {
            case .alwaysHidden: return 0
            case .hidden: return 2
            case .visible: return 5
            }
        }
        return inversionCount(ranks)
    }

    public static func orderDisorder(items: [ManagedItem], desiredOrder: [String]) -> Int {
        let ids = physicalItems(items).map(\.id)
        guard ids.count == desiredOrder.count, Set(ids) == Set(desiredOrder),
              Set(desiredOrder).count == desiredOrder.count else { return .max }
        let positions = Dictionary(uniqueKeysWithValues: desiredOrder.enumerated().map { ($0.element, $0.offset) })
        return inversionCount(ids.compactMap { positions[$0] })
    }

    private static func inversionCount(_ ranks: [Int]) -> Int {
        // ponytail: 菜单栏仅几十项，直接计数；规模显著增大后再换线性分桶。
        return ranks.indices.reduce(0) { total, index in
            total + ranks.dropFirst(index + 1).filter { $0 < ranks[index] }.count
        }
    }

    /// 包括两条真实分界的完整顺序；系统项保持相对顺序且留在右侧。
    public static func arrangementOrder(items: [ManagedItem], layout: MenuBarLayout,
                                        leftDivider: String? = nil, rightDivider: String? = nil, toggle: String,
                                        defaultZone: MenuBarZone = .hidden) -> [String] {
        let controls: Set<String> = Set([leftDivider, rightDivider, toggle].compactMap { $0 })
        let users = items.filter { !$0.isSystemOwned && !controls.contains($0.id) }
        let userIDs = Set(users.map(\.id))
        func members(_ zone: MenuBarZone) -> [String] {
            layout.items(in: zone).filter { userIDs.contains($0) }
                + users.filter { layout.zone(of: $0.id) == nil && defaultZone == zone }.map(\.id)
        }
        var order = members(.alwaysHidden)
        if let left = leftDivider { order.append(left) }
        order.append(contentsOf: members(.hidden))
        if let right = rightDivider { order.append(right) }
        if leftDivider != nil || rightDivider != nil {
            order.append(toggle)
            order.append(contentsOf: members(.visible))
        } else {
            let physical = physicalItems(items)
            let visibleSet = Set(members(.visible))
            for item in physical {
                if item.id == toggle || visibleSet.contains(item.id) {
                    order.append(item.id)
                }
            }
            if !order.contains(toggle) {
                order.append(toggle)
            }
        }
        order.append(contentsOf: items.filter(\.isSystemOwned).map(\.id))
        let live = Set(items.map(\.id))
        var seen: Set<String> = []
        return order.filter { live.contains($0) && seen.insert($0).inserted }
    }

    /// 空分区可以落在已验证的自有分界两侧，但必须按移动方向选正确的一侧。
    public static func boundaryLandingX(for itemID: String, to zone: MenuBarZone, ordered: [ManagedItem],
                                         leftEdge: CGFloat?, rightEdge: CGFloat?, dividerIDs: Set<String>) -> CGFloat? {
        guard let leftEdge, let rightEdge, leftEdge < rightEdge,
              let moving = ordered.firstIndex(where: { $0.id == itemID }) else { return nil }
        let current = self.zone(forX: ordered[moving].centerX, leftEdge: leftEdge, rightEdge: rightEdge)
        guard current != zone else { return nil }
        let edge: CGFloat
        switch zone {
        case .visible: edge = rightEdge
        case .alwaysHidden: edge = leftEdge
        case .hidden: edge = current == .visible ? rightEdge : leftEdge
        }
        guard let target = ordered.firstIndex(where: {
            dividerIDs.contains($0.id) && abs($0.centerX - edge) < 2
        }) else { return nil }
        return MenuBarDropTarget.targetX(in: ordered, moving: moving, to: target)
    }

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
