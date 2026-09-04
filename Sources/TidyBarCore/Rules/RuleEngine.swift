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
        public init(itemID: String, from: MenuBarZone?, to: MenuBarZone, sourceRule: String) {
            self.itemID = itemID
            self.from = from
            self.to = to
            self.sourceRule = sourceRule
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
        hasKnownWiFiState: Bool = true,
        isScreenShareActive: Bool = false
    ) -> Batch {
        let sorted = rules
            .filter { $0.isEnabled && $0.isEvaluable }
            .sorted { $0.priority < $1.priority }

        var winnerByItem: [String: (change: Change, priority: Int)] = [:]
        var profiles: [String] = []

        for rule in sorted {
            let matched = rule.conditions.allSatisfy {
                $0.evaluate(context, hasKnownWiFiState: hasKnownWiFiState, isScreenShareActive: isScreenShareActive)
            }
            guard matched else { continue }

            for action in rule.actions {
                if action.kind == .applyProfile {
                    if let name = action.profileName, !profiles.contains(name) { profiles.append(name) }
                    continue
                }
                guard let itemID = action.itemID, let zone = action.kind.targetZone else { continue }

                if let existing = winnerByItem[itemID], existing.priority <= rule.priority {
                    continue // 已有同级或更高优先级规则占位
                }
                winnerByItem[itemID] = (
                    Change(itemID: itemID, from: currentLayout.zone(of: itemID), to: zone, sourceRule: rule.name),
                    rule.priority
                )
            }
        }

        // 幂等过滤：结果与现状一致的变更直接丢弃
        let changes = winnerByItem.values
            .map(\.change)
            .filter { $0.from != $0.to }
            .sorted { $0.itemID < $1.itemID }

        return Batch(changes: changes, appliedProfiles: profiles)
    }

    /// 批次落地到布局（不落系统，仅内存真相源），供预览/撤销与单测使用
    public func applying(_ batch: Batch, to layout: MenuBarLayout) -> MenuBarLayout {
        var next = layout
        for change in batch.changes {
            next.move(itemID: change.itemID, to: change.to, position: nil)
        }
        return next
    }
}
