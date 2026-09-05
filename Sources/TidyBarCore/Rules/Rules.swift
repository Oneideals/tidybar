import Foundation

// MARK: - 条件显示（规则引擎，报告 C1/C2）
//
// 设计目标：把 Bartender 藏在深层设置里的「触发器」做成泛用户能读懂的条件卡片。
// 因此 RuleCondition 全部是可枚举、可序列化的离散条件，UI 层直接渲染成
// 「如果【条件】那么【动作】」句式，不引入表达式引擎。

/// 规则输入快照。由 SystemContextProvider 采集（IOKit 电量、CoreWLAN、焦点模式等）。
/// 采集实现留到 M2；求值逻辑是纯函数，已具备完整单测。
public struct SystemContext: Equatable, Sendable {
    /// 0.0 - 1.0；nil = 无电池（台式机/外接电源设备）
    public let batteryLevel: Double?
    public let isCharging: Bool
    public let connectedWiFiSSID: String?
    /// 当前激活的焦点模式名；nil = 未开启任何焦点模式
    public let activeFocusMode: String?
    /// 当前前台 App 的 bundle id
    public let frontmostAppBundleID: String?
    public let now: Date
    public let calendar: Calendar

    public init(
        batteryLevel: Double?,
        isCharging: Bool,
        connectedWiFiSSID: String?,
        activeFocusMode: String?,
        frontmostAppBundleID: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.connectedWiFiSSID = connectedWiFiSSID
        self.activeFocusMode = activeFocusMode
        self.frontmostAppBundleID = frontmostAppBundleID
        self.now = now
        self.calendar = calendar
    }
}

/// 「如果」部分
public enum RuleCondition: String, Codable, CaseIterable, Sendable {
    case batteryLow
    case batteryCritical
    case notCharging
    case onBatteryPower
    case focusModeActive
    case screenSharingLikely
    case nightTime
    case workingHours
    case wifiDisconnected

    /// 规则卡片上的中文标签
    public var label: String {
        switch self {
        case .batteryLow: return "电量低于 20%"
        case .batteryCritical: return "电量低于 10%"
        case .notCharging: return "未在充电"
        case .onBatteryPower: return "使用电池供电"
        case .focusModeActive: return "开启专注模式时"
        case .screenSharingLikely: return "疑似投屏/录屏时"
        case .nightTime: return "夜间（22:00-7:00）"
        case .workingHours: return "工作时段（9:00-18:00）"
        case .wifiDisconnected: return "未连接 Wi-Fi"
        }
    }

    /// 各条件的阈值（集中定义，避免散落在求值分支里）
    public static let lowBatteryThreshold = 0.20
    public static let criticalBatteryThreshold = 0.10
    public static let nightStartHour = 22
    public static let nightEndHour = 7
    public static let workStartHour = 9
    public static let workEndHour = 18

    /// 纯求值。`hasKnownWiFiState` 用于区分「读不到」与「已断开」，
    /// 避免 CoreWLAN 权限缺失时误判规则。
    public func evaluate(
        _ context: SystemContext,
        hasKnownWiFiState: Bool,
        isScreenShareActive: Bool
    ) -> Bool {
        switch self {
        case .batteryLow:
            guard let level = context.batteryLevel else { return false }
            return level <= Self.lowBatteryThreshold
        case .batteryCritical:
            guard let level = context.batteryLevel else { return false }
            return level <= Self.criticalBatteryThreshold
        case .notCharging:
            return !context.isCharging
        case .onBatteryPower:
            guard context.batteryLevel != nil else { return false }
            return !context.isCharging
        case .focusModeActive:
            return context.activeFocusMode != nil
        case .screenSharingLikely:
            return isScreenShareActive
        case .nightTime:
            return RuleCondition.inHourRange(
                context.hour(in: context.calendar),
                start: Self.nightStartHour,
                end: Self.nightEndHour
            )
        case .workingHours:
            let hour = context.hour(in: context.calendar)
            let weekday = context.calendar.component(.weekday, from: context.now)
            let isWeekday = weekday >= 2 && weekday <= 6
            return isWeekday && hour >= Self.workStartHour && hour < Self.workEndHour
        case .wifiDisconnected:
            guard hasKnownWiFiState else { return false }
            return context.connectedWiFiSSID == nil
        }
    }

    /// 跨零点区间判定（夜间 22:00-7:00 依赖此逻辑）
    public static func inHourRange(_ hour: Int, start: Int, end: Int) -> Bool {
        if start <= end {
            return hour >= start && hour < end
        }
        return hour >= start || hour < end
    }
}

/// 「那么」部分
public struct RuleAction: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// 把图标放回可见区（投屏时反向：从可见区收进隐藏区）
        case show
        case hide
        case alwaysHide
        /// 切换整套布局档案
        case applyProfile

        public var label: String {
            switch self {
            case .show: return "显示"
            case .hide: return "隐藏"
            case .alwaysHide: return "始终隐藏"
            case .applyProfile: return "切换到档案"
            }
        }

        public var targetZone: MenuBarZone? {
            switch self {
            case .show: return .visible
            case .hide: return .hidden
            case .alwaysHide: return .alwaysHidden
            case .applyProfile: return nil
            }
        }
    }

    public let kind: Kind
    /// kind != .applyProfile 时必填
    public let itemID: String?
    /// kind == .applyProfile 时必填
    public let profileName: String?

    public init(kind: Kind, itemID: String? = nil, profileName: String? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.profileName = profileName
    }

    /// 单图标动作
    public static func show(_ itemID: String) -> RuleAction { .init(kind: .show, itemID: itemID) }
    /// 按目标分区构造（编辑器用：选了"隐藏"就得到 hide）
    public static func forZone(_ zone: MenuBarZone) -> RuleAction {
        switch zone {
        case .visible: return .init(kind: .show)
        case .hidden: return .init(kind: .hide)
        case .alwaysHidden: return .init(kind: .alwaysHide)
        }
    }
    public static func hide(_ itemID: String) -> RuleAction { .init(kind: .hide, itemID: itemID) }
    public static func alwaysHide(_ itemID: String) -> RuleAction { .init(kind: .alwaysHide, itemID: itemID) }
    public static func applyProfile(_ name: String) -> RuleAction { .init(kind: .applyProfile, profileName: name) }
}

/// 一条规则：多个条件为 AND 关系
public struct DisplayRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public var isEnabled: Bool
    /// 数字越小优先级越高；同一图标动作冲突时高优先级胜出
    public var priority: Int

    public init(
        id: UUID = UUID(),
        name: String,
        conditions: [RuleCondition],
        actions: [RuleAction],
        isEnabled: Bool = true,
        priority: Int = 100
    ) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.actions = actions
        self.isEnabled = isEnabled
        self.priority = priority
    }

    public var isEvaluable: Bool {
        !conditions.isEmpty && !actions.isEmpty
    }
}

extension SystemContext {
    public func hour(in calendar: Calendar) -> Int {
        calendar.component(.hour, from: now)
    }
}
