import Foundation
import CoreGraphics

/// 一个被工具接管的菜单栏图标。
///
/// `id` 必须在跨启动、跨布局后保持稳定，否则每次系统更新都会丢失用户配置。
/// 稳定性策略：`ownerBundleID + 归一化 title`（见 `stableID(...)`）。
public struct ManagedItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    /// 归属 App 的 bundle id；系统项（时钟、 Wi‑Fi、控制中心等）可能为 nil
    public let ownerBundleID: String?
    public var title: String
    /// 屏幕坐标（左上角原点系，AppKit 约定），用于计算 ⌘ 拖拽目标位置
    public var frame: CGRect
    /// 是否为系统自带菜单栏项（默认不参与自动隐藏，降低误伤风险）
    public var isSystemOwned: Bool
    /// 最近一次被用户点击的时间，用于 P2-G1「图标健康度」
    public var lastActivatedAt: Date?

    public init(
        id: String,
        ownerBundleID: String?,
        title: String,
        frame: CGRect,
        isSystemOwned: Bool = false,
        lastActivatedAt: Date? = nil
    ) {
        self.id = id
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.frame = frame
        self.isSystemOwned = isSystemOwned
        self.lastActivatedAt = lastActivatedAt
    }

    /// 构造跨会话稳定的图标标识。
    public static func stableID(ownerBundleID: String?, title: String) -> String {
        let normalizedBundle = (ownerBundleID ?? "com.apple.system")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return "\(normalizedBundle).\(normalizedTitle)"
    }

    /// 图标中心点 X 坐标，⌘ 拖拽的目标锚点
    public var centerX: CGFloat {
        frame.midX
    }
}

extension ManagedItem {
    /// 供事件层使用的原始发现结果（不含分区信息，分区由 MenuBarLayout 决定）
    public struct Discovery: Equatable, Sendable {
        public let ownerBundleID: String?
        public let title: String
        public let frame: CGRect
        public let isSystemOwned: Bool

        public init(ownerBundleID: String?, title: String, frame: CGRect, isSystemOwned: Bool) {
            self.ownerBundleID = ownerBundleID
            self.title = title
            self.frame = frame
            self.isSystemOwned = isSystemOwned
        }

        public var item: ManagedItem {
            ManagedItem(
                id: ManagedItem.stableID(ownerBundleID: ownerBundleID, title: title),
                ownerBundleID: ownerBundleID,
                title: title,
                frame: frame,
                isSystemOwned: isSystemOwned
            )
        }
    }
}
