import Foundation

/// 菜单栏三分区模型（沿用 Ice 已验证、用户已形成心智的分区方式）。
/// 报告对应功能：A2 三分区模型。
public enum MenuBarZone: String, Codable, CaseIterable, Sendable, Comparable {
    /// 常驻显示区：始终占据菜单栏空间
    case visible
    /// 隐藏区：折叠时不占空间，可通过分隔符/悬停/滚动/面板呼出
    case hidden
    /// 始终隐藏区：只能经面板、搜索或快捷键激活
    case alwaysHidden

    /// 图标在物理菜单栏上从左到右的分区次序
    public var sortOrder: Int {
        switch self {
        case .visible: return 0
        case .hidden: return 1
        case .alwaysHidden: return 2
        }
    }

    /// 该分区的图标是否真实占据菜单栏宽度
    public var occupiesMenuBar: Bool {
        self != .alwaysHidden
    }

    /// 面向泛 Mac 用户的分区名称（设置界面与提示文案复用）
    public var displayLabel: String {
        switch self {
        case .visible: return "显示"
        case .hidden: return "隐藏（可展开）"
        case .alwaysHidden: return "始终隐藏"
        }
    }

    public static func < (lhs: MenuBarZone, rhs: MenuBarZone) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
