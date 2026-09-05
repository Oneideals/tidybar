import AppKit

/// 用菜单完成分区分配与首启引导。
///
/// 为什么先做菜单而不是面板内拖拽：跨区拖拽依赖 ⌘ 拖拽闸门（`isConfirmedSupportedOS` 目前 false），
/// 而"把某个图标收进隐藏区"这个动作本身只是布局意图——菜单能立刻把它交付出去，
/// 等闸门开放时同一套意图直接换成拖拽落点，不必重做。
extension TidyBarController {
    /// 可分配的项：排除系统托管图标（默认不参与自动隐藏，报告 A1 的边界）
    public var assignableItems: [ManagedItem] {
        snapshot.items.filter { !$0.isSystemOwned }
    }

    /// 分区中文名，供 UI 与诊断共用一份，不在两处各写一遍
    public static func zoneLabel(_ zone: MenuBarZone) -> String {
        switch zone {
        case .visible: return "显示"
        case .hidden: return "收纳（点 ☰ 呼出）"
        case .alwaysHidden: return "始终隐藏"
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
        let root = NSMenuItem(title: "整理图标", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "整理图标")
        submenu.autoenablesItems = false

        let items = controller.assignableItems
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "暂未读到任何图标", action: nil, keyEquivalent: "")
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
            title: "　当前：\(controller.capability.displayName)（只改归属，不搬动系统图标）",
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
        let root = NSMenuItem(title: "新图标待确认 (\(controller.pendingNewItems.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "新图标待确认")
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
        let root = NSMenuItem(title: "首次设置", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "首次设置")
        submenu.autoenablesItems = false

        let step1 = NSMenuItem(
            title: "1. " + (accessibilityGranted ? "辅助功能权限：已授予 ✓" : "辅助功能权限：未授予"),
            action: accessibilityGranted ? nil : openSettingsSelector,
            keyEquivalent: ""
        )
        step1.target = accessibilityGranted ? nil : target
        submenu.addItem(step1)

        let step2 = NSMenuItem(title: "2. 在「整理图标」里把不常用的收进隐藏区", action: nil, keyEquivalent: "")
        step2.isEnabled = false
        submenu.addItem(step2)

        let step3 = NSMenuItem(title: "3. 试一下呼出：点 ☰ 或菜单栏分隔符", action: nil, keyEquivalent: "")
        step3.isEnabled = false
        submenu.addItem(step3)

        submenu.addItem(.separator())
        let finish = NSMenuItem(title: "完成引导", action: doneSelector, keyEquivalent: "")
        finish.target = target
        submenu.addItem(finish)
        let skip = NSMenuItem(title: "跳过引导", action: skipSelector, keyEquivalent: "")
        skip.target = target
        submenu.addItem(skip)
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
