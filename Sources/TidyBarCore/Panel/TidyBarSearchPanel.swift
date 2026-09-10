import AppKit

/// 图标搜索面板（对标 Ice / Spotlight 极简 HUD）：键入名称 → 定位 → 激活。
/// 支持键盘 ↑/↓ 移动选中项、↵ 回车激活、⎋ Esc 退出。
public final class TidyBarSearchPanel: NSPanel {
    public init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isExcludedFromWindowsMenu = true
    }

    // 搜索框必须能接键盘输入，否则整个面板只是装饰
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

/// 搜索结果选中项钳位。
///
/// 越界时夹到端点而不是回绕：回绕会让"在第一条上按一下 ↑"直接跳到最后一条，
/// 在 8 条结果里几乎必然导致回车激活错的那一项。
public enum SearchSelection {
    public static func clamped(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let shifted = (current < 0 ? 0 : current) + delta
        return max(0, min(count - 1, shifted))
    }
}

/// 搜索面板的高质感装配与状态驱动。
public final class TidyBarSearchUI: NSObject, NSTextFieldDelegate {
    public let panel = TidyBarSearchPanel()
    private let container = NSVisualEffectView()
    private let field = NSTextField()
    private let searchIconView = NSImageView()
    private let escHintLabel = NSTextField(labelWithString: "ESC 退出")
    private let divider = NSBox()
    private let stack = NSStackView()
    private var rows: [ManagedItem] = []
    private var heightConstraint: NSLayoutConstraint!

    /// 查询 → 结果。由装配层接到控制器上。
    public var queryHandler: (String) -> [ManagedItem] = { _ in [] }
    /// 激活某一项。返回的结果用于决定要不要给出"点不动"的提示。
    public var activateHandler: (ManagedItem) -> ActivationOutcome = { _ in .actionUnsupported }
    public var onDismiss: (() -> Void)?
    public var zoneLabel: (String) -> String = { _ in "" }

    private let maxResults: Int

    public init(maxResults: Int = 8) {
        self.maxResults = maxResults
        super.init()
        setupUI()
    }

    private func setupUI() {
        container.wantsLayer = true
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        searchIconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
        searchIconView.contentTintColor = .secondaryLabelColor
        searchIconView.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "搜索菜单栏图标或应用…"
        field.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submit)

        escHintLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        escHintLabel.textColor = .tertiaryLabelColor
        escHintLabel.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchIconView)
        container.addSubview(field)
        container.addSubview(escHintLabel)
        container.addSubview(divider)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            searchIconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchIconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            searchIconView.widthAnchor.constraint(equalToConstant: 18),
            searchIconView.heightAnchor.constraint(equalToConstant: 18),

            escHintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            escHintLabel.centerYAnchor.constraint(equalTo: searchIconView.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: escHintLabel.leadingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: searchIconView.centerYAnchor),

            divider.topAnchor.constraint(equalTo: searchIconView.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            divider.heightAnchor.constraint(equalToConstant: 1),

            stack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        panel.contentView = container
        panel.initialFirstResponder = field
        heightConstraint = container.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        heightConstraint.isActive = true
    }

    /// 当前结果行数。给真机自检用——不看内部视图树也能断言"确实渲染了几条"。
    public var resultRowCount: Int { stack.arrangedSubviews.count }

    /// 居中呼出 Spotlight HUD（屏幕水平中央偏上 28% 黄金视线）。
    public func presentCentered(on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 460
        let height: CGFloat = 52
        let x = screenFrame.midX - (width / 2)
        let y = screenFrame.maxY - (screenFrame.height * 0.28) - height
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        openPanel()
    }

    /// 在指定锚点上方呼出面板（贴着菜单栏下缘）。兼容已有代码与自检脚本。
    public func present(anchorX: CGFloat, screenHeight: CGFloat) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 460, height: 50)
        let width = max(460, size.width)
        let height = max(50, min(size.height, 420))
        let screenMaxX = NSScreen.main?.frame.maxX ?? width
        let x = max(12, min(anchorX - width / 2, screenMaxX - width - 12))
        panel.setFrame(CGRect(x: x, y: screenHeight - height - 8, width: width, height: height), display: true)
        openPanel()
    }

    private func openPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        field.stringValue = ""
        refresh()
        installKeyMonitor()
        claimKeyboard()
    }

    public func dismiss() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        keyMonitor = nil
        panel.orderOut(nil)
        onDismiss?()
    }

    /// 键盘导航用局部监视器接：↑↓ 移动选中、回车激活、Esc 关闭。
    private var keyMonitor: Any?

    private func installKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 126: self.moveSelection(-1); return nil      // ↑
            case 125: self.moveSelection(1); return nil       // ↓
            case 36, 76: self.submit(); return nil            // 回车 / 小键盘回车
            case 53: self.dismiss(); return nil               // Esc
            default: return event
            }
        }
    }

    /// 抢键盘焦点，带退让重试
    private func claimKeyboard(attempt: Int = 0) {
        if panel.makeFirstResponder(field) { return }
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) { [weak self] in
            self?.claimKeyboard(attempt: attempt + 1)
        }
    }

    public func controlTextDidChange(_ notification: Notification) {
        selection = 0
        refresh()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(-1)
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(1)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    /// 当前选中项下标。键盘 ↑/↓ 改它，回车取它。
    public private(set) var selection: Int = 0

    /// 渲染结果列表项：带应用图标、分区胶囊与选中高亮
    private func refresh() {
        rows = Array(queryHandler(field.stringValue).prefix(maxResults))
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasQuery = !field.stringValue.isEmpty
        divider.isHidden = !hasQuery
        if !hasQuery {
            stack.isHidden = true
            return
        }
        stack.isHidden = false
        if rows.isEmpty {
            stack.addItem(view: labelRow("没有匹配的图标"))
            return
        }
        for (index, item) in rows.enumerated() {
            let zone = zoneLabel(item.id)
            let isSelected = (index == selection)
            let row = createRowView(for: item, zone: zone, isSelected: isSelected, index: index)
            stack.addItem(view: row)
        }
    }

    private func createRowView(for item: ManagedItem, zone: String, isSelected: Bool, index: Int) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(rowClicked(_:)))
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(item.id)
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true

        if isSelected {
            button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else {
            button.layer?.backgroundColor = NSColor.clear.cgColor
        }

        let icon = NSImageView()
        icon.image = AppIconResolver.resolve(for: item)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .medium)
        titleLabel.textColor = isSelected ? .controlAccentColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSTextField(labelWithString: " " + zone + " ")
        badge.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        badge.textColor = .secondaryLabelColor
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let actionHint = NSTextField(labelWithString: isSelected ? "↵ 激活" : "")
        actionHint.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        actionHint.textColor = .controlAccentColor
        actionHint.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(icon)
        button.addSubview(titleLabel)
        button.addSubview(badge)
        button.addSubview(actionHint)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(equalTo: actionHint.leadingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),

            actionHint.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
            actionHint.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        return button
    }

    private func labelRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 32).isActive = true
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let item = rows.first(where: { $0.id == id }) else { return }
        finish(with: item)
    }

    @objc private func submit() {
        guard rows.indices.contains(selection) else {
            guard let first = rows.first else { return }
            finish(with: first)
            return
        }
        finish(with: rows[selection])
    }

    public func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = SearchSelection.clamped(current: selection, delta: delta, count: rows.count)
        refresh()
    }

    private func finish(with item: ManagedItem) {
        let outcome = activateHandler(item)
        guard outcome.countsAsPressed else {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            stack.isHidden = false
            stack.addItem(view: labelRow("无法激活「" + item.title + "」：" + outcome.userReadable))
            return
        }
        dismiss()
    }
}

private extension NSStackView {
    func addItem(view: NSView) {
        addView(view, in: .leading)
    }
}
