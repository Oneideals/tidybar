import Foundation

/// 智能菜单栏图标分类器。
///
/// 解决痛点：用户菜单栏通常有 20~40 个图标，手动拖拽分类成本极高。
/// 算法基于真实的 macOS 菜单栏人机工学与高频应用指纹库，
/// 自动分析每个图标的归属类型、使用特征与唤起方式，计算出推荐分区。
public enum SmartItemClassifier {
    public enum Category: String, Sendable, CaseIterable {
        case systemEssential = "系统核心状态"
        case instantMessage = "即时通讯/高频通知"
        case networkMonitor = "实时网络监控"
        case hotkeyLauncher = "快捷键启动/全局搜索"
        case hardwareUtility = "系统与硬件辅助"
        case backgroundDaemon = "后台守护/驱动服务"
        case clipboardAutomation = "剪贴板与效率自动化"
        case windowGesture = "窗口管理与鼠标手势"
        case other = "其他应用"
    }

    public struct Recommendation: Equatable, Sendable {
        public let itemID: String
        public let title: String
        public let ownerBundleID: String?
        public let recommendedZone: MenuBarZone
        public let category: Category
        public let reason: String

        public init(
            itemID: String,
            title: String,
            ownerBundleID: String?,
            recommendedZone: MenuBarZone,
            category: Category,
            reason: String
        ) {
            self.itemID = itemID
            self.title = title
            self.ownerBundleID = ownerBundleID
            self.recommendedZone = recommendedZone
            self.category = category
            self.reason = reason
        }
    }

    /// 对单一条目进行智能分析与分区推荐
    public static func classify(item: ManagedItem) -> Recommendation {
        let bundleID = (item.ownerBundleID ?? "").lowercased()
        let title = item.title.lowercased()
        let combined = "\(bundleID) \(title)"

        // 0. TidyBar 本身
        if bundleID.contains("tidybar") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .visible,
                category: .systemEssential,
                reason: "TidyBar 自身的控制入口，必须常驻"
            )
        }

        // 1. 系统核心状态（时间、输入法、控制中心、麦克风安全指示）
        if item.isSystemOwned || bundleID.contains("controlcenter") || bundleID.contains("textinput") {
            if combined.contains("时钟") || combined.contains("clock") || combined.contains("time") || combined.contains("星期") || combined.contains("年") {
                return Recommendation(
                    itemID: item.id,
                    title: item.title,
                    ownerBundleID: item.ownerBundleID,
                    recommendedZone: .visible,
                    category: .systemEssential,
                    reason: "时间与日期是高频查看的系统基础状态"
                )
            }
            if combined.contains("输入法") || combined.contains("textinput") {
                return Recommendation(
                    itemID: item.id,
                    title: item.title,
                    ownerBundleID: item.ownerBundleID,
                    recommendedZone: .visible,
                    category: .systemEssential,
                    reason: "输入法状态指示便于中英/全半角切换确认"
                )
            }
            if combined.contains("控制中心") || combined.contains("录屏") || combined.contains("麦克风") {
                return Recommendation(
                    itemID: item.id,
                    title: item.title,
                    ownerBundleID: item.ownerBundleID,
                    recommendedZone: .visible,
                    category: .systemEssential,
                    reason: "系统级核心控制台与硬件隐私状态指示"
                )
            }
        }

        // 2. 即时通讯与高频未读通知类应用（建议保持显示，方便看未读红点）
        let imIdentifiers = ["xinwechat", "wechat", "dingtalk", "feishu", "lark", "slack", "telegram", "qq"]
        if imIdentifiers.contains(where: { combined.contains($0) }) {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .visible,
                category: .instantMessage,
                reason: "即时通讯工具需要实时观察新消息红点与未读角标"
            )
        }

        // 3. 实时网速/流量监测器（如 Surge、iStat Menus）
        if combined.contains("surge") || combined.contains("istat") || combined.contains("netspeed") || combined.contains("traffic") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .visible,
                category: .networkMonitor,
                reason: "实时网速与网络监测，方便随时确认连接状态"
            )
        }

        // 4. 纯底层驱动与无交互后台服务（推荐始终隐藏）
        if combined.contains("paragon") || combined.contains("ntfs") || combined.contains("macvirt") || combined.contains("orbstack") || combined.contains("docker") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .alwaysHidden,
                category: .backgroundDaemon,
                reason: "纯底层服务/磁盘驱动，平时无需任何日常菜单栏交互"
            )
        }

        // 5. 快捷键唤起型启动器/搜索/密码（推荐收纳隐藏）
        if combined.contains("raycast") || combined.contains("hapigo") || combined.contains("alfred") || combined.contains("1password") || combined.contains("flomo") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .hidden,
                category: .hotkeyLauncher,
                reason: "日常完全通过全局快捷键呼出，无需长期占据显眼菜单栏位"
            )
        }

        // 6. 剪贴板与鼠标划词自动化（推荐收纳隐藏）
        if combined.contains("paste") || combined.contains("popclip") || combined.contains("bob") || combined.contains("dropover") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .hidden,
                category: .clipboardAutomation,
                reason: "依托选词弹出、全局快捷键或鼠标拖拽触发，菜单栏仅用于配置"
            )
        }

        // 7. 窗口管理与系统手势增强（推荐收纳隐藏）
        if combined.contains("rectangle") || combined.contains("hookshot") || combined.contains("betterandbetter") || combined.contains("bettertouchtool") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .hidden,
                category: .windowGesture,
                reason: "纯快捷键与手势驱动工具，日常静默生效"
            )
        }

        // 8. 硬件与系统辅助守护进程（推荐收纳隐藏）
        if combined.contains("aldente") || combined.contains("betterdisplay") || combined.contains("boom") || combined.contains("cleanmymac") || combined.contains("adguard") || combined.contains("quitall") || combined.contains("ccswitch") || combined.contains("devicespace") || combined.contains("1capture") || combined.contains("ticktick") || combined.contains("ghostdownloader") || combined.contains("python") || combined.contains("weather") {
            return Recommendation(
                itemID: item.id,
                title: item.title,
                ownerBundleID: item.ownerBundleID,
                recommendedZone: .hidden,
                category: .hardwareUtility,
                reason: "后台常驻辅助小工具，设定完毕后极少主动点击，适合收纳隐藏"
            )
        }

        // 9. 默认规则：其他第三方应用默认建议收纳到隐藏区以保持菜单栏清爽
        return Recommendation(
            itemID: item.id,
            title: item.title,
            ownerBundleID: item.ownerBundleID,
            recommendedZone: item.isSystemOwned ? .visible : .hidden,
            category: .other,
            reason: item.isSystemOwned ? "系统项默认保留在显示区" : "第三方应用收纳至隐藏区以保持菜单栏清爽"
        )
    }

    /// 批量计算所有条目的智能分区分配
    public static func classifyAll(items: [ManagedItem]) -> [Recommendation] {
        items.map { classify(item: $0) }
    }
}
