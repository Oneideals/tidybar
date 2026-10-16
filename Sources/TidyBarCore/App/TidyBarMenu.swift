import AppKit

/// 用菜单完成分区分配与首启引导。
///
/// 为什么先做菜单而不是面板内拖拽：跨区拖拽依赖 ⌘ 拖拽闸门（`isConfirmedSupportedOS` 目前 false），
/// 而"把某个图标收进隐藏区"这个动作本身只是布局意图——菜单能立刻把它交付出去，
/// 等闸门开放时同一套意图直接换成拖拽落点，不必重做。
extension TidyBarController {
    /// 分区名，供 UI 与诊断共用一份，不在两处各写一遍
    public static func zoneLabel(_ zone: MenuBarZone) -> String {
        switch zone {
        case .visible: return L10n.zoneVisible
        case .hidden: return L10n.zoneHidden
        case .alwaysHidden: return L10n.zoneAlwaysHidden
        }
    }
}

/// ☰ 菜单里挂的两块内容：分区分配 + 首启引导。构造与状态无关，纯装配，便于替换。
enum TidyBarMenuBuilder {
    static func zoneAssignment(
        controller: TidyBarController,
        target: AnyObject,
        assignSelector: Selector,
        perGroupLimit: Int = 12
    ) -> NSMenuItem {
        let root = NSMenuItem(title: L10n.organizeIcons, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.organizeIcons)
        submenu.autoenablesItems = false

        let items = controller.assignableItems
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: L10n.noIconsFound, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            root.submenu = submenu
            return root
        }

        let grouped = Dictionary(grouping: items) { controller.layoutEngine.layout.zone(of: $0.id) ?? .visible }
        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let members = (grouped[zone] ?? []).sorted { $0.title < $1.title }
            let header = NSMenuItem(title: "\(TidyBarController.zoneLabel(zone)) · \(members.count)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for item in members.prefix(perGroupLimit) {
                for targetZone in [MenuBarZone.visible, .hidden, .alwaysHidden] where targetZone != zone {
                    let entry = NSMenuItem(
                        title: "　\(item.title) → \(TidyBarController.zoneLabel(targetZone))",
                        action: assignSelector,
                        keyEquivalent: ""
                    )
                    entry.target = target
                    entry.representedObject = ZoneAssignmentRequest(itemID: item.id, zone: targetZone)
                    submenu.addItem(entry)
                }
            }
            if members.count > perGroupLimit {
                let more = NSMenuItem(title: "　…另有 \(members.count - perGroupLimit) 项未列出", action: nil, keyEquivalent: "")
                more.isEnabled = false
                submenu.addItem(more)
            }
        }
        submenu.addItem(.separator())
        let note = NSMenuItem(
            title: "　当前：\(controller.capability.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        submenu.addItem(note)
        root.submenu = submenu
        return root
    }

    /// 新图标问答（报告 A7「先问我」）。列在菜单里而不是弹窗：
    /// 弹窗会在用户正在做别的事时抢焦点，而这件事并不紧急。
    static func newItemQuestions(
        controller: TidyBarController,
        target: AnyObject,
        answerSelector: Selector,
        limit: Int = 6
    ) -> NSMenuItem {
        let root = NSMenuItem(title: "\(L10n.pendingNewIcons) (\(controller.pendingNewItems.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.pendingNewIcons)
        submenu.autoenablesItems = false
        for item in controller.pendingNewItems.prefix(limit) {
            for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
                let entry = NSMenuItem(
                    title: "\(item.title) → \(TidyBarController.zoneLabel(zone))",
                    action: answerSelector,
                    keyEquivalent: ""
                )
                entry.target = target
                entry.representedObject = ZoneAssignmentRequest(itemID: item.id, zone: zone)
                submenu.addItem(entry)
            }
        }
        if controller.pendingNewItems.count > limit {
            let more = NSMenuItem(title: "…另有 \(controller.pendingNewItems.count - limit) 项", action: nil, keyEquivalent: "")
            more.isEnabled = false
            submenu.addItem(more)
        }
        root.submenu = submenu
        return root
    }

    /// 首启引导（报告 B1）。每步都能跳过，绝不把人堵在向导里。
    static func firstRunGuide(
        accessibilityGranted: Bool,
        target: AnyObject,
        openSettingsSelector: Selector,
        doneSelector: Selector,
        skipSelector: Selector
    ) -> NSMenuItem {
        let root = NSMenuItem(title: L10n.tr("首次设置", "Getting Started"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.tr("首次设置", "Getting Started"))
        submenu.autoenablesItems = false

        let step1 = NSMenuItem(
            title: "1. " + (accessibilityGranted ? L10n.tr("辅助功能权限：已授予 ✓", "Accessibility: Granted ✓") : L10n.tr("辅助功能权限：未授予", "Accessibility: Not Granted")),
            action: accessibilityGranted ? nil : openSettingsSelector,
            keyEquivalent: ""
        )
        step1.target = accessibilityGranted ? nil : target
        submenu.addItem(step1)

        let step2 = NSMenuItem(title: "2. " + L10n.tr("在「整理图标」里把不常用的收进隐藏区", "Move rarely used items to Hidden in Organize Icons"), action: nil, keyEquivalent: "")
        step2.isEnabled = false
        submenu.addItem(step2)

        let step3 = NSMenuItem(title: "3. " + L10n.tr("试一下呼出：点 ☰ 或菜单栏分隔符", "Try revealing: Click ☰ or the divider"), action: nil, keyEquivalent: "")
        step3.isEnabled = false
        submenu.addItem(step3)

        submenu.addItem(.separator())
        let finish = NSMenuItem(title: L10n.buttonFinish, action: doneSelector, keyEquivalent: "")
        finish.target = target
        submenu.addItem(finish)
        let skip = NSMenuItem(title: L10n.buttonSkip, action: skipSelector, keyEquivalent: "")
        skip.target = target
        submenu.addItem(skip)
        root.submenu = submenu
        return root
    }

    static func profilesMenu(
        controller: TidyBarController,
        target: AnyObject,
        applySelector: Selector,
        saveSelector: Selector
    ) -> NSMenuItem {
        let root = NSMenuItem(title: L10n.layoutProfiles, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.layoutProfiles)
        submenu.autoenablesItems = false

        let profiles = controller.listProfiles()
        if profiles.isEmpty {
            let empty = NSMenuItem(title: L10n.noSavedProfiles, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for name in profiles {
                let item = NSMenuItem(title: name, action: applySelector, keyEquivalent: "")
                item.target = target
                item.representedObject = name
                if controller.settings.activeProfileName == name {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        let saveItem = NSMenuItem(title: L10n.saveCurrentLayoutPrompt, action: saveSelector, keyEquivalent: "")
        saveItem.target = target
        submenu.addItem(saveItem)
        root.submenu = submenu
        return root
    }
}

/// 菜单项携带的分配请求（representedObject 的载体，避免把 id/分区拆成两个字符串字段）
public struct ZoneAssignmentRequest {
    public let itemID: String
    public let zone: MenuBarZone
    public init(itemID: String, zone: MenuBarZone) {
        self.itemID = itemID
        self.zone = zone
    }
}
