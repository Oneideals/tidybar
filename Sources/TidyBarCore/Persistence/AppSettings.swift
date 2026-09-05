import Foundation
import CoreGraphics

/// 用户设置（持久化到 UserDefaults，suite 与 bundle id 对齐）。
/// 只存「用户意图」，图标位置真相源仍是 MenuBarLayout。
public struct AppSettings: Codable, Equatable, Sendable {
    /// 呼出方式集合（报告 A4）
    public var revealTriggers: Set<RevealTrigger>
    /// 自动重新隐藏延迟，0 = 不自动收起（报告 A6）
    public var rehideDelay: TimeInterval
    /// 新图标默认归位分区（报告 A7）
    public var newItemZone: MenuBarZone
    /// 图标间距微调（报告 E2）
    public var itemSpacing: CGFloat
    /// 是否启用菜单栏着色/圆角等样式（报告 E1）
    public var stylingEnabled: Bool
    /// 规则总开关
    public var rulesEnabled: Bool
    /// 收纳面板背景跟随菜单栏取色。开启会用到屏幕采样，可能触发录屏权限弹窗，
    /// 因此默认关闭（报告 §4.4 风险条目的落地处理）。
    public var followMenuBarColorEnabled: Bool
    /// 崩溃/异常退出后是否自动按未完成的意图重放
    public var autoRecoverPendingIntent: Bool
    /// 布局档案（报告 C2）：名称 → 布局
    public var profiles: [String: MenuBarLayout]
    /// 上次激活的档案
    public var activeProfileName: String?
    /// 用户自定义规则
    public var rules: [DisplayRule]
    /// 新图标策略（报告 A7）里的"先问我"。开新字段必须同步下面的 `init(from:)`。
    public var askAboutNewItems: Bool
    /// 首启向导是否已完成/被跳过（B1）。以前不敢存，就是因为合成 Codable 会让老文件解码失败。
    public var hasCompletedFirstRunGuide: Bool

    public init(
        revealTriggers: Set<RevealTrigger> = RevealTrigger.beginnerDefaults,
        rehideDelay: TimeInterval = 2.0,
        newItemZone: MenuBarZone = .hidden,
        itemSpacing: CGFloat = 0,
        stylingEnabled: Bool = false,
        rulesEnabled: Bool = true,
        followMenuBarColorEnabled: Bool = false,
        autoRecoverPendingIntent: Bool = true,
        profiles: [String: MenuBarLayout] = [:],
        activeProfileName: String? = nil,
        rules: [DisplayRule] = [],
        askAboutNewItems: Bool = false,
        hasCompletedFirstRunGuide: Bool = false
    ) {
        self.revealTriggers = revealTriggers
        self.rehideDelay = rehideDelay
        self.newItemZone = newItemZone
        self.itemSpacing = itemSpacing
        self.stylingEnabled = stylingEnabled
        self.rulesEnabled = rulesEnabled
        self.followMenuBarColorEnabled = followMenuBarColorEnabled
        self.autoRecoverPendingIntent = autoRecoverPendingIntent
        self.profiles = profiles
        self.activeProfileName = activeProfileName
        self.rules = rules
        self.askAboutNewItems = askAboutNewItems
        self.hasCompletedFirstRunGuide = hasCompletedFirstRunGuide
    }

    /// 逐字段 `decodeIfPresent`。
    ///
    /// 为什么要手写：合成解码遇到**缺字段**会整份失败，而 `load()` 外面套的是 `try?`——
    /// 结果是"升级到带新字段的版本 ⇒ 老用户全部设置被静默重置成默认值"，
    /// 症状还是"我没动过设置，它自己变回去了"，最难归因的一类。
    /// 有了这个 init，加字段就是安全的；新增字段请同时给默认值并在此登记。
    enum CodingKeys: String, CodingKey {
        case revealTriggers, rehideDelay, newItemZone, itemSpacing, stylingEnabled
        case rulesEnabled, followMenuBarColorEnabled, autoRecoverPendingIntent
        case profiles, activeProfileName, rules, askAboutNewItems, hasCompletedFirstRunGuide
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        revealTriggers = try c.decodeIfPresent(Set<RevealTrigger>.self, forKey: .revealTriggers)
            ?? defaults.revealTriggers
        rehideDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .rehideDelay) ?? defaults.rehideDelay
        newItemZone = try c.decodeIfPresent(MenuBarZone.self, forKey: .newItemZone) ?? defaults.newItemZone
        itemSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .itemSpacing) ?? defaults.itemSpacing
        stylingEnabled = try c.decodeIfPresent(Bool.self, forKey: .stylingEnabled) ?? defaults.stylingEnabled
        rulesEnabled = try c.decodeIfPresent(Bool.self, forKey: .rulesEnabled) ?? defaults.rulesEnabled
        followMenuBarColorEnabled = try c.decodeIfPresent(Bool.self, forKey: .followMenuBarColorEnabled)
            ?? defaults.followMenuBarColorEnabled
        autoRecoverPendingIntent = try c.decodeIfPresent(Bool.self, forKey: .autoRecoverPendingIntent)
            ?? defaults.autoRecoverPendingIntent
        profiles = try c.decodeIfPresent([String: MenuBarLayout].self, forKey: .profiles) ?? defaults.profiles
        activeProfileName = try c.decodeIfPresent(String.self, forKey: .activeProfileName)
        rules = try c.decodeIfPresent([DisplayRule].self, forKey: .rules) ?? defaults.rules
        askAboutNewItems = try c.decodeIfPresent(Bool.self, forKey: .askAboutNewItems) ?? false
        hasCompletedFirstRunGuide = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedFirstRunGuide) ?? false
    }

    /// 校验并夹紧非法值，避免旧版本或手工改 plist 造成的坏数据把工具搞崩
    public func sanitized() -> AppSettings {
        var copy = self
        copy.rehideDelay = min(max(copy.rehideDelay, 0), 10)
        copy.itemSpacing = min(max(copy.itemSpacing, -4), 24)
        if copy.revealTriggers.isEmpty { copy.revealTriggers = RevealTrigger.beginnerDefaults }
        return copy
    }
}

/// 设置存取。抽象成协议以便控制器注入内存假实现做单测。
public protocol SettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private let key = "tidybar.settings.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 上一次 `load()` 是否走了"读不出来 → 退回默认值"的路径。
    /// 有了显式解码这条本该极少触发；一旦触发就是真事故（用户会看到设置变默认值），
    /// 所以必须留下可读痕迹，而不是安静地装作首次运行。
    public private(set) var didFallBackToDefaults = false

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            didFallBackToDefaults = false
            return AppSettings()
        }
        guard let settings = try? decoder.decode(AppSettings.self, from: data) else {
            didFallBackToDefaults = true
            return AppSettings()
        }
        didFallBackToDefaults = false
        return settings.sanitized()
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? encoder.encode(settings.sanitized()) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 应用支持目录：布局日志、缓存等都放这里，不散落 dotfile（便于卸载干净）
public enum AppPaths {
    public static func supportDirectory(appName: String = "TidyBar") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var journalDirectory: URL {
        supportDirectory().appendingPathComponent("LayoutJournal", isDirectory: true)
    }

    /// 拖拽接管的已确认名单（按机器 + 系统版本各记一条），与布局日志分开存放。
    public static var dragGateFile: URL {
        supportDirectory().appendingPathComponent("drag-confirmed.json")
    }

    /// 跨启动身份台账（用户的分配 ↔ 图标历史名称）。与设置、布局日志分开：
    /// 三份文件的解码失败后果完全不同，不能共用一个 `try?` 回退。
    public static var identityLedgerFile: URL {
        supportDirectory().appendingPathComponent("identity-ledger.json")
    }
}
