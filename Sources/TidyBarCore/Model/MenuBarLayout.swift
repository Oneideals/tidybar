import Foundation

/// 布局：记录每个分区里图标的有序 id 列表。
/// 这是本工具唯一的「真相源」，所有隐藏/显示操作都表现为一次布局变更 + 一次落地执行。
public struct MenuBarLayout: Codable, Equatable, Sendable {
    /// key 为 MenuBarZone.rawValue，value 为从左到右的图标 id 顺序
    public private(set) var zones: [String: [String]]

    public init(zones: [String: [String]] = [:]) {
        self.zones = zones
    }

    // MARK: - 读取

    public func items(in zone: MenuBarZone) -> [String] {
        zones[zone.rawValue] ?? []
    }

    public var allItemIDs: Set<String> {
        Set(zones.values.flatMap { $0 })
    }

    /// 该归属进程在本工具的布局里**只有一条**配置时，返回它所在的分区。
    ///
    /// 用来接住"标题漂移"：微信把未读数写进 AXTitle，含标题的 id 会随状态变化，
    /// 老配置于是认不出同一个图标，用户会遇到"我明明收起来了，它又冒出来"。
    /// 一个进程只有一个图标时，"这条配置属于这个进程"已经足够定位到人，
    /// 不需要标题参与。多于一个图标时这里返回 nil——那种情况只能靠位置认领，
    /// 硬接会把配置接到兄弟图标上，比认错更糟。
    public func soleZone(forOwner ownerBundleID: String) -> MenuBarZone? {
        let prefix = ManagedItem.normalized(ownerBundleID) + "."
        let matches = MenuBarZone.allCases.flatMap { zone in
            items(in: zone).filter { $0.hasPrefix(prefix) }
        }
        guard matches.count == 1, let only = matches.first else { return nil }
        return zone(of: only)
    }

    public func zone(of itemID: String) -> MenuBarZone? {
        for zone in MenuBarZone.allCases where items(in: zone).contains(itemID) {
            return zone
        }
        return nil
    }

    public func position(of itemID: String) -> Int? {
        location(of: itemID)?.1
    }

    /// 图标所在分区与序号。独立成方法，避免在 `move(itemID:to:)` 里被 `zone` 参数遮蔽。
    private func location(of itemID: String) -> (MenuBarZone, Int)? {
        guard let found = zone(of: itemID) else { return nil }
        return items(in: found).firstIndex(of: itemID).map { (found, $0) }
    }

    /// 占据菜单栏物理宽度的图标总数（用于小屏空间预警）
    public var occupiedCount: Int {
        MenuBarZone.allCases.filter { $0.occupiesMenuBar }
            .reduce(0) { $0 + items(in: $1).count }
    }

    // MARK: - 变更（全部返回变更结果，便于 Safety 层做前后对照与回滚）

    /// 把图标放入指定分区指定位置；同区且未指定位置时保留原顺序，跨区默认追加。
    /// 返回旧位置用于失败回滚。
    @discardableResult
    public mutating func move(itemID: String, to zone: MenuBarZone, position: Int? = nil) -> (zone: MenuBarZone, position: Int)? {
        let previous = location(of: itemID)
        let requestedPosition = position ?? (previous?.0 == zone ? previous?.1 : nil)
        removeFromZones(itemID)

        var list = zones[zone.rawValue] ?? []
        let index = requestedPosition.map { min(max($0, 0), list.count) } ?? list.count
        list.insert(itemID, at: index)
        zones[zone.rawValue] = list
        return previous
    }

    public mutating func append(_ itemID: String, to zone: MenuBarZone) {
        guard location(of: itemID) == nil else { return }
        var list = zones[zone.rawValue] ?? []
        list.append(itemID)
        zones[zone.rawValue] = list
    }

    public mutating func remove(itemID: String) {
        removeFromZones(itemID)
    }

    /// 依据新图标策略生成初始布局（报告 A7：新图标处理策略）
    public static func folding(discovered itemIDs: [String], into layout: MenuBarLayout, defaultZone: MenuBarZone) -> MenuBarLayout {
        var next = layout
        for id in itemIDs where next.zone(of: id) == nil {
            let zone = ManagedItem.isSystemOwned(itemID: id) ? .visible : defaultZone
            next.append(id, to: zone)
        }
        // 系统项（时钟、控制中心等）受系统原生保护，无论历史配置如何，必须强制保留在常显区 (.visible)
        for id in itemIDs where ManagedItem.isSystemOwned(itemID: id) {
            if next.zone(of: id) != .visible {
                next.move(itemID: id, to: .visible)
            }
        }
        // 已消失的图标（App 退出/卸载）不残留
        let discovered = Set(itemIDs)
        for zone in MenuBarZone.allCases {
            next.removeFromZonesOnly(matching: { !discovered.contains($0) }, in: zone)
        }
        return next
    }

    // MARK: - 私有

    private mutating func removeFromZones(_ itemID: String) {
        for zone in MenuBarZone.allCases {
            guard var list = zones[zone.rawValue] else { continue }
            list.removeAll { $0 == itemID }
            zones[zone.rawValue] = list.isEmpty ? nil : list
        }
    }

    private mutating func removeFromZonesOnly(matching predicate: (String) -> Bool, in zone: MenuBarZone) {
        guard var list = zones[zone.rawValue] else { return }
        list.removeAll(where: predicate)
        zones[zone.rawValue] = list.isEmpty ? nil : list
    }

/// 该归属进程在本工具布局里已有的配置 id（可能来自多个分区，顺序按分区登记次序）。
    public func configuredIDs(ofOwner ownerBundleID: String) -> [String] {
        let prefix = ManagedItem.normalized(ownerBundleID) + "."
        return MenuBarZone.allCases.flatMap { items(in: $0).filter { $0.hasPrefix(prefix) } }
    }

    /// 原地改名（保持所在分区与左右顺序）。标题漂移后的配置迁移就靠它落到新 id 上。
    public mutating func rename(id old: String, to new: String) {
        guard old != new, let current = zone(of: old) else { return }
        var list = items(in: current)
        guard let index = list.firstIndex(of: old) else { return }
        // 新 id 已经被登记在**别的**分区时不能硬塞，否则同一图标会同时出现在两个分区
        if let existing = zone(of: new), existing != current { return }
        list.removeAll { $0 == old || $0 == new }
        list.insert(new, at: min(index, list.count))
        zones[current.rawValue] = list
    }
}
