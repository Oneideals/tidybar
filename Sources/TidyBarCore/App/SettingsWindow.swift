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
            case .layout: return "菜单栏布局"
            case .triggers: return "触发手势"
            case .general: return "常规设置"
            case .advanced: return "高级与诊断"
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
    private let launchToggle = NSButton(checkboxWithTitle: "开机自动启动 TidyBar", target: nil, action: nil)
    private let askToggle = NSButton(checkboxWithTitle: "出现新图标时先问我（A7）", target: nil, action: nil)
    private let stylingToggle = NSButton(checkboxWithTitle: "启用菜单栏美化（圆角胶囊背景，E1）", target: nil, action: nil)
    private let rehideStepper = NSStepper()
    private let rehideValue = NSTextField(labelWithString: "")
    private let hotKeyLine = NSTextField(labelWithString: "")
    private let performanceLine = NSTextField(labelWithString: "")
    private let privacyLine = NSTextField(wrappingLabelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let overview = IconOverviewView(onReassign: { _, _ in false })
    private let dividerButton = NSButton(title: "│ 摆放菜单栏分隔符", target: nil, action: nil)
    private let foldButton = NSButton(title: "▶ 原地折叠菜单栏", target: nil, action: nil)
    private let emptyBarToggle = NSButton(checkboxWithTitle: "点击菜单栏空白处触发", target: nil, action: nil)
    private let scrollToggle = NSButton(checkboxWithTitle: "在菜单栏上双指滚轮/横滑触发", target: nil, action: nil)
    private let hoverToggle = NSButton(checkboxWithTitle: "光标在菜单栏空白处悬停触发", target: nil, action: nil)
    private let emptyBarActionPopup = NSPopUpButton()
    private let scrollActionPopup = NSPopUpButton()

    // 侧边栏与内容容器
    private let sidebarContainer = NSVisualEffectView()
    private let contentContainer = NSView()
    private var sidebarButtons: [Tab: NSButton] = [:]
    private var tabViews: [Tab: NSView] = [:]

    /// 外部提供的截图缓存查找器，确保设置面板图标与菜单栏/抽屉风格一致。
    public var imageProvider: ((ManagedItem) -> CGImage?)?

    public init(controller: TidyBarController, hotKeyDescription: String) {
        self.controller = controller
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

        hotKeyLine.stringValue = "• 呼出抽屉快捷键：" + hotKeyDescription
        hotKeyLine.font = NSFont.systemFont(ofSize: 12)
        stack2.addArrangedSubview(hotKeyLine)

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

        let titleLabel = NSTextField(labelWithString: "常规与行为偏好")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let (card1, stack1) = createCardView(title: "系统启动与图标策略", subtitle: "管理开机行为以及新出现的未收纳图标。")
        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunchAtLogin)
        stack1.addArrangedSubview(launchToggle)

        askToggle.target = self
        askToggle.action = #selector(toggleAsk)
        stack1.addArrangedSubview(askToggle)
        view.addSubview(card1)

        let (card2, stack2) = createCardView(title: "收纳抽屉自动隐藏", subtitle: "设置鼠标离开抽屉后自动隐藏的延时时间。")
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

        let (card3, stack3) = createCardView(title: "外观美化（可选）", subtitle: "在菜单栏下方绘制微妙的半透明胶囊背景（鼠标点击穿透）。")
        stylingToggle.target = self
        stylingToggle.action = #selector(toggleStyling)
        stack3.addArrangedSubview(stylingToggle)
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

    // MARK: - 页面 4：高级与诊断
    private func buildAdvancedPane() -> NSView {
        let view = NSView()

        let titleLabel = NSTextField(labelWithString: "系统高级与安全诊断")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let (card1, stack1) = createCardView(title: "常驻性能指标（守门测试）", subtitle: "以系统真实物理驻留（phys_footprint）为准，严守预算。")
        performanceLine.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        performanceLine.textColor = .labelColor
        stack1.addArrangedSubview(performanceLine)
        view.addSubview(card1)

        let (card2, stack2) = createCardView(title: "本地隐私与日志", subtitle: "零网络连接、零遥测收集；WAL 预写日志保障异常恢复。")
        privacyLine.font = NSFont.systemFont(ofSize: 11)
        privacyLine.textColor = .secondaryLabelColor
        privacyLine.maximumNumberOfLines = 2
        stack2.addArrangedSubview(privacyLine)

        statusLine.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLine.textColor = .secondaryLabelColor
        statusLine.maximumNumberOfLines = 3
        stack2.addArrangedSubview(statusLine)
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
            ? "自动收起：从不"
            : String(format: "自动收起：%.1fs", controller.settings.rehideDelay)

        // 自然手势触发与动作状态同步
        emptyBarToggle.state = controller.settings.revealTriggers.contains(.emptyBarClick) ? .on : .off
        scrollToggle.state = controller.settings.revealTriggers.contains(.scrollOrSwipe) ? .on : .off
        hoverToggle.state = controller.settings.revealTriggers.contains(.hover) ? .on : .off
        emptyBarActionPopup.selectItem(at: controller.settings.emptyBarClickAction == .toggleFold ? 0 : 1)
        scrollActionPopup.selectItem(at: controller.settings.scrollOrSwipeAction == .toggleFold ? 0 : 1)

        let state = LaunchAtLogin.state()
        launchToggle.state = state == .enabled ? .on : .off
        switch state {
        case .needsApproval:
            launchToggle.title = "开机自动启动：需在系统设置里批准"
        case .unknown(let reason):
            launchToggle.title = "开机自动启动不可用：\(reason)"
        default:
            launchToggle.title = "开机自动启动 TidyBar"
        }

        if let arePlaced = controller.areDividersPlaced?(), arePlaced {
            dividerButton.title = "收起菜单栏分隔符"
            dividerButton.contentTintColor = .secondaryLabelColor
        } else {
            dividerButton.title = "│ 摆放菜单栏分隔符"
            dividerButton.contentTintColor = .controlAccentColor
        }

        let isFolded = controller.isMenuBarFoldedQuery?() ?? false
        foldButton.title = controller.isPhysicalLayoutBusy ? "正在整理菜单栏…"
            : controller.capability == .panelOnlyFallback ? "打开收纳抽屉"
            : (isFolded ? "◀ 展开菜单栏" : "▶ 原地折叠菜单栏")
        foldButton.toolTip = controller.capabilityReason
        foldButton.isEnabled = !controller.isPhysicalLayoutBusy
        dividerButton.isEnabled = !controller.isPhysicalLayoutBusy
        foldButton.contentTintColor = isFolded ? .systemGreen : .systemBlue

        let footprint = ResourceProbe.residentMemoryBytes()
        let memStr = footprint > 0 ? String(format: "%.1f MB", Double(footprint) / 1_048_576) : "暂不可用"
        performanceLine.stringValue = "内存占用：\(memStr)（预算 ≤40 MB）｜ CPU：未采样"
        performanceLine.toolTip = "内存采用系统物理占用（phys_footprint），与性能预算和启动日志一致。"
        privacyLine.stringValue = "隐私（F2）：纯本地运行，零网络请求、零遥测收集；配置保存在本地。"
        statusLine.stringValue = controller.logs.suffix(2).joined(separator: "\n")
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
        }
        overviewInWizard.physicalLayoutState = controller.physicalLayoutState
        overviewInWizard.reload(rows: IconOverviewBuilder.rows(from: controller))
    }

    public init(controller: TidyBarController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎用 TidyBar（1/3）"
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
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])

        let next = NSButton(title: "下一步", target: self, action: #selector(advance))
        let skip = NSButton(title: "跳过", target: self, action: #selector(finish))
        for (index, button) in [next, skip].enumerated() {
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20 - CGFloat(index) * 96),
            ])
        }
        showStep()
    }

    /// 只刷新当前步骤，不推进向导；异步整理结果与设置窗口同步呈现。
    public func refresh() { showStep() }

    private func showStep() {
        window?.title = "欢迎用 TidyBar（\(step)/3）"
        // 总览只在第 2 步出现；别的步骤收回，避免窗口里挂着一块不相关的长表
        if step != 2 { overviewInWizard.removeFromSuperview() }
        let trusted = controller.layoutEngineAllowsTakeoverDescription
        switch step {
        case 1:
            body.stringValue = "第 1 步：辅助功能权限用于读取和整理菜单栏图标。\n当前：\(trusted)\n在系统设置中授权后，会自动更新可用能力。"
        case 2:
            body.stringValue = "第 2 步：这张表就是全景——每个图标现在在哪个区一目了然。\n点右侧按钮即可调整；默认策略是"
                + (controller.settings.askAboutNewItems ? "出现新图标时先问你" : "新图标自动收进隐藏区")
                + "。也可以完全跳过，之后在设置里改。"
            installOverviewInWizard()
        default:
            body.stringValue = "第 3 步：呼出隐藏区——点 ☰、点菜单栏分隔符"
                + (controller.settings.revealTriggers.contains(.hotkey) ? "，或按 ⌥Space。" : "。")
                + "\n点「完成」就开始用。"
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
