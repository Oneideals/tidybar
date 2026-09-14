import Foundation
import CoreGraphics

/// 一个被工具接管的菜单栏图标。
///
/// id 必须跨启动稳定，否则用户配置每次开机都会错位。但 M0 真机实测发现：
/// 第三方图标在 AX 里普遍**没有** AXIdentifier / AXUUID，连 AXTitle 都常是空串
/// （Raycast 即如此），所以"靠名字当 id"只对一部分图标成立。据此分两种身份：
///   · 有 AXTitle / AXDescription → owner + 归一化名字（跨重启稳定，首选）
///   · 只有 roleDescription      → owner + 该进程 extras 列表中的序号
///     （App 自己重排图标时会错位，因此显示名退回 App 名，UI 要提示"按位置认领"）
public struct ManagedItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    /// 归属 App 的 bundle id；系统项（时钟、控制中心等）可能是 com.apple.*，CLI 进程可能为 nil
    public let ownerBundleID: String?
    /// 用于显示的标题（已按可用来源解析过）
    public var title: String
    /// 屏幕坐标（AppKit 约定：左下原点、y 向上），用于计算 ⌘ 拖拽目标位置
    public var frame: CGRect
    /// 是否为系统自带菜单栏项（默认不参与自动隐藏，降低误伤风险）
    public var isSystemOwned: Bool
    /// 最近一次被用户点击的时间，用于 P2-G1「图标健康度」
    public var lastActivatedAt: Date?
    /// id 的可信度来源
    public let identitySource: ItemIdentitySource
    /// 在归属进程 extras 列表中的序号；仅序号型身份参与 id
    public let ordinalInOwner: Int
    /// 归属进程一共暴露了几个图标（判定"序号是否恒为 0"的依据）
    public let ownerItemCount: Int
    /// 仅用于匹配同一次 AX 观测；不进入用户配置、持久化或界面值比较。
    public internal(set) var observationToken: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, ownerBundleID, title, frame, isSystemOwned, lastActivatedAt, identitySource, ordinalInOwner, ownerItemCount
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.ownerBundleID == rhs.ownerBundleID && lhs.title == rhs.title
            && lhs.frame == rhs.frame && lhs.isSystemOwned == rhs.isSystemOwned
            && lhs.lastActivatedAt == rhs.lastActivatedAt && lhs.identitySource == rhs.identitySource
            && lhs.ordinalInOwner == rhs.ordinalInOwner && lhs.ownerItemCount == rhs.ownerItemCount
    }

    public init(
        id: String,
        ownerBundleID: String?,
        title: String,
        frame: CGRect,
        isSystemOwned: Bool = false,
        lastActivatedAt: Date? = nil,
        identitySource: ItemIdentitySource = .axTitle,
        ordinalInOwner: Int = 0,
        ownerItemCount: Int = 1
    ) {
        self.id = id
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.frame = frame
        self.isSystemOwned = isSystemOwned
        self.lastActivatedAt = lastActivatedAt
        self.identitySource = identitySource
        self.ordinalInOwner = ordinalInOwner
        self.ownerItemCount = ownerItemCount
    }

    /// 身份强度：命名身份最稳；无名的还要看归属进程是否只有一个图标
    public var identityStrength: MenuBarItemPolicy.IdentityStrength {
        switch identitySource {
        case .axTitle, .axDescription:
            return .named
        case .ownerOrdinal:
            return ownerItemCount <= 1 ? .soleItem : .positional
        }
    }

    /// 该图标的身份只靠位置成立（设置界面需提示：App 重排后可能错位）
    public var isPositionalIdentity: Bool { identityStrength == .positional }

    /// 用户配置能否持久化在这份身份上
    public var canPersistAssignment: Bool { identityStrength.isPersistent }

    /// 图标中心点 X 坐标，⌘ 拖拽的目标锚点
    public var centerX: CGFloat { frame.midX }

    // MARK: - id

    /// 构造跨会话稳定的图标标识。
    public static func stableID(
        ownerBundleID: String?,
        title: String,
        identitySource: ItemIdentitySource = .axTitle,
        ordinalInOwner: Int = 0
    ) -> String {
        let bundle = normalized(ownerBundleID ?? "com.apple.system")
        switch identitySource {
        case .axTitle, .axDescription:
            return bundle + "." + normalized(title)
        case .ownerOrdinal:
            return bundle + ".#item" + String(ordinalInOwner)
        }
    }

    /// 大小写 / 全半角 / 首尾空白差异不应产生新身份（标题会随语言与状态变化）
    public static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// 从稳定 id 中解析归属 App 的 Bundle ID
    public static func ownerFromID(_ id: String) -> String? {
        if let range = id.range(of: ".#item") {
            return String(id[..<range.lowerBound])
        }
        if let lastDot = id.lastIndex(of: ".") {
            return String(id[..<lastDot])
        }
        return id
    }

    /// 从稳定 id 中解析标题/可读名
    public static func titleFromID(_ id: String) -> String {
        if let range = id.range(of: ".#item") {
            let owner = String(id[..<range.lowerBound])
            return owner.components(separatedBy: ".").last ?? owner
        }
        if let lastDot = id.lastIndex(of: ".") {
            let titlePart = String(id[id.index(after: lastDot)...])
            return titlePart.isEmpty ? id : titlePart
        }
        return id
    }
}

extension ManagedItem {
    /// reader 的中间产物：已解析出身份来源，但还没算 id
    public struct Discovery: Equatable, Sendable {
        public let ownerBundleID: String?
        /// 归属 App 的可读名（NSRunningApplication.localizedName），序号型身份时用来生成显示名
        public let ownerDisplayName: String?
        public let axTitle: String?
        public let axDescription: String?
        public let frame: CGRect
        public let isSystemOwned: Bool
        public let ordinalInOwner: Int
        public let identitySource: ItemIdentitySource
        /// 归属进程一共暴露几个图标（判定序号是否恒为 0）
        public let ownerItemCount: Int

        public init(
            ownerBundleID: String?,
            ownerDisplayName: String? = nil,
            axTitle: String?,
            axDescription: String? = nil,
            frame: CGRect,
            isSystemOwned: Bool,
            ordinalInOwner: Int = 0,
            identitySource: ItemIdentitySource,
            ownerItemCount: Int = 1
        ) {
            self.ownerBundleID = ownerBundleID
            self.ownerDisplayName = ownerDisplayName
            self.axTitle = axTitle
            self.axDescription = axDescription
            self.frame = frame
            self.isSystemOwned = isSystemOwned
            self.ordinalInOwner = ordinalInOwner
            self.identitySource = identitySource
            self.ownerItemCount = ownerItemCount
        }

        /// 显示名优先级：AXTitle → AXDescription → App 可读名
        public var displayTitle: String {
            if let title = axTitle, !title.isEmpty { return title }
            if let description = axDescription, !description.isEmpty { return description }
            return ownerDisplayName ?? "菜单栏项"
        }

        /// id 里用的名字：序号型身份不能拿显示名参与（显示名含序号，会让 id 随显示变化），
        /// 所以只把"名字本身"交给 stableID；序号型直接走序号分支。
        public var item: ManagedItem {
            var item = ManagedItem(
                id: ManagedItem.stableID(
                    ownerBundleID: ownerBundleID,
                    title: displayTitle,
                    identitySource: identitySource,
                    ordinalInOwner: ordinalInOwner
                ),
                ownerBundleID: ownerBundleID,
                title: displayTitle,
                frame: frame,
                isSystemOwned: isSystemOwned,
                identitySource: identitySource,
                ordinalInOwner: ordinalInOwner,
                ownerItemCount: ownerItemCount
            )
            item.observationToken = UUID()
            return item
        }
    }
}
