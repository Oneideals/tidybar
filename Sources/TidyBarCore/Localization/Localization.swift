import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var displayName: String {
        switch self {
        case .system: return "跟随系统 (System)"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// TidyBar 集中本地化支持（中 / 英双语）
public enum L10n {
    /// 全局语言配置（默认跟随系统）
    public static var currentLanguage: AppLanguage = .system

    public static var isChinese: Bool {
        switch currentLanguage {
        case .zhHans: return true
        case .en: return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? ""
            return preferred.hasPrefix("zh")
        }
    }

    public static func tr(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    // MARK: - 状态栏与上下文菜单
    public static var foldIcons: String { tr("折叠菜单栏图标", "Fold Menu Bar Icons") }
    public static var unfoldIcons: String { tr("展开菜单栏图标", "Unfold Menu Bar Icons") }
    public static var showDrawer: String { tr("显示收纳抽屉", "Show Drawer") }
    public static var hideDrawer: String { tr("收起收纳抽屉", "Hide Drawer") }
    public static var searchIcons: String { tr("搜索图标…", "Search Icons…") }
    public static var rescanMenuBar: String { tr("重新扫描菜单栏", "Rescan Menu Bar") }
    public static var reconcilePositions: String { tr("规整菜单栏位置", "Reconcile Icon Positions") }
    public static var placeDividers: String { tr("摆放菜单栏分隔符", "Place Menu Bar Dividers") }
    public static var retractDividers: String { tr("收起分隔符", "Retract Dividers") }
    public static var demoMode: String { tr("演示模式（全部收起）", "Demo Mode (Hide All)") }
    public static var organizeIcons: String { tr("整理图标", "Organize Icons") }
    public static var noIconsFound: String { tr("暂未读到任何图标", "No icons detected yet") }
    public static var pendingNewIcons: String { tr("新图标待确认", "Pending New Icons") }
    public static var layoutProfiles: String { tr("布局预设", "Layout Profiles") }
    public static var noSavedProfiles: String { tr("暂无保存的预设", "No saved profiles") }
    public static var saveCurrentLayoutPrompt: String { tr("将当前布局另存为预设…", "Save Current Layout as Profile…") }
    public static var settings: String { tr("偏好设置…", "Settings…") }
    public static var aboutTidyBar: String { tr("关于 TidyBar…", "About TidyBar…") }
    public static var quitTidyBar: String { tr("退出 TidyBar", "Quit TidyBar") }
    public static var arrangingMenuBar: String { tr("正在整理菜单栏…", "Arranging menu bar…") }
    public static var accessibilityWarning: String { tr("⚠️ 辅助功能权限未就绪（点击授权）", "⚠️ Accessibility permission required (click to grant)") }

    // MARK: - 分区
    public static var zoneVisible: String { tr("显示", "Visible") }
    public static var zoneHidden: String { tr("收纳（点 ☰ 呼出）", "Hidden (Click ☰ to reveal)") }
    public static var zoneAlwaysHidden: String { tr("始终隐藏", "Always Hidden") }

    // MARK: - 设置窗口 Tab 标题
    public static var tabLayout: String { tr("菜单栏布局", "Menu Bar Layout") }
    public static var tabTriggers: String { tr("触发手势", "Gestures & Triggers") }
    public static var tabGeneral: String { tr("常规设置", "General") }
    public static var tabAdvanced: String { tr("高级与诊断", "Advanced & Diagnostics") }

    // MARK: - 设置窗口：布局
    public static var layoutTitle: String { tr("菜单栏布局整理", "Menu Bar Layout") }
    public static var layoutSubtitle: String { tr("在下方拟态托盘间自由拖拽图标以划分状态区，配置即时生效。", "Drag icons between simulated zones below to organize. Changes take effect instantly.") }
    public static var reconcileButtonTitle: String { tr("✨ 规整菜单栏分区", "✨ Reconcile Partitions") }
    public static var reconcileTooltip: String { tr("将隐藏区与始终隐藏区的所有图标一次性规整至显示区左侧，确保抽屉呼出时永远位于最左侧", "Realign all hidden and always-hidden icons to the left of the visible zone.") }

    // MARK: - 设置窗口：手势与触发
    public static var triggersTitle: String { tr("手势与快捷呼出（自然体验）", "Gestures & Shortcuts") }
    public static var cardGesturesTitle: String { tr("菜单栏自然手势", "Natural Menu Bar Gestures") }
    public static var cardGesturesSubtitle: String { tr("无需瞄准点击 ☰ 小按钮，在菜单栏区域随手即可触发。", "Trigger effortlessly anywhere on the menu bar without precision clicking.") }
    public static var toggleEmptyBarClick: String { tr("点击菜单栏空白处触发", "Click empty menu bar area") }
    public static var toggleScroll: String { tr("在菜单栏上双指滚轮/横滑触发", "Two-finger scroll / swipe on menu bar") }
    public static var toggleHover: String { tr("光标在菜单栏空白处悬停触发", "Hover cursor over empty menu bar area") }
    public static var actionToggleFold: String { tr("目标：原地展开/折叠菜单栏", "Action: Fold / Unfold Menu Bar") }
    public static var actionToggleDrawer: String { tr("目标：呼出/收起收纳抽屉", "Action: Open / Close Drawer") }
    public static var cardShortcutsTitle: String { tr("快捷键与 Spotlight 搜索", "Shortcuts & Spotlight Search") }
    public static var cardShortcutsSubtitle: String { tr("随时随地一键唤醒菜单栏图标或居中搜索。", "Instantly summon your icons or perform centered Spotlight-like search.") }
    public static var hotkeyLabelPrefix: String { tr("• 呼出抽屉快捷键：", "• Summon drawer shortcut: ") }
    public static var testDrawerButton: String { tr("立即呼出收纳抽屉试试", "Test Drawer Now") }
    public static var searchHudLabel: String { tr("• Spotlight 搜索 HUD：在菜单中点击或按 ⌘F 呼出", "• Spotlight Search HUD: Click in menu or press ⌘F") }
    public static var testSearchButton: String { tr("立即呼出搜索 HUD 试试", "Test Search HUD Now") }

    // MARK: - 设置窗口：常规
    public static var generalTitle: String { tr("常规与行为偏好", "General Preferences") }
    public static var cardStartupTitle: String { tr("系统启动与图标策略", "Startup & Icon Policy") }
    public static var cardStartupSubtitle: String { tr("管理开机行为以及新出现的未收纳图标。", "Manage startup behavior and unassigned newly launched icons.") }
    public static var launchAtLogin: String { tr("开机自动启动 TidyBar", "Launch TidyBar at login") }
    public static var launchNeedsApproval: String { tr("开机自动启动：需在系统设置里批准", "Launch at login: Requires approval in System Settings") }
    public static var launchUnavailable: String { tr("开机自动启动不可用：", "Launch at login unavailable: ") }
    public static var askAboutNewItems: String { tr("出现新图标时先问我", "Ask when new menu bar icons appear") }

    // MARK: - 系统设置已隐藏应用（macOS 27+）
    public static var systemHiddenAppsTitle: String { tr("macOS 系统设置已隐藏项", "macOS System Settings Hidden Items") }
    public static var systemHiddenAppsSubtitle: String {
        tr("在 macOS「系统设置 -> 菜单栏与控制中心」中被禁用的应用。TidyBar 自动感知并豁免整理，无需重复配置。",
           "Apps disabled in macOS System Settings. TidyBar automatically detects and exempts them from management.")
    }
    public static var systemHiddenAppsEmpty: String {
        tr("当前无系统设置隐藏的应用（全部菜单栏应用均由 TidyBar 统一智能收纳）。",
           "No apps hidden by macOS System Settings (all menu bar apps managed by TidyBar).")
    }
    public static var systemHiddenBadge: String { tr("系统已隐藏", "System Hidden") }
    public static var openSystemControlCenterSettings: String { tr("打开系统控制中心与菜单栏设置…", "Open macOS Control Center Settings…") }
    public static var systemHiddenExemptNotice: String { tr("已被 macOS 系统设置隐藏，TidyBar 自动豁免二次整理", "Hidden by macOS System Settings; exempt from TidyBar arrangement") }
    public static var cardRehideTitle: String { tr("长显区域显示时间（临时浮现）", "Visible Area Dwell Time") }
    public static var cardRehideSubtitle: String { tr("从收纳抽屉点击图标临时显示在长显区域后的停留时间，支持右键唤出菜单，超时无操作自动收回。", "How long a drawer icon temporarily stays in the visible zone after being clicked.") }
    public static var rehideNever: String { tr("长显显示：从不自动收起", "Dwell Time: Never auto-rehide") }
    public static func rehideSeconds(_ s: Double) -> String {
        tr(String(format: "长显显示：%.1f 秒（无操作后收回）", s), String(format: "Dwell Time: %.1f seconds", s))
    }
    public static var cardStylingTitle: String { tr("外观美化（可选）", "Menu Bar Appearance (Optional)") }
    public static var cardStylingSubtitle: String { tr("在菜单栏下方绘制微妙的半透明胶囊背景（鼠标点击穿透）。", "Draws a subtle translucent capsule background under the menu bar.") }
    public static var enableStyling: String { tr("启用菜单栏美化（圆角胶囊背景）", "Enable menu bar styling (rounded capsule)") }
    public static var cardLanguageTitle: String { tr("界面语言", "Language") }
    public static var cardLanguageSubtitle: String { tr("选择 TidyBar 的界面显示语言。", "Choose interface language for TidyBar.") }

    // MARK: - 设置窗口：高级与诊断
    public static var advancedTitle: String { tr("系统高级与安全诊断", "Advanced & Diagnostics") }
    public static var cardPerformanceTitle: String { tr("常驻性能指标（守门测试）", "Performance Budget & Health") }
    public static var cardPerformanceSubtitle: String { tr("以系统真实物理驻留（phys_footprint）为准，严守预算。", "Strictly monitored via system physical footprint.") }
    public static var memoryLabel: String { tr("内存占用：", "Memory footprint: ") }
    public static var memoryBudgetSuffix: String { tr("（预算 ≤40 MB）｜ CPU：未采样", " (Budget ≤40 MB) | CPU: Idle") }
    public static var cardPrivacyTitle: String { tr("本地隐私与健康诊断", "Privacy & Diagnostics") }
    public static var cardPrivacySubtitle: String { tr("100% 本地纯净运行，零网络请求、零遥测；支持一键打包导出诊断信息用于排错。", "100% offline, zero telemetry. Export diagnostics bundle to report bugs.") }
    public static var privacyNotice: String { tr("隐私保证：纯本地运行，零网络请求、零遥测收集；配置保存在本地。", "Privacy Guarantee: 100% offline, zero network requests, zero telemetry.") }
    public static var exportDiagnosticsButton: String { tr("📦 导出系统诊断日志包…", "📦 Export Diagnostics Bundle…") }
    public static var reportIssueButton: String { tr("🌐 在 GitHub 提交 Issue 反馈", "🌐 Report Issue on GitHub") }
    public static var viewPrivacyPolicyButton: String { tr("📄 查看隐私政策 (Privacy Policy)", "📄 View Privacy Policy") }
    public static var cardRulesTitle: String { tr("自动化与高级规则", "Automation & Smart Rules") }
    public static var cardRulesSubtitle: String { tr("配置基于电量、Wi-Fi、聚焦模式或前台 App 的自动显示/隐藏规则。", "Configure automated rules based on battery, Wi-Fi, focus modes, or active apps.") }
    public static var openRuleEditorButton: String { tr("打开规则编辑器…", "Open Rule Editor…") }

    // MARK: - 首启向导
    public static func wizardTitle(step: Int) -> String {
        tr("欢迎用 TidyBar（\(step)/3）", "Welcome to TidyBar (\(step)/3)")
    }
    public static var wizardStep1Body: String {
        tr("第 1 步：辅助功能权限用于读取和整理菜单栏图标。\n在系统设置中授予后，TidyBar 才能实时读取状态项几何位置并智能整理。",
           "Step 1: Accessibility permission is required to inspect and organize menu bar icons.\nGrant permission in System Settings so TidyBar can manage status items.")
    }
    public static var wizardStep1ScreenCaptureNote: String {
        tr("\n可选权限：屏幕录制权限（用于捕获高保真像素图标，若未授予将自动降级为官方高清图标渲染）。",
           "\nOptional: Screen Recording permission (used for pixel-accurate icon capture; falls back cleanly to native Dock icons if not granted).")
    }
    public static var openAccessibilityButton: String { tr("前往系统设置授权辅助功能…", "Open Accessibility Settings…") }
    public static var openScreenCaptureButton: String { tr("前往系统设置授权屏幕录制…", "Open Screen Recording Settings…") }
    public static var wizardStep2BodyPrefix: String {
        tr("第 2 步：这张表就是全景——每个图标现在在哪个区一目了然。\n点右侧按钮即可调整；默认策略是",
           "Step 2: Here is your full overview — easily see which zone each icon belongs to.\nUse the buttons to organize; default policy is ")
    }
    public static var wizardStep2Ask: String { tr("出现新图标时先问你", "ask when new icons appear") }
    public static var wizardStep2Auto: String { tr("新图标自动收进隐藏区", "automatically hide new icons") }
    public static var wizardStep2BodySuffix: String {
        tr("。也可以完全跳过，之后随时在偏好设置里调整。",
           ". You can also skip now and customize anytime in Settings.")
    }
    public static var wizardStep3Body: String {
        tr("第 3 步：呼出隐藏区——点击 ☰ 状态栏图标、点击菜单栏分隔符，或在菜单栏空白区域点击/双指轻扫即可随时呼出。\n点击「完成」立即开始体验！",
           "Step 3: Summon Hidden Icons — Click the ☰ status bar icon, click the divider, or simply click/swipe on any empty menu bar area.\nClick 'Finish' to start enjoying a clean menu bar!")
    }
    public static var buttonNext: String { tr("下一步", "Next") }
    public static var buttonSkip: String { tr("跳过", "Skip") }
    public static var buttonFinish: String { tr("完成", "Finish") }

    // MARK: - 关于面板
    public static var aboutTitle: String { tr("关于 TidyBar", "About TidyBar") }
    public static var appTagline: String {
        tr("装完即忘的 macOS 菜单栏管家：默认干净，需要时聪明。",
           "The set-and-forget macOS menu bar manager: clean by default, smart when needed.")
    }
    public static var gitHubRepoButton: String { tr("GitHub 仓库", "GitHub Repository") }
    public static var feedbackButton: String { tr("提交反馈", "Feedback & Issues") }
    public static var licenseButton: String { tr("开源许可证 (MIT)", "MIT License") }
    public static var copyrightNotice: String {
        tr("© 2026 Oneideals. 基于 MIT 协议完全开源。", "© 2026 Oneideals. Open source under the MIT License.")
    }
}
