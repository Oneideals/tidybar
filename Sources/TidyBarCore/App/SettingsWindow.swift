import AppKit

/// 设置窗口（M1 缺失的一整块 UI 的最小可用版）。
///
/// 刻意做得"直白"：每一项都是**读系统或读状态**再显示，不缓存自己算出来的假状态——
/// 开机自启尤其如此，用户在系统设置里手动改过之后，我们这里必须跟着变。
public final class TidyBarSettingsWindowController: NSWindowController {
    private let controller: TidyBarController
    private let launchToggle = NSButton(checkboxWithTitle: "开机自动启动 TidyBar", target: nil, action: nil)
    private let askToggle = NSButton(checkboxWithTitle: "出现新图标时先问我（A7）", target: nil, action: nil)
    private let rehideStepper = NSStepper()
    private let rehideValue = NSTextField(labelWithString: "")
    private let hotKeyLine = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")

    public init(controller: TidyBarController, hotKeyDescription: String) {
        self.controller = controller
        let height: CGFloat = 268
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidyBar 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(hotKeyDescription: hotKeyDescription)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func build(hotKeyDescription: String) {
        guard let root = window?.contentView else { return }
        var y = 232.0
        func place(_ view: NSView, at top: CGFloat) {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                view.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
                view.topAnchor.constraint(equalTo: root.topAnchor, constant: top),
            ])
        }

        let title = NSTextField(labelWithString: "呼出方式（当前生效）")
        place(title, at: y); y -= 22
        let triggers = NSTextField(wrappingLabelWithString: controller.settings.revealTriggers
            .map(\.displayName).sorted().joined(separator: "、"))
        triggers.font = NSFont.systemFont(ofSize: 11)
        triggers.maximumNumberOfLines = 2
        place(triggers, at: y); y -= 40

        hotKeyLine.stringValue = "快捷键：" + hotKeyDescription
        hotKeyLine.font = NSFont.systemFont(ofSize: 11)
        place(hotKeyLine, at: y); y -= 26

        askToggle.target = self
        askToggle.action = #selector(toggleAsk)
        place(askToggle, at: y); y -= 26

        launchToggle.target = self
        launchToggle.action = #selector(toggleLaunchAtLogin)
        place(launchToggle, at: y); y -= 30

        rehideStepper.minValue = 0
        rehideStepper.maxValue = 10
        rehideStepper.increment = 0.5
        rehideStepper.target = self
        rehideStepper.action = #selector(changeRehide)
        place(rehideStepper, at: y)
        rehideValue.font = NSFont.systemFont(ofSize: 11)
        root.addSubview(rehideValue)
        rehideValue.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rehideValue.leadingAnchor.constraint(equalTo: rehideStepper.trailingAnchor, constant: 8),
            rehideValue.centerYAnchor.constraint(equalTo: rehideStepper.centerYAnchor),
        ])
        y -= 34

        statusLine.font = NSFont.systemFont(ofSize: 10)
        statusLine.textColor = .secondaryLabelColor
        statusLine.maximumNumberOfLines = 3
        place(statusLine, at: y)
    }

    private func refresh() {
        askToggle.state = controller.settings.askAboutNewItems ? .on : .off
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
        statusLine.stringValue = controller.logs.suffix(2).joined(separator: "\n")
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 首启向导（B1）：三步、每步可跳过，全程不挡路。
public final class FirstRunWizardController: NSWindowController {
    private let controller: TidyBarController
    private let onFinish: () -> Void
    private let body = NSTextField(wrappingLabelWithString: "")
    private var step = 1

    public init(controller: TidyBarController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
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
        let trusted = controller.layoutEngineAllowsTakeoverDescription
        switch step {
        case 1:
            body.stringValue = "第 1 步：辅助功能权限决定我能不能读到并整理你的图标。\n当前：\(trusted)\n没授予的话我只会显示占位首字母，不会去搬动任何图标。"
        case 2:
            body.stringValue = "第 2 步：☰ 菜单 →「整理图标」可以把不常用的收进隐藏区。\n默认策略是"
                + (controller.settings.askAboutNewItems ? "出现新图标时先问你" : "新图标自动收进隐藏区")
                + "；这一步也可以完全跳过，之后随时在设置里改。"
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
