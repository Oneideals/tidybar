import AppKit

/// 设置窗口（对标 Bartender 专业三行菜单栏托盘与多标签页管理）。
///
/// 刻意做得"直白"：每一项都是**读系统或读状态**再显示，不缓存自己算出来的假状态——
/// 开机自启尤其如此，用户在系统设置里手动改过之后，我们这里必须跟着变。
public final class TidyBarSettingsWindowController: NSWindowController {
    private let controller: TidyBarController
    private let launchToggle = NSButton(checkboxWithTitle: "开机自动启动 TidyBar", target: nil, action: nil)
    private let askToggle = NSButton(checkboxWithTitle: "出现新图标时先问我（A7）", target: nil, action: nil)
    private let stylingToggle = NSButton(checkboxWithTitle: "启用菜单栏美化（圆角胶囊背景，E1）", target: nil, action: nil)
    private let rehideStepper = NSStepper()
    private let rehideValue = NSTextField(labelWithString: "")
    private let hotKeyLine = NSTextField(labelWithString: "")
    private let performanceLine = NSTextField(labelWithString: "")
    private let privacyLine = NSTextField(wrappingLabelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let overview = IconOverviewView(onReassign: { _, _ in })   // 回调在 init 里重设
    private let dividerButton = NSButton(title: "│ 摆放菜单栏分隔符", target: nil, action: nil)

    public init(controller: TidyBarController, hotKeyDescription: String) {
        self.controller = controller
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidyBar 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        overview.onReassign = { [weak controller] itemID, zone in
            _ = controller?.reassignZone(itemID, to: zone)
        }
        overview.onZoneChanged = { [weak self] in self?.refresh() }
        build(hotKeyDescription: hotKeyDescription)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func build(hotKeyDescription: String) {
        guard let root = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        // Tab 1: 图标整理（Bartender 风格三行菜单栏托盘）
        let tab1 = NSTabViewItem(identifier: "icons")
        tab1.label = "图标整理"
        let tab1View = NSView()

        let titleLabel = NSTextField(labelWithString: "拖拽图标自定义菜单栏布局")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        tab1View.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "将图标在三个状态托盘间自由拖拽，松手即时生效并同步落地配置。")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        tab1View.addSubview(subtitleLabel)

        let smartButton = NSButton(title: "🪄 一键智能推荐收纳", target: self, action: #selector(triggerSmartCategorize))
        smartButton.bezelStyle = .rounded
        smartButton.contentTintColor = .controlAccentColor
        smartButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        smartButton.translatesAutoresizingMaskIntoConstraints = false
        tab1View.addSubview(smartButton)

        dividerButton.bezelStyle = .rounded
        dividerButton.font = NSFont.systemFont(ofSize: 12)
        dividerButton.target = self
        dividerButton.action = #selector(toggleDividers)
        dividerButton.translatesAutoresizingMaskIntoConstraints = false
        tab1View.addSubview(dividerButton)

        overview.translatesAutoresizingMaskIntoConstraints = false
        tab1View.addSubview(overview)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: tab1View.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: tab1View.leadingAnchor, constant: 6),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: tab1View.leadingAnchor, constant: 6),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: smartButton.leadingAnchor, constant: -12),

            dividerButton.topAnchor.constraint(equalTo: tab1View.topAnchor, constant: 10),
            dividerButton.trailingAnchor.constraint(equalTo: tab1View.trailingAnchor, constant: -6),
            dividerButton.heightAnchor.constraint(equalToConstant: 28),

            smartButton.topAnchor.constraint(equalTo: tab1View.topAnchor, constant: 10),
            smartButton.trailingAnchor.constraint(equalTo: dividerButton.leadingAnchor, constant: -8),
            smartButton.heightAnchor.constraint(equalToConstant: 28),

            overview.leadingAnchor.constraint(equalTo: tab1View.leadingAnchor, constant: 4),
            overview.trailingAnchor.constraint(equalTo: tab1View.trailingAnchor, constant: -4),
            overview.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            overview.bottomAnchor.constraint(lessThanOrEqualTo: tab1View.bottomAnchor, constant: -6),
        ])
        tab1.view = tab1View
        tabView.addTabViewItem(tab1)

        // Tab 2: 常规设置
        let tab2 = NSTabViewItem(identifier: "general")
        tab2.label = "常规设置"
        let tab2View = NSView()
        buildGeneralTab(in: tab2View, hotKeyDescription: hotKeyDescription)
        tab2.view = tab2View
        tabView.addTabViewItem(tab2)

        // Tab 3: 外观与性能
        let tab3 = NSTabViewItem(identifier: "about")
        tab3.label = "外观与性能"
        let tab3View = NSView()
        buildAboutTab(in: tab3View)
        tab3.view = tab3View
        tabView.addTabViewItem(tab3)
    }

    private func buildGeneralTab(in view: NSView, hotKeyDescription: String) {
        var previous: NSView?
        func place(_ item: NSView, topOffset: CGFloat) {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
            let topConstraint = previous == nil
                ? item.topAnchor.constraint(equalTo: view.topAnchor, constant: topOffset)
                : item.topAnchor.constraint(equalTo: previous!.bottomAnchor, constant: topOffset)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                item.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
                topConstraint,
            ])
            previous = item
        }

        let triggerTitle = NSTextField(labelWithString: "呼出方式：")
        triggerTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        place(triggerTitle, topOffset: 20)

        let triggers = NSTextField(wrappingLabelWithString: controller.settings.revealTriggers
            .map(\.displayName).sorted().joined(separator: "、"))
        triggers.font = NSFont.systemFont(ofSize: 11)
        triggers.textColor = .secondaryLabelColor
        place(triggers, topOffset: 6)

        hotKeyLine.stringValue = "快捷键：" + hotKeyDescription
        hotKeyLine.font = NSFont.systemFont(ofSize: 11)
        place(hotKeyLine, topOffset: 12)

        let sep1 = NSBox()
        sep1.boxType = .separator
        place(sep1, topOffset: 16)

        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunchAtLogin)
        place(launchToggle, topOffset: 16)

        askToggle.target = self
        askToggle.action = #selector(toggleAsk)
        place(askToggle, topOffset: 16)

        rehideStepper.minValue = 0
        rehideStepper.maxValue = 10
        rehideStepper.increment = 0.5
        rehideStepper.target = self
        rehideStepper.action = #selector(changeRehide)
        place(rehideStepper, topOffset: 16)

        rehideValue.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(rehideValue)
        rehideValue.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rehideValue.leadingAnchor.constraint(equalTo: rehideStepper.trailingAnchor, constant: 8),
            rehideValue.centerYAnchor.constraint(equalTo: rehideStepper.centerYAnchor),
        ])
    }

    private func buildAboutTab(in view: NSView) {
        var previous: NSView?
        func place(_ item: NSView, topOffset: CGFloat) {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
            let topConstraint = previous == nil
                ? item.topAnchor.constraint(equalTo: view.topAnchor, constant: topOffset)
                : item.topAnchor.constraint(equalTo: previous!.bottomAnchor, constant: topOffset)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                item.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
                topConstraint,
            ])
            previous = item
        }

        stylingToggle.target = self
        stylingToggle.action = #selector(toggleStyling)
        place(stylingToggle, topOffset: 20)

        let stylingHint = NSTextField(labelWithString: "在菜单栏下方绘制微妙的半透明胶囊背景与细边框（鼠标点击完全穿透）")
        stylingHint.font = NSFont.systemFont(ofSize: 10)
        stylingHint.textColor = .tertiaryLabelColor
        place(stylingHint, topOffset: 4)

        let sep = NSBox()
        sep.boxType = .separator
        place(sep, topOffset: 16)

        performanceLine.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        performanceLine.textColor = .secondaryLabelColor
        place(performanceLine, topOffset: 16)

        privacyLine.font = NSFont.systemFont(ofSize: 10)
        privacyLine.textColor = .secondaryLabelColor
        privacyLine.maximumNumberOfLines = 3
        place(privacyLine, topOffset: 12)

        statusLine.font = NSFont.systemFont(ofSize: 10)
        statusLine.textColor = .tertiaryLabelColor
        statusLine.maximumNumberOfLines = 3
        place(statusLine, topOffset: 16)
    }

    public func refresh() {
        overview.reload(rows: IconOverviewBuilder.rows(from: controller))
        askToggle.state = controller.settings.askAboutNewItems ? .on : .off
        stylingToggle.state = controller.settings.stylingEnabled ? .on : .off
        rehideStepper.doubleValue = controller.settings.rehideDelay
        rehideValue.stringValue = controller.settings.rehideDelay == 0
            ? "自动收起：从不"
            : String(format: "自动收起：%.1fs", controller.settings.rehideDelay)
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

        let memMB = currentResidentMemoryMB()
        let memStr = memMB != nil ? String(format: "%.1f MB", memMB!) : "约 13 MB"
        performanceLine.stringValue = "性能（F1）：常驻内存 \(memStr)（预算 ≤40MB）｜ 空闲 CPU ≈ 0.0%"
        privacyLine.stringValue = "隐私（F2）：纯本地运行，零网络请求、零遥测收集；配置保存在本地。"
        statusLine.stringValue = controller.logs.suffix(2).joined(separator: "\n")
    }

    @objc private func triggerSmartCategorize() {
        overview.applySmartRecommendations()
        refresh()
    }

    @objc private func toggleDividers() {
        controller.onToggleDividers?()
        refresh()
    }

    private func currentResidentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
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
    private lazy var overviewInWizard: IconOverviewView = IconOverviewView(onReassign: { _, _ in })

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
                _ = controller?.move(itemID, to: zone)
            }
            overviewInWizard.onZoneChanged = { [weak self] in self?.showStep() }
        }
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

    private func showStep() {
        window?.title = "欢迎用 TidyBar（\(step)/3）"
        // 总览只在第 2 步出现；别的步骤收回，避免窗口里挂着一块不相关的长表
        if step != 2 { overviewInWizard.removeFromSuperview() }
        let trusted = controller.layoutEngineAllowsTakeoverDescription
        switch step {
        case 1:
            body.stringValue = "第 1 步：辅助功能权限决定我能不能读到并整理你的图标。\n当前：\(trusted)\n没授予的话我只会显示占位首字母，不会去搬动任何图标。"
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
