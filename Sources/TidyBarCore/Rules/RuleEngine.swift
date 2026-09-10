import Foundation

/// 规则求值器：把启用中的规则折叠成「一次布局变更批次」。
///
/// 关键约定：
/// - 条件全部满足（AND）才算命中；
/// - 同一图标上动作冲突时，priority 小者胜出，避免两条规则互相拉扯造成图标抖动；
/// - 若最终结果与当前布局一致，产出空批次（幂等，防止规则反复触发导致持续重排）。
public struct RuleEngine {
    public struct Change: Equatable, Sendable {
        public let itemID: String
        public let from: MenuBarZone?
        public let to: MenuBarZone
        public let sourceRule: String
        public let position: Int?
        public init(itemID: String, from: MenuBarZone?, to: MenuBarZone, sourceRule: String, position: Int? = nil) {
            self.itemID = itemID
            self.from = from
            self.to = to
            self.sourceRule = sourceRule
            self.position = position
        }
    }

    public struct Batch: Equatable, Sendable {
        public let changes: [Change]
        public let appliedProfiles: [String]
        public init(changes: [Change], appliedProfiles: [String] = []) {
            self.changes = changes
            self.appliedProfiles = appliedProfiles
        }
        public var isEmpty: Bool { changes.isEmpty && appliedProfiles.isEmpty }
    }

    public init() {}

    /// - Parameter isScreenShareActive: 由 App 层探测（投屏/录屏会话）后传入，保持求值器纯净可测
    public func evaluate(
        rules: [DisplayRule],
        context: SystemContext,
        currentLayout: MenuBarLayout,
        hasKnownWiFiState: Bool? = nil,
        isScreenShareActive: Bool = false,
        profiles: [String: MenuBarLayout] = [:],
        activeProfileName: String? = nil
    ) -> Batch {
        let sorted = rules
            .filter { $0.isEnabled && $0.isEvaluable }
            .sorted { $0.priority < $1.priority }

        var winnerByItem: [String: (change: Change, priority: Int)] = [:]
        var requestedProfiles: [String] = []

        func propose(_ itemID: String, zone: MenuBarZone, position: Int? = nil, rule: DisplayRule) {
            if let existing = winnerByItem[itemID], existing.priority <= rule.priority { return }
            winnerByItem[itemID] = (
                Change(itemID: itemID, from: currentLayout.zone(of: itemID), to: zone,
                       sourceRule: rule.name, position: position), rule.priority
            )
        }

        for rule in sorted {
            let matched = rule.conditions.allSatisfy {
                $0.evaluate(context, hasKnownWiFiState: hasKnownWiFiState ?? context.hasKnownWiFiState,
                            isScreenShareActive: isScreenShareActive)
            }
            guard matched else { continue }

            for action in rule.actions {
                if action.kind == .applyProfile {
                    guard let name = action.profileName else { continue }
                    if !requestedProfiles.contains(name) { requestedProfiles.append(name) }
                    if let profile = profiles[name] {
                        for zone in MenuBarZone.allCases {
                            for (position, id) in profile.items(in: zone).enumerated() {
                                propose(id, zone: zone, position: position, rule: rule)
                            }
                        }
                    }
                    continue
                }
                guard let itemID = action.itemID, let zone = action.kind.targetZone else { continue }
                propose(itemID, zone: zone, rule: rule)
            }
        }

        let plans = winnerByItem.values
            .map(\.change)
            .sorted {
                if $0.to != $1.to { return $0.to < $1.to }
                if $0.position != $1.position { return ($0.position ?? Int.max) < ($1.position ?? Int.max) }
                return $0.itemID < $1.itemID
            }

        // 先形成最终布局，再求差异。高优先级规则把某项移走后，
        // 档案中剩余项的序号必须收拢，否则会永远请求一个不存在的槽位。
        var desired = currentLayout
        for plan in plans where plan.position != nil || plan.from != plan.to {
            desired.remove(itemID: plan.itemID)
        }
        var nextPosition: [MenuBarZone: Int] = [:]
        for plan in plans where plan.position != nil {
            let index = nextPosition[plan.to, default: 0]
            desired.move(itemID: plan.itemID, to: plan.to, position: index)
            nextPosition[plan.to] = index + 1
        }
        for plan in plans where plan.position == nil && plan.from != plan.to {
            desired.move(itemID: plan.itemID, to: plan.to)
        }
        var rolling = currentLayout
        var changes: [Change] = []
        for zone in MenuBarZone.allCases {
            for (index, id) in desired.items(in: zone).enumerated() {
                guard let plan = winnerByItem[id]?.change else { continue }
                let position = plan.position == nil ? nil : index
                let from = rolling.zone(of: id)
                guard from != zone || position.map({ rolling.position(of: id) != $0 }) == true else { continue }
                changes.append(Change(itemID: id, from: from, to: zone,
                                      sourceRule: plan.sourceRule, position: position))
                rolling.move(itemID: id, to: zone, position: position)
            }
        }

        let appliedProfiles = requestedProfiles.prefix(1).filter { $0 != activeProfileName || !changes.isEmpty }
        return Batch(changes: changes, appliedProfiles: appliedProfiles)
    }

    /// 批次落地到布局（不落系统，仅内存真相源），供预览/撤销与单测使用
    public func applying(_ batch: Batch, to layout: MenuBarLayout) -> MenuBarLayout {
        var next = layout
        for change in batch.changes {
            next.move(itemID: change.itemID, to: change.to, position: change.position)
        }
        return next
    }
}
