import AppKit

/// 规则编辑器（P1-C 的完整版入口）。
///
/// 一条规则 = 名字 + 若干条件（多选一满足即可）+ 动作（把图标挪到哪个区）。
/// 刻意不给"条件组合式"（AND/OR 嵌套）：现有求值器就是"任一条件满足即触发"，
/// UI 表达出求值器没有的能力等于骗用户。
public final class RuleEditorWindowController: NSWindowController {
    private let controller: TidyBarController
    private let onFinish: (DisplayRule) -> Void

    private let nameField = NSTextField()
    private let conditionBoxes: [NSButton] = RuleCondition.allCases.map {
        NSButton(checkboxWithTitle: $0.label, target: nil, action: nil)
    }
    private let zonePopup = NSPopUpButton(title: "", target: nil, action: nil)
    private let enabledToggle = NSButton(checkboxWithTitle: "规则启用", target: nil, action: nil)
    private let statusLine = NSTextField(labelWithString: "")

    /// 编辑已有规则时传入；nil 表示新建。
    public init(controller: TidyBarController, editing existing: DisplayRule?, onFinish: @escaping (DisplayRule) -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? "新建规则" : "编辑规则"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        if let existing { fill(from: existing) }
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func build() {
        guard let root = window?.contentView else { return }

        let nameLabel = NSTextField(labelWithString: "规则名")
        nameField.placeholderString = "例如：省电模式"
        for view in [nameLabel, nameField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])

        let condLabel = NSTextField(labelWithString: "任一条件满足即触发")
        condLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        condLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(condLabel)
        NSLayoutConstraint.activate([
            condLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            condLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])

        var anchor: NSLayoutYAxisAnchor = condLabel.bottomAnchor
        for box in conditionBoxes {
            box.translatesAutoresizingMaskIntoConstraints = false
            box.font = NSFont.systemFont(ofSize: 11)
            root.addSubview(box)
            NSLayoutConstraint.activate([
                box.topAnchor.constraint(equalTo: anchor, constant: 4),
                box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            ])
            anchor = box.bottomAnchor
        }

        let actionLabel = NSTextField(labelWithString: "就把不常用图标收进")
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actionLabel)
        NSLayoutConstraint.activate([
            actionLabel.topAnchor.constraint(equalTo: anchor, constant: 14),
            actionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])
        for zone in MenuBarZone.allCases {
            zonePopup.addItem(withTitle: zone.displayLabel)
        }
        zonePopup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(zonePopup)
        NSLayoutConstraint.activate([
            zonePopup.centerYAnchor.constraint(equalTo: actionLabel.centerYAnchor),
            zonePopup.leadingAnchor.constraint(equalTo: actionLabel.trailingAnchor, constant: 8),
        ])

        enabledToggle.state = .on
        enabledToggle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(enabledToggle)
        NSLayoutConstraint.activate([
            enabledToggle.topAnchor.constraint(equalTo: actionLabel.bottomAnchor, constant: 12),
            enabledToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])

        statusLine.font = NSFont.systemFont(ofSize: 10)
        statusLine.textColor = .systemRed
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLine)
        NSLayoutConstraint.activate([
            statusLine.topAnchor.constraint(equalTo: enabledToggle.bottomAnchor, constant: 8),
            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        for (index, button) in [save, cancel].enumerated() {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .inline
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20 - CGFloat(index) * 92),
            ])
        }
    }

    private func fill(from rule: DisplayRule) {
        nameField.stringValue = rule.name
        for (condition, box) in zip(RuleCondition.allCases, conditionBoxes) {
            box.state = rule.conditions.contains(condition) ? .on : .off
        }
        if let zone = rule.actions.first?.kind.targetZone,
           let index = MenuBarZone.allCases.firstIndex(of: zone) {
            zonePopup.selectItem(at: index)
        }
        enabledToggle.state = rule.isEnabled ? .on : .off
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusLine.stringValue = "先给规则起个名字"
            return
        }
        let selected = zip(RuleCondition.allCases, conditionBoxes)
            .filter { $0.1.state == .on }
            .map(\.0)
        guard !selected.isEmpty else {
            statusLine.stringValue = "至少勾选一个条件——无条件规则等于常开，不如直接改默认分区"
            return
        }
        let zoneIndex = zonePopup.indexOfSelectedItem
        let zone = MenuBarZone.allCases.indices.contains(zoneIndex) ? MenuBarZone.allCases[zoneIndex] : .hidden

        let rule = DisplayRule(
            name: name,
            conditions: selected,
            actions: [RuleAction.forZone(zone)],
            isEnabled: enabledToggle.state == .on
        )
        onFinish(rule)
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    public func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
