import AppKit

/// 图标搜索面板（报告 A8）：键入名称 → 定位 → 激活。
/// 支持键盘 ↑/↓ 移动选中项、↵ 回车激活、⎋ Esc 退出。
public final class TidyBarSearchPanel: NSPanel {
    public init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 44),
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

/// 搜索面板的装配与状态。查询与排序交给 `TidyBarController.search`（纯逻辑，已有单测），
/// 这里只负责把结果摆出来、把激活传回去。
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

public final class TidyBarSearchUI: NSObject, NSTextFieldDelegate {
    public let panel = TidyBarSearchPanel()
    private let field = NSTextField()
    private let stack = NSStackView()
    private var rows: [ManagedItem] = []
    private var heightConstraint: NSLayoutConstraint!

    /// 查询 → 结果。由装配层接到控制器上。
    public var queryHandler: (String) -> [ManagedItem] = { _ in [] }
    /// 激活某一项。返回的结果用于决定要不要给出"点不动"的提示。
    public var activateHandler: (ManagedItem) -> ActivationOutcome = { _ in .actionUnsupported }
    public var onDismiss: (() -> Void)?

    private let maxResults: Int

    public init(maxResults: Int = 8) {
        self.maxResults = maxResults
        super.init()

        field.placeholderString = "搜索菜单栏图标…"
        field.font = NSFont.systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submit)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 10
        root.addSubview(field)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        panel.contentView = root
        panel.initialFirstResponder = field
        heightConstraint = root.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        heightConstraint.isActive = true
    }

    /// 当前结果行数。给真机自检用——不看内部视图树也能断言"确实渲染了几条"。
    public var resultRowCount: Int { stack.arrangedSubviews.count }

    /// 在指定锚点上方呼出面板（贴着菜单栏下缘）。
    public func present(anchorX: CGFloat, screenHeight: CGFloat) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 340, height: 44)
        let width = max(340, size.width)
        let height = max(44, min(size.height, 360))
        let x = max(8, min(anchorX - width / 2, (NSScreen.main?.frame.maxX ?? width) - width - 8))
        panel.setFrame(CGRect(x: x, y: screenHeight - height - 6, width: width, height: height), display: true)
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
    /// 不用 NSTableView 的 keyDown 转发是因为这里只有几行结果，
    /// 而局部监视器能吃到"焦点在输入框里"时的方向键——那正是搜索时唯一有意义的按键。
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

    /// 抢键盘焦点。
    ///
    /// 真 app 自检复现过：activate 是异步的，同一帧里 `makeFirstResponder` 会静默失败，
    /// 结果面板看得见但敲不进去（`输入框取得焦点=no`）。所以在窗口拿到 key 之后有限次重试，
    /// 每次退让一点时间；上限到了就放弃——不靠 sleep 死等，也不假装成功。
    private func claimKeyboard(attempt: Int = 0) {
        if panel.makeFirstResponder(field) { return }
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) { [weak self] in
            self?.claimKeyboard(attempt: attempt + 1)
        }
    }

    private var window: NSWindow? { panel }

    public func controlTextDidChange(_ notification: Notification) {
        selection = 0        // 结果集换了，选中项必须回到第一条，否则回车会激活上一次选中的那一项
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

    /// 结果行：标题 + 归属 + 当前分区。三项都要，因为 88% 图标没有可读标题，
    /// 只显示 title 会看到一排"第 2 个"，分不清是谁。
    private func refresh() {
        rows = Array(queryHandler(field.stringValue).prefix(maxResults))
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if field.stringValue.isEmpty {
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
            let text = "\(item.title)　·　\(zone)"
            let row = NSButton(title: index == 0 ? text + "　↵" : text, target: self, action: #selector(rowClicked(_:)))
            row.isBordered = false
            row.bezelStyle = .shadowlessSquare
            row.font = NSFont.systemFont(ofSize: 12)
            row.alignment = .left
            row.image = AppIconResolver.resolve(for: item)
            row.imagePosition = .imageLeft
            row.imageScaling = .scaleProportionallyUpOrDown
            row.identifier = NSUserInterfaceItemIdentifier(item.id)
            if index == selection {
                row.contentTintColor = .controlAccentColor
            }

            stack.addItem(view: row)
        }
    }

    private func labelRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 分区标签由装配层注入，避免这里再依赖布局对象
    public var zoneLabel: (String) -> String = { _ in "" }

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

    /// 键盘移动选中项。A8 验收要"键入名称定位并激活"，只支持鼠标点选等于把搜索结果
    /// 变成一块必须用鼠标伺候的列表；越界时夹到端点而不是回绕，回绕在 8 条结果里
    /// 会让人按一次就跳到最后一条，很难看也很难解释。
    public func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = SearchSelection.clamped(current: selection, delta: delta, count: rows.count)
        refresh()
    }

    private func finish(with item: ManagedItem) {
        let outcome = activateHandler(item)
        guard outcome.countsAsPressed else {
            // 搜到了却点不动：在面板里就地说明并保持打开。
            // 不用 NSAlert——模态框会把"非激活面板"的设计整个破坏掉，还会抢走焦点。
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
