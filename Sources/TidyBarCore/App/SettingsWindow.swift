import AppKit

/// 设置窗口（对标 Bartender 专业三行菜单栏托盘与多标签页管理）。
///
/// 刻意做得"直白"：每一项都是**读系统或读状态**再显示，不缓存自己算出来的假状态——
/// 开机自启尤其如此，用户在系统设置里手动改过之后，我们这里必须跟着变。
public final class TidyBarSettingsWindowController: NSWindowController {
    public enum Tab: String, CaseIterable {
        case layout = "layout"
        case triggers = "triggers"
        case general = "general"
        case advanced = "advanced"

        var title: String {
            switch self {
            case .layout: return L10n.tabLayout
            case .triggers: return L10n.tabTriggers
            case .general: return L10n.tabGeneral
            case .advanced: return L10n.tabAdvanced
            }
        }

        var iconName: String {
            switch self {
            case .layout: return "rectangle.3.group"
            case .triggers: return "hand.tap"
            case .general: return "gearshape"
            case .advanced: return "shield.lefthalf.filled"
            }
        }
    }

    private let controller: TidyBarController
    private var currentTab: Tab = .layout

    // 控件
    private let launchToggle = NSButton(checkboxWithTitle: L10n.launchAtLogin, target: nil, action: nil)
    private let askToggle = NSButton(checkboxWithTitle: L10n.askAboutNewItems, target: nil, action: nil)
    private let stylingToggle = NSButton(checkboxWithTitle: L10n.enableStyling, target: nil, action: nil)
    private let rehideStepper = NSStepper()
    private let rehideValue = NSTextField(labelWithString: "")
    private let hotKeyLine = NSTextField(labelWithString: "")
    private let performanceLine = NSTextField(labelWithString: "")
    private let privacyLine = NSTextField(wrappingLabelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let overview = IconOverviewView(onReassign: { _, _ in false })
    private let dividerButton = NSButton(title: "│ " + L10n.placeDividers, target: nil, action: nil)
    private let foldButton = NSButton(title: "▶ " + L10n.foldIcons, target: nil, action: nil)
    private let emptyBarToggle = NSButton(checkboxWithTitle: L10n.toggleEmptyBarClick, target: nil, action: nil)
    private let scrollToggle = NSButton(checkboxWithTitle: L10n.toggleScroll, target: nil, action: nil)
    private let hoverToggle = NSButton(checkboxWithTitle: L10n.toggleHover, target: nil, action: nil)
    private let emptyBarActionPopup = NSPopUpButton()
    private let scrollActionPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()

    // 侧边栏与内容容器
    private let sidebarContainer = NSVisualEffectView()
    private let contentContainer = NSView()
    private var sidebarButtons: [Tab: NSButton] = [:]
    private var tabViews: [Tab: NSView] = [:]

    /// 外部提供的截图缓存查找器，确保设置面板图标与菜单栏/抽屉风格一致。
    public var imageProvider: ((ManagedItem) -> CGImage?)?

    /// 点击打开规则编辑器的回调
    public var onOpenRuleEditor: (() -> Void)?

    public init(controller: TidyBarController, hotKeyDescription: String) {
        self.controller = controller
        L10n.currentLanguage = controller.settings.appLanguage
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidyBar 偏好设置"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 860, height: 580)
        super.init(window: window)
        overview.onReassign = { [weak controller] itemID, zone in
            controller?.reassignZone(itemID, to: zone) ?? false
        }
        overview.onZoneChanged = { [weak self] in self?.refresh() }
        overview.onRestoreAlwaysHidden = { [weak self, weak controller] in
            controller?.restoreAlwaysHiddenToHidden()
            self?.overview.reportNotice("已成功将始终隐藏区的所有图标全部恢复至隐藏区！")
            self?.refresh()
        }
        buildLayout(hotKeyDescription: hotKeyDescription)
        selectTab(.layout)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func buildLayout(hotKeyDescription: String) {
        guard let root = window?.contentView else { return }

        // 左侧现代侧边栏
        sidebarContainer.material = .sidebar
        sidebarContainer.blendingMode = .behindWindow
        sidebarContainer.state = .active
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarContainer)

        // 分割线
        let vDivider = NSBox()
        vDivider.boxType = .separator
        vDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vDivider)

        // 右侧内容区
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 190),

            vDivider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            vDivider.topAnchor.constraint(equalTo: root.topAnchor),
            vDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            vDivider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: vDivider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildSidebar()
        buildPanes(hotKeyDescription: hotKeyDescription)
    }

    private func buildSidebar() {
        // 顶部品牌标题
        let headerBox = NSView()
        headerBox.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(headerBox)

        let appTitle = NSTextField(labelWithString: "TidyBar")
        appTitle.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        appTitle.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(appTitle)

        let versionLabel = NSTextField(labelWithString: "v2.0 · 现代菜单栏管理")
        versionLabel.font = NSFont.systemFont(ofSize: 10)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(versionLabel)

        let buttonStack = NSStackView()
        buttonStack.orientation = .vertical
        buttonStack.alignment = .width
        buttonStack.spacing = 6
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            headerBox.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 18),
            headerBox.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 16),
            headerBox.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -16),
            headerBox.heightAnchor.constraint(equalToConstant: 40),

            appTitle.topAnchor.constraint(equalTo: headerBox.topAnchor),
            appTitle.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),

            versionLabel.topAnchor.constraint(equalTo: appTitle.bottomAnchor, constant: 2),
            versionLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),

            buttonStack.topAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: 14),
            buttonStack.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -12),
        ])

        for tab in Tab.allCases {
            let btn = createSidebarButton(tab: tab)
            sidebarButtons[tab] = btn
            buttonStack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalTo: buttonStack.widthAnchor).isActive = true
        }
    }

    private func createSidebarButton(tab: Tab) -> NSButton {
        let btn = NSButton(title: "  " + tab.title, target: self, action: #selector(sidebarClicked(_:)))
        btn.identifier = NSUserInterfaceItemIdentifier(tab.rawValue)
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.alignment = .left
        btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        btn.image = NSImage(systemSymbolName: tab.iconName, accessibilityDescription: tab.title)
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleProportionallyDown
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return btn
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let tab = Tab(rawValue: id) else { return }
        selectTab(tab)
    }

    private func selectTab(_ tab: Tab) {
        currentTab = tab
        for (t, btn) in sidebarButtons {
            if t == tab {
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                btn.contentTintColor = .controlAccentColor
                btn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            } else {
                btn.layer?.backgroundColor = NSColor.clear.cgColor
                btn.contentTintColor = .labelColor
                btn.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            }
        }

        for (t, pane) in tabViews {
            pane.isHidden = (t != tab)
        }
    }

    private func buildPanes(hotKeyDescription: String) {
        let layoutPane = buildLayoutPane()
        let triggersPane = buildTriggersPane(hotKeyDescription: hotKeyDescription)
        let generalPane = buildGeneralPane()
        let advancedPane = buildAdvancedPane()

        tabViews[.layout] = layoutPane
        tabViews[.triggers] = triggersPane
        tabViews[.general] = generalPane
        tabViews[.advanced] = advancedPane

        for (tab, pane) in tabViews {
            pane.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 28),
                pane.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -28),
                pane.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 20),
            ])
            if tab == .layout {
                pane.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -20).isActive = true
            } else {
                pane.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor, constant: -20).isActive = true
            }
        }
    }

    // MARK: - 页面 1：菜单栏布局
    private func buildLayoutPane() -> NSView {
        let view = NSView()
        let titleLabel = NSTextField(labelWithString: "菜单栏布局整理")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "在下方拟态托盘间自由拖拽图标以划分状态区，配置即时生效。")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        foldButton.bezelStyle = .rounded
        foldButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        foldButton.target = self
        foldButton.action = #selector(toggleFoldFromSettings)
        foldButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(foldButton)

        dividerButton.bezelStyle = .rounded
        dividerButton.font = NSFont.systemFont(ofSize: 12)
        dividerButton.target = self
        dividerButton.action = #selector(toggleDividers)
        dividerButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dividerButton)

        overview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overview)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),

            dividerButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dividerButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dividerButton.heightAnchor.constraint(equalToConstant: 28),

            foldButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            foldButton.trailingAnchor.constraint(equalTo: dividerButton.leadingAnchor, constant: -8),
            foldButton.heightAnchor.constraint(equalToConstant: 28),

            overview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overview.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            overview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    // MARK: - 页面 2：触发手势
    private func buildTriggersPane(hotKeyDescription: String) -> NSView {
        let view = NSView()

        let titleLabel = NSTextField(labelWithString: "手势与快捷呼出（对标 Ice 自然体验）")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // 卡片 1: 自然手势
        let (card1, stack1) = createCardView(title: "菜单栏自然手势", subtitle: "无需瞄准点击 ☰ 小按钮，在菜单栏区域随手即可触发。")

        let emptyBarRow = NSStackView()
        emptyBarRow.orientation = .horizontal
        emptyBarRow.spacing = 12
        emptyBarToggle.target = self
        emptyBarToggle.action = #selector(toggleEmptyBarClick)
        emptyBarRow.addArrangedSubview(emptyBarToggle)
        emptyBarActionPopup.removeAllItems()
        emptyBarActionPopup.addItems(withTitles: ["目标：原地展开/折叠菜单栏", "目标：呼出/收起收纳抽屉"])
        emptyBarActionPopup.target = self
        emptyBarActionPopup.action = #selector(changeEmptyBarAction)
        emptyBarActionPopup.font = NSFont.systemFont(ofSize: 11)
        emptyBarRow.addArrangedSubview(emptyBarActionPopup)
        stack1.addArrangedSubview(emptyBarRow)

        let scrollRow = NSStackView()
        scrollRow.orientation = .horizontal
        scrollRow.spacing = 12
        scrollToggle.target = self
        scrollToggle.action = #selector(toggleScroll)
        scrollRow.addArrangedSubview(scrollToggle)
        scrollActionPopup.removeAllItems()
        scrollActionPopup.addItems(withTitles: ["目标：原地展开/折叠菜单栏", "目标：呼出/收起收纳抽屉"])
        scrollActionPopup.target = self
        scrollActionPopup.action = #selector(changeScrollAction)
        scrollActionPopup.font = NSFont.systemFont(ofSize: 11)
        scrollRow.addArrangedSubview(scrollActionPopup)
        stack1.addArrangedSubview(scrollRow)

        hoverToggle.target = self
        hoverToggle.action = #selector(toggleHover)
        stack1.addArrangedSubview(hoverToggle)

        view.addSubview(card1)

        // 卡片 2: 快捷键 & Spotlight 搜索
        let (card2, stack2) = createCardView(title: "快捷键与 Spotlight 搜索", subtitle: "随时随地一键唤醒菜单栏图标或居中搜索。")

        let hotKeyRow = NSStackView()
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 12
        hotKeyLine.stringValue = "• 呼出抽屉快捷键：" + hotKeyDescription
        hotKeyLine.font = NSFont.systemFont(ofSize: 12)
        hotKeyRow.addArrangedSubview(hotKeyLine)

        let testDrawerBtn = NSButton(title: "立即呼出收纳抽屉试试", target: self, action: #selector(testDrawer))
        testDrawerBtn.bezelStyle = .rounded
        testDrawerBtn.font = NSFont.systemFont(ofSize: 11)
        hotKeyRow.addArrangedSubview(testDrawerBtn)
        stack2.addArrangedSubview(hotKeyRow)

        let searchRow = NSStackView()
        searchRow.orientation = .horizontal
        searchRow.spacing = 12
        let searchLabel = NSTextField(labelWithString: "• Spotlight 搜索 HUD：在菜单中点击或按 ⌘F 呼出")
        searchLabel.font = NSFont.systemFont(ofSize: 12)
        searchRow.addArrangedSubview(searchLabel)

        let testSearchBtn = NSButton(title: "立即呼出搜索 HUD 试试", target: self, action: #selector(testSearchHUD))
        testSearchBtn.bezelStyle = .rounded
        testSearchBtn.font = NSFont.systemFont(ofSize: 11)
        searchRow.addArrangedSubview(testSearchBtn)
        stack2.addArrangedSubview(searchRow)

        view.addSubview(card2)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),

            card1.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            card1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card1.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card2.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card2.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    // MARK: - 页面 3：常规设置
    private func buildGeneralPane() -> NSView {
        let view = NSView()

        let titleLabel = NSTextField(labelWithString: L10n.generalTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let (card1, stack1) = createCardView(title: L10n.cardStartupTitle, subtitle: L10n.cardStartupSubtitle)
        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunchAtLogin)
        stack1.addArrangedSubview(launchToggle)

        askToggle.target = self
        askToggle.action = #selector(toggleAsk)
        stack1.addArrangedSubview(askToggle)
        view.addSubview(card1)

        let (card2, stack2) = createCardView(title: L10n.cardRehideTitle, subtitle: L10n.cardRehideSubtitle)
        let rehideRow = NSStackView()
        rehideRow.orientation = .horizontal
        rehideRow.spacing = 10
        rehideStepper.minValue = 0
        rehideStepper.maxValue = 10
        rehideStepper.increment = 0.5
        rehideStepper.target = self
        rehideStepper.action = #selector(changeRehide)
        rehideRow.addArrangedSubview(rehideStepper)

        rehideValue.font = NSFont.systemFont(ofSize: 12)
        rehideRow.addArrangedSubview(rehideValue)
        stack2.addArrangedSubview(rehideRow)
        view.addSubview(card2)

        let (card3, stack3) = createCardView(title: L10n.cardStylingTitle, subtitle: L10n.cardStylingSubtitle)
        stylingToggle.target = self
        stylingToggle.action = #selector(toggleStyling)
        stack3.addArrangedSubview(stylingToggle)
        view.addSubview(card3)

        let (card4, stack4) = createCardView(title: L10n.cardLanguageTitle, subtitle: L10n.cardLanguageSubtitle)
        languagePopup.removeAllItems()
        for lang in AppLanguage.allCases {
            languagePopup.addItem(withTitle: lang.displayName)
        }
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
        stack4.addArrangedSubview(languagePopup)
        view.addSubview(card4)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),

            card1.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            card1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card1.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card2.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card3.topAnchor.constraint(equalTo: card2.bottomAnchor, constant: 14),
            card3.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card3.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card4.topAnchor.constraint(equalTo: card3.bottomAnchor, constant: 14),
            card4.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card4.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card4.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    // MARK: - 页面 4：高级与诊断
    private func buildAdvancedPane() -> NSView {
        let view = NSView()

        let titleLabel = NSTextField(labelWithString: L10n.advancedTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let (card1, stack1) = createCardView(title: L10n.cardPerformanceTitle, subtitle: L10n.cardPerformanceSubtitle)
        performanceLine.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        performanceLine.textColor = .labelColor
        stack1.addArrangedSubview(performanceLine)
        view.addSubview(card1)

        let (card2, stack2) = createCardView(title: L10n.cardPrivacyTitle, subtitle: L10n.cardPrivacySubtitle)
        privacyLine.font = NSFont.systemFont(ofSize: 11)
        privacyLine.textColor = .secondaryLabelColor
        privacyLine.maximumNumberOfLines = 2
        stack2.addArrangedSubview(privacyLine)

        statusLine.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLine.textColor = .secondaryLabelColor
        statusLine.maximumNumberOfLines = 3
        stack2.addArrangedSubview(statusLine)

        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8

        let exportBtn = NSButton(title: L10n.exportDiagnosticsButton, target: self, action: #selector(exportDiagnosticsAction))
        exportBtn.bezelStyle = .rounded
        exportBtn.font = NSFont.systemFont(ofSize: 11)
        actionsRow.addArrangedSubview(exportBtn)

        let issueBtn = NSButton(title: L10n.reportIssueButton, target: self, action: #selector(reportIssueAction))
        issueBtn.bezelStyle = .rounded
        issueBtn.font = NSFont.systemFont(ofSize: 11)
        actionsRow.addArrangedSubview(issueBtn)

        let privacyBtn = NSButton(title: L10n.viewPrivacyPolicyButton, target: self, action: #selector(viewPrivacyAction))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 11)
        actionsRow.addArrangedSubview(privacyBtn)

        let aboutBtn = NSButton(title: L10n.aboutTidyBar, target: self, action: #selector(openAboutAction))
        aboutBtn.bezelStyle = .rounded
        aboutBtn.font = NSFont.systemFont(ofSize: 11)
        actionsRow.addArrangedSubview(aboutBtn)

        stack2.addArrangedSubview(actionsRow)
        view.addSubview(card2)

        let (card3, stack3) = createCardView(title: L10n.cardRulesTitle, subtitle: L10n.cardRulesSubtitle)
        let ruleButton = NSButton(title: L10n.openRuleEditorButton, target: self, action: #selector(openRuleEditorAction))
        ruleButton.bezelStyle = .rounded
        ruleButton.font = NSFont.systemFont(ofSize: 12)
        stack3.addArrangedSubview(ruleButton)
        view.addSubview(card3)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),

            card1.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            card1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card1.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card2.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card3.topAnchor.constraint(equalTo: card2.bottomAnchor, constant: 14),
            card3.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card3.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card3.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    @objc private func openRuleEditorAction() {
        onOpenRuleEditor?()
    }

    private func createCardView(title: String, subtitle: String) -> (card: NSView, bodyStack: NSStackView) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = NSFont.systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(subtitleField)

        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 10
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bodyStack)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            subtitleField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),

            bodyStack.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 12),
            bodyStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            bodyStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            bodyStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        return (card, bodyStack)
    }

    @objc private func testDrawer() {
        controller.onToggleDrawer?()
    }

    @objc private func testSearchHUD() {
        controller.onSearchRequested?()
    }

    public func refresh() {
        overview.imageProvider = imageProvider
        overview.physicalLayoutState = controller.physicalLayoutState
        overview.reload(rows: IconOverviewBuilder.rows(from: controller))
        askToggle.state = controller.settings.askAboutNewItems ? .on : .off
        stylingToggle.state = controller.settings.stylingEnabled ? .on : .off
        rehideStepper.doubleValue = controller.settings.rehideDelay
        rehideValue.stringValue = controller.settings.rehideDelay == 0
            ? L10n.rehideNever
            : L10n.rehideSeconds(controller.settings.rehideDelay)

        // 自然手势触发与动作状态同步
        emptyBarToggle.state = controller.settings.revealTriggers.contains(.emptyBarClick) ? .on : .off
        scrollToggle.state = controller.settings.revealTriggers.contains(.scrollOrSwipe) ? .on : .off
        hoverToggle.state = controller.settings.revealTriggers.contains(.hover) ? .on : .off
        emptyBarActionPopup.selectItem(at: controller.settings.emptyBarClickAction == .toggleFold ? 0 : 1)
        scrollActionPopup.selectItem(at: controller.settings.scrollOrSwipeAction == .toggleFold ? 0 : 1)

        let langIdx = AppLanguage.allCases.firstIndex(of: controller.settings.appLanguage) ?? 0
        languagePopup.selectItem(at: langIdx)

        let state = LaunchAtLogin.state()
        launchToggle.state = state == .enabled ? .on : .off
        switch state {
        case .needsApproval:
            launchToggle.title = L10n.launchNeedsApproval
        case .unknown(let reason):
            launchToggle.title = "\(L10n.launchUnavailable)\(reason)"
        default:
            launchToggle.title = L10n.launchAtLogin
        }

        if NativeMenuBarHider.shared.isAvailable {
            dividerButton.title = L10n.reconcileButtonTitle
            dividerButton.contentTintColor = .controlAccentColor
            dividerButton.toolTip = L10n.reconcileTooltip
        } else if let arePlaced = controller.areDividersPlaced?(), arePlaced {
            dividerButton.title = L10n.retractDividers
            dividerButton.contentTintColor = .secondaryLabelColor
            dividerButton.toolTip = nil
        } else {
            dividerButton.title = "│ " + L10n.placeDividers
            dividerButton.contentTintColor = .controlAccentColor
            dividerButton.toolTip = nil
        }

        let isFolded = controller.isMenuBarFoldedQuery?() ?? false
        foldButton.title = controller.isPhysicalLayoutBusy ? L10n.arrangingMenuBar
            : controller.capability == .panelOnlyFallback ? L10n.showDrawer
            : (isFolded ? "◀ " + L10n.unfoldIcons : "▶ " + L10n.foldIcons)
        foldButton.toolTip = controller.capabilityReason
        foldButton.isEnabled = !controller.isPhysicalLayoutBusy
        dividerButton.isEnabled = !controller.isPhysicalLayoutBusy
        foldButton.contentTintColor = isFolded ? .systemGreen : .systemBlue

        let footprint = ResourceProbe.residentMemoryBytes()
        let memStr = footprint > 0 ? String(format: "%.1f MB", Double(footprint) / 1_048_576) : L10n.tr("暂不可用", "N/A")
        performanceLine.stringValue = "\(L10n.memoryLabel)\(memStr)\(L10n.memoryBudgetSuffix)"
        performanceLine.toolTip = L10n.tr("内存采用系统物理占用（phys_footprint），与性能预算和启动日志一致。", "Memory is measured via system physical footprint (phys_footprint).")
        privacyLine.stringValue = L10n.privacyNotice
        statusLine.stringValue = controller.logs.suffix(2).joined(separator: "\n")
    }

    @objc private func changeLanguage() {
        let index = languagePopup.indexOfSelectedItem
        if index >= 0 && index < AppLanguage.allCases.count {
            let selected = AppLanguage.allCases[index]
            controller.update { $0.appLanguage = selected }
            L10n.currentLanguage = selected
            window?.title = L10n.tr("TidyBar 偏好设置", "TidyBar Settings")
            for (t, btn) in sidebarButtons {
                btn.title = t.title
            }
            refresh()
        }
    }

    @objc private func exportDiagnosticsAction() {
        DiagnosticExporter.exportDiagnostics(controller: controller, presentingWindow: window)
    }

    @objc private func reportIssueAction() {
        DiagnosticExporter.openGitHubIssue()
    }

    @objc private func viewPrivacyAction() {
        DiagnosticExporter.openPrivacyPolicy()
    }

    @objc private func openAboutAction() {
        TidyBarAboutWindowController.shared.show()
    }

    @objc private func toggleEmptyBarClick() {
        controller.update {
            if emptyBarToggle.state == .on {
                $0.revealTriggers.insert(.emptyBarClick)
            } else {
                $0.revealTriggers.remove(.emptyBarClick)
            }
        }
        refresh()
    }

    @objc private func toggleScroll() {
        controller.update {
            if scrollToggle.state == .on {
                $0.revealTriggers.insert(.scrollOrSwipe)
            } else {
                $0.revealTriggers.remove(.scrollOrSwipe)
            }
        }
        refresh()
    }

    @objc private func toggleHover() {
        controller.update {
            if hoverToggle.state == .on {
                $0.revealTriggers.insert(.hover)
            } else {
                $0.revealTriggers.remove(.hover)
            }
        }
        refresh()
    }

    @objc private func changeEmptyBarAction() {
        let action: GestureAction = emptyBarActionPopup.indexOfSelectedItem == 0 ? .toggleFold : .toggleDrawer
        controller.update { $0.emptyBarClickAction = action }
    }

    @objc private func changeScrollAction() {
        let action: GestureAction = scrollActionPopup.indexOfSelectedItem == 0 ? .toggleFold : .toggleDrawer
        controller.update { $0.scrollOrSwipeAction = action }
    }

    @objc private func toggleFoldFromSettings() {
        controller.onToggleMenuBarFold?()
        refresh()
    }

    @objc private func toggleDividers() {
        if NativeMenuBarHider.shared.isAvailable {
            controller.onReconcilePartitions?()
            refresh()
            return
        }
        controller.onToggleDividers?()
        refresh()
    }

    @objc private func toggleStyling() {
        controller.update { $0.stylingEnabled = (stylingToggle.state == .on) }
        refresh()
    }

    @objc private func toggleAsk() {
        controller.update { $0.askAboutNewItems = (askToggle.state == .on) }
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        let want = launchToggle.state == .on
        switch LaunchAtLogin.setEnabled(want) {
        case .success:
            break
        case .failure(let failure):
            // 失败必须原样显示。静默回滚复选框是这类开关最讨人嫌的写法。
            launchToggle.state = want ? .off : .on
            statusLine.stringValue = "开机自启设置失败：" + failure.reason
        }
        refresh()
    }

    @objc private func changeRehide() {
        controller.update { $0.rehideDelay = rehideStepper.doubleValue }
        refresh()
    }

    public func showAgain() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 首启向导（B1）：三步、每步可跳过，全程不挡路。

public final class FirstRunWizardController: NSWindowController {
    private let controller: TidyBarController
    private let onFinish: () -> Void
    private let body = NSTextField(wrappingLabelWithString: "")
    private let authButton = NSButton(title: L10n.openAccessibilityButton, target: nil, action: nil)
    private let screenCaptureButton = NSButton(title: L10n.openScreenCaptureButton, target: nil, action: nil)
    private let nextButton = NSButton(title: L10n.buttonNext, target: nil, action: nil)
    private let skipButton = NSButton(title: L10n.buttonSkip, target: nil, action: nil)
    private var step = 1
    /// 第 2 步复用的总览：与设置页同一个视图类型、同一套行语义，不会各长一套。
    private lazy var overviewInWizard: IconOverviewView = IconOverviewView(onReassign: { _, _ in false })

    private func installOverviewInWizard() {
        if overviewInWizard.superview == nil, let root = window?.contentView {
            overviewInWizard.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(overviewInWizard)
            NSLayoutConstraint.activate([
                overviewInWizard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                overviewInWizard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                overviewInWizard.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
                overviewInWizard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -56),
            ])
            overviewInWizard.onReassign = { [weak controller] itemID, zone in
                controller?.reassignZone(itemID, to: zone) ?? false
            }
            overviewInWizard.onZoneChanged = { [weak self] in self?.showStep() }
            overviewInWizard.onRestoreAlwaysHidden = { [weak self, weak controller] in
                controller?.restoreAlwaysHiddenToHidden()
                self?.showStep()
            }
        }
        overviewInWizard.physicalLayoutState = controller.physicalLayoutState
        overviewInWizard.reload(rows: IconOverviewBuilder.rows(from: controller))
    }

    public init(controller: TidyBarController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.wizardTitle(step: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func build() {
        guard let root = window?.contentView else { return }
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = NSFont.systemFont(ofSize: 12)
        root.addSubview(body)

        authButton.translatesAutoresizingMaskIntoConstraints = false
        authButton.bezelStyle = .rounded
        authButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        authButton.target = self
        authButton.action = #selector(openAccessibilitySettings)
        root.addSubview(authButton)

        screenCaptureButton.translatesAutoresizingMaskIntoConstraints = false
        screenCaptureButton.bezelStyle = .rounded
        screenCaptureButton.font = NSFont.systemFont(ofSize: 11)
        screenCaptureButton.target = self
        screenCaptureButton.action = #selector(openScreenCaptureSettings)
        root.addSubview(screenCaptureButton)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            authButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            authButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            authButton.heightAnchor.constraint(equalToConstant: 28),

            screenCaptureButton.topAnchor.constraint(equalTo: authButton.bottomAnchor, constant: 8),
            screenCaptureButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            screenCaptureButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        nextButton.target = self
        nextButton.action = #selector(advance)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nextButton)

        skipButton.target = self
        skipButton.action = #selector(finish)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(skipButton)

        NSLayoutConstraint.activate([
            nextButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            nextButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            skipButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            skipButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -12),
            skipButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        showStep()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 只刷新当前步骤，不推进向导；异步整理结果与设置窗口同步呈现。
    public func refresh() { showStep() }

    private func showStep() {
        window?.title = L10n.wizardTitle(step: step)
        // 总览只在第 2 步出现；别的步骤收回，避免窗口里挂着一块不相关的长表
        if step != 2 { overviewInWizard.removeFromSuperview() }
        let isStep1 = (step == 1)
        authButton.isHidden = !isStep1
        screenCaptureButton.isHidden = !isStep1

        nextButton.title = (step == 3) ? L10n.buttonFinish : L10n.buttonNext
        skipButton.title = L10n.buttonSkip

        let trusted = controller.layoutEngineAllowsTakeoverDescription
        switch step {
        case 1:
            body.stringValue = "\(L10n.wizardStep1Body)\n\n"
                + L10n.tr("当前辅助功能状态：\(trusted)", "Current Accessibility Status: \(trusted)")
                + "\n" + L10n.wizardStep1ScreenCaptureNote
            if AXIsProcessTrusted() {
                authButton.title = L10n.tr("✓ 辅助功能权限已授予", "✓ Accessibility Permission Granted")
                authButton.isEnabled = false
            } else {
                authButton.title = L10n.openAccessibilityButton
                authButton.isEnabled = true
            }
        case 2:
            body.stringValue = L10n.wizardStep2BodyPrefix
                + (controller.settings.askAboutNewItems ? L10n.wizardStep2Ask : L10n.wizardStep2Auto)
                + L10n.wizardStep2BodySuffix
            installOverviewInWizard()
        default:
            body.stringValue = L10n.wizardStep3Body
        }
    }

    @objc private func advance() {
        if step < 3 { step += 1; showStep() } else { finish() }
    }

    @objc private func finish() {
        onFinish()
        window?.close()
    }
}
