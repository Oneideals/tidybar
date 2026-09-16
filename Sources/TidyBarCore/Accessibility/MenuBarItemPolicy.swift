import Foundation
import CoreGraphics

/// 图标身份来源。M0 真机结论决定了这个枚举的形状（docs/findings/01-enumeration.md）：
/// Tahoe 上第三方 NSStatusItem 普遍 **不提供** AXIdentifier / AXUUID / AXDescription，
/// Raycast 这类纯图标项甚至 AXTitle 都是空串——所以"靠名字做稳定 id"不成立，
/// 只能退到 (归属进程 + 该进程 extras 列表里的序号)，名字只作为显示用。
public enum ItemIdentitySource: String, Codable, CaseIterable, Sendable {
    /// AXTitle 有值：最理想，文本型状态项（如时钟、我们自己的 ☰）
    case axTitle
    /// 只有 AXDescription（部分 App 设了 accessibilityLabel）
    case axDescription
    /// 只能靠归属进程 + 序号：绝大多数纯图标项走这条
    case ownerOrdinal

    /// 序号参与 id 计算——只有名字不可用时才需要
    public var requiresOrdinal: Bool { self == .ownerOrdinal }

    public var label: String {
        switch self {
        case .axTitle: return "AX 标题"
        case .axDescription: return "AX 描述"
        case .ownerOrdinal: return "进程+序号"
        }
    }
}

/// 枚举结果准入策略。
///
/// 规则来自 M0 实测的四类脏数据，写成纯函数以便在无 GUI 环境下被用例钉住：
///   1. Control Center 把"当前不可见"的菜单项也报出来，实测 37 项里 33 项是 0×0。
///   2. AXExtrasMenuBar 子项里混有已弹出的菜单/窗口（实测见过 310×346 的弹层）。
///   3. 名字不可用不等于不是图标——恰恰相反，纯图标项本来就是没名字的，必须接受。
///   4. 跨屏时负 y 是合法的（实测副屏 frame.origin.y = -384），判定必须逐屏做。
public enum MenuBarItemPolicy {
    public enum Rejection: String, Equatable, Sendable, CaseIterable {
        /// 尺寸为 0 或非正：系统报出的不可见项
        case zeroSize
        /// 不在任何屏幕的菜单栏带内：弹层、离屏残留
        case outsideMenuBar

        public var explanation: String {
            switch self {
            case .zeroSize: return "尺寸为 0（系统报出的不可见项）"
            case .outsideMenuBar: return "不在菜单栏带内（弹层或离屏残留）"
            }
        }
    }

    /// 非拒绝但值得上报的降级：id 只能靠序号，App 重启后若图标顺序变化会需要重新认领
    public enum IdentityDowngrade: String, Equatable, Sendable, CaseIterable {
        case ordinalOnly
    }

    /// 身份强度。M0 实测 88% 的图标读不到名字，但"靠序号"内部还分两种稳定性：
    /// 单图标进程的序号恒为 0（结构上稳定，可持久化）；多图标进程才会因重排而错位。
    public enum IdentityStrength: String, Codable, CaseIterable, Sendable {
        /// 有 AXTitle / AXDescription，跨重启可靠
        case named
        /// 无名，但归属进程只有一个图标 → 序号恒 0，等价于稳定
        case soleItem
        /// 无名且归属进程有多个图标 → 只能按位置认领，重排会错位
        case positional

        /// 是否允许把用户配置持久化到这份身份上
        public var isPersistent: Bool {
            switch self {
            case .named, .soleItem: return true
            case .positional: return false
            }
        }

        public var label: String {
            switch self {
            case .named: return "按名称"
            case .soleItem: return "按归属 App（唯一图标）"
            case .positional: return "按位置认领"
            }
        }

        /// 设置界面提示文案；只有 positional 需要警告
        public var caveat: String? {
            switch self {
            case .named, .soleItem: return nil
            case .positional: return "该 App 有多个菜单栏图标且读不到名称，若它自己重排图标，需要你重新认领一次"
            }
        }
    }

    public struct Config: Sendable {
        /// 菜单栏图标允许的最大高度。实测正常项 22~30pt，弹层是几百 pt。
        public var maxItemHeight: CGFloat
        /// 允许的最大宽度。实测最宽的是时钟 146pt（含时间文字），弹层 310pt+。
        public var maxItemWidth: CGFloat
        /// 菜单栏带上下容差：机型菜单栏高实测 30~33pt
        public var menuBarTolerance: CGFloat

        public init(
            maxItemHeight: CGFloat = 44,
            maxItemWidth: CGFloat = 200,
            menuBarTolerance: CGFloat = 12
        ) {
            self.maxItemHeight = maxItemHeight
            self.maxItemWidth = maxItemWidth
            self.menuBarTolerance = menuBarTolerance
        }
    }

    /// 返回 nil 表示接受。
    public static func rejection(
        frame: CGRect,
        screens: [ScreenInfo],
        config: Config = Config()
    ) -> Rejection? {
        guard frame.width > 0, frame.height > 0 else { return .zeroSize }
        guard frame.height <= config.maxItemHeight, frame.width <= config.maxItemWidth else {
            return .outsideMenuBar
        }
        // 逐屏判定：任一块屏幕的菜单栏带内含图标中心即认为在菜单栏上
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let onSomeMenuBar = screens.contains(where: { (screen: ScreenInfo) -> Bool in
            let bandTop = screen.frame.maxY
            let bandBottom = screen.frame.maxY - screen.menuBarHeight - config.menuBarTolerance
            guard center.y >= bandBottom && center.y <= bandTop else { return false }
            if screen.frame.contains(center) { return true }
            // 两条分隔符可能同时展开为超大跨度（10,000pt 推杆）；保留被推到左侧的真实图标供搜索与状态判断。
            let hiddenSpan = max(25_000, 2 * max(2000, screen.frame.width + 200))
            if center.x >= screen.frame.minX - hiddenSpan && center.x <= screen.frame.maxX {
                return true
            }
            return false
        })
        return onSomeMenuBar ? nil : .outsideMenuBar
    }
}

/// 枚举刷新节奏。实测数字决定了它只能是"事件驱动 + 去抖动"，不能定时轮询。
public enum EnumerationCadence {
    /// 冷启动全量扫描实测 ~2.6-3.4s（首次对每个进程建 AX 连接）、
    /// 稳态 p50 约 110ms / p95 约 195ms（本机 90 进程、27 个可见第三方图标）。
    /// 结论：冷启动不得同步等待（否则 2s 接管预算必爆），稳态也不得高频轮询。
    public static let measuredColdStartMilliseconds = 2_622.0
    public static let measuredSteadyP50Milliseconds = 110.0
    public static let measuredSteadyP95Milliseconds = 195.0

    /// 去抖窗口：必须 ≥ 实测 p95，否则一次图标抖动会引发连环重扫
    public static let debounceInterval: TimeInterval = 0.25

    /// 允许触发刷新的事件（其它一律不刷新，守住空闲 CPU ≈ 0%）
    public enum Trigger: String, CaseIterable, Sendable {
        case itemAppeared
        case itemDisappeared
        case frontmostAppChanged
        case screenParametersChanged
        case userRequested
    }

    /// 纯函数：同一触发源在去抖窗口内只放行一次
    public static func shouldRefresh(
        lastRefreshAt: Date?,
        now: Date,
        interval: TimeInterval = debounceInterval
    ) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= interval
    }
}
