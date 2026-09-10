import AppKit

/// 规则编辑器（P1-C 的完整版入口）。
///
/// 一条规则 = 名字 + 全部满足的条件 + 明确目标的动作。
public final class RuleEditorWindowController: NSWindowController {
    private let controller: TidyBarController
    private let onFinish: (DisplayRule) -> Void
    private let originalRule: DisplayRule?

    private let nameField = NSTextField()
    private let conditionBoxes: [NSButton] = RuleCondition.allCases.map {
        NSButton(checkboxWithTitle: $0.label, target: nil, action: nil)
    }
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var targetIsProfile = false
    private let enabledToggle = NSButton(checkboxWithTitle: "规则启用", target: nil, action: nil)
    private let statusLine = NSTextField(labelWithString: "")

    /// 编辑已有规则时传入；nil 表示新建。
    public init(controller: TidyBarController, editing existing: DisplayRule?, onFinish: @escaping (DisplayRule) -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        self.originalRule = existing
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 470),
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
        nameField.identifier = NSUserInterfaceItemIdentifier("rule-name")
        actionPopup.identifier = NSUserInterfaceItemIdentifier("rule-action")
        targetPopup.identifier = NSUserInterfaceItemIdentifier("rule-target")

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

        let condLabel = NSTextField(labelWithString: "以下条件全部满足时触发")
        condLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        condLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(condLabel)
        NSLayoutConstraint.activate([
            condLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            condLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])

        var anchor: NSLayoutYAxisAnchor = condLabel.bottomAnchor
        for (condition, box) in zip(RuleCondition.allCases, conditionBoxes) {
            if !condition.supportsAutomaticEvaluation {
                box.isEnabled = false
                box.title += "（自动检测暂不可用）"
            }
            box.translatesAutoresizingMaskIntoConstraints = false
            box.font = NSFont.systemFont(ofSize: 11)
            root.addSubview(box)
            NSLayoutConstraint.activate([
                box.topAnchor.constraint(equalTo: anchor, constant: 4),
                box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            ])
            anchor = box.bottomAnchor
        }

        let count = originalRule?.actions.count ?? 0
        let actionLabel = NSTextField(labelWithString: count > 1 ? "执行动作（第 1 项，共 \(count) 项）" : "执行动作")
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actionLabel)
        NSLayoutConstraint.activate([
            actionLabel.topAnchor.constraint(equalTo: anchor, constant: 14),
            actionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])
        for action in RuleAction.Kind.allCases {
            actionPopup.addItem(withTitle: action.label)
        }
        actionPopup.selectItem(at: 1)
        actionPopup.target = self
        actionPopup.action = #selector(reloadTargets)
        actionPopup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actionPopup)
        NSLayoutConstraint.activate([
            actionPopup.centerYAnchor.constraint(equalTo: actionLabel.centerYAnchor),
            actionPopup.leadingAnchor.constraint(equalTo: actionLabel.trailingAnchor, constant: 8),
        ])

        let targetLabel = NSTextField(labelWithString: "作用目标")
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        targetPopup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(targetLabel)
        root.addSubview(targetPopup)
        NSLayoutConstraint.activate([
            targetLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            targetPopup.topAnchor.constraint(equalTo: actionPopup.bottomAnchor, constant: 10),
            targetLabel.centerYAnchor.constraint(equalTo: targetPopup.centerYAnchor),
            targetPopup.leadingAnchor.constraint(equalTo: targetLabel.trailingAnchor, constant: 8),
            targetPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])
        reloadTargets()

        enabledToggle.state = .on
        enabledToggle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(enabledToggle)
        NSLayoutConstraint.activate([
            enabledToggle.topAnchor.constraint(equalTo: targetPopup.bottomAnchor, constant: 12),
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
            if box.state == .on { box.isEnabled = true }
        }
        if let action = rule.actions.first, let index = RuleAction.Kind.allCases.firstIndex(of: action.kind) {
            actionPopup.selectItem(at: index)
            reloadTargets()
            let target = action.kind == .applyProfile ? action.profileName : action.itemID.flatMap(controller.resolveItemID)
            if let index = targetPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == target }) {
                targetPopup.selectItem(at: index)
            }
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
        guard selected.allSatisfy(\.supportsAutomaticEvaluation) else {
            statusLine.stringValue = "请取消暂不可自动检测的条件"
            return
        }
        guard let target = targetPopup.selectedItem?.representedObject as? String else {
            statusLine.stringValue = "请选择要操作的图标或布局档案"
            return
        }
        let kind = RuleAction.Kind.allCases[actionPopup.indexOfSelectedItem]
        let action = kind == .applyProfile ? RuleAction.applyProfile(target) : RuleAction(kind: kind, itemID: target)

        let rule = DisplayRule(
            id: originalRule?.id ?? UUID(),
            name: name,
            conditions: selected,
            actions: [action] + (originalRule.map { Array($0.actions.dropFirst()) } ?? []),
            isEnabled: enabledToggle.state == .on,
            priority: originalRule?.priority ?? 100
        )
        onFinish(rule)
        window?.close()
    }

    @objc private func cancel() { window?.close() }

    @objc private func reloadTargets() {
        let kind = RuleAction.Kind.allCases[actionPopup.indexOfSelectedItem]
        let isProfile = kind == .applyProfile
        let previous = targetIsProfile == isProfile ? targetPopup.selectedItem?.representedObject as? String : nil
        targetIsProfile = isProfile
        targetPopup.removeAllItems()
        targetPopup.addItem(withTitle: kind == .applyProfile ? "请选择布局档案" : "请选择图标")
        if kind == .applyProfile {
            for name in controller.listProfiles() {
                targetPopup.addItem(withTitle: name)
                targetPopup.lastItem?.representedObject = name
            }
        } else {
            for item in controller.assignableItems {
                targetPopup.addItem(withTitle: item.title)
                targetPopup.lastItem?.representedObject = item.id
            }
        }
        if let previous, let index = targetPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == previous }) {
            targetPopup.selectItem(at: index)
        }
    }

    public func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
