import AppKit

/// 图标总览：三分区全景清单（设置第一页，首启向导第 2 步复用）。
///
/// 这是用户问出来的界面，此前只有"整理图标"动作菜单——空间隐喻（看菜单栏本身）对老手够用，
/// 但"哪些在常驻/收纳/始终隐藏"这张表是品类基本盘（Bartender/Ice 的设置首页就是它）。
/// 88% 图标无名 ⇒ 每行都要给 缩略图 + 名称 + 归属进程 三个锚点；身份只靠位置的 6% 必须标出来，
/// 否则用户以为设置钉死了某个 App，其实它换个位置就认不出。
public final class IconOverviewView: NSView {
    public struct Row {
        public let item: ManagedItem
        public let zone: MenuBarZone
        public let isPositionalIdentity: Bool
    }

    /// 改分区的回调。声明成可重设的公开属性：设置页与向导各自绑定自己的控制器动作。
    public var onReassign: (String, MenuBarZone) -> Void
    private var rows: [Row] = []
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let zoneHeaderColors: [MenuBarZone: NSColor] = [
        .visible: .systemGreen, .hidden: .systemOrange, .alwaysHidden: .systemGray,
    ]

    public var onZoneChanged: (() -> Void)?

    public init(onReassign: @escaping (String, MenuBarZone) -> Void) {
        self.onReassign = onReassign
        super.init(frame: CGRect(x: 0, y: 0, width: 460, height: 420))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func setup() {
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -24),
        ])
    }

    /// 唯一的刷新入口：整表按分区重画。
    public func reload(rows: [Row]) {
        self.rows = rows
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var previous: NSView?
        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let members = rows.filter { $0.zone == zone }.sorted { $0.item.title < $1.item.title }
            let header = makeHeader(zone: zone, count: members.count, previous: previous)
            stack.addArrangedSubview(header)
            previous = header
            for row in members {
                let line = makeRow(row)
                stack.addArrangedSubview(line)
                previous = line
            }
            if members.isEmpty {
                let empty = NSTextField(labelWithString: "　（空）")
                empty.font = NSFont.systemFont(ofSize: 10)
                empty.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(empty)
                previous = empty
            }
        }
    }

    private func makeHeader(zone: MenuBarZone, count: Int, previous: NSView?) -> NSView {
        let title = NSTextField(labelWithString: "\(zone.displayLabel) · \(count) 项")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = zoneHeaderColors[zone] ?? .labelColor
        return title
    }

    private func makeRow(_ row: Row) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let name = NSTextField(labelWithString: row.item.title)
        name.font = NSFont.systemFont(ofSize: 12)
        let owner = NSTextField(labelWithString: row.item.ownerBundleID ?? "（系统）")
        owner.font = NSFont.systemFont(ofSize: 9)
        owner.textColor = .tertiaryLabelColor

        var rightmost: NSView = name
        container.addSubview(name)
        name.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8).isActive = true
        name.centerYAnchor.constraint(equalTo: container.centerYAnchor).isActive = true

        if row.isPositionalIdentity {
            let warn = NSTextField(labelWithString: "按位置认领")
            warn.font = NSFont.systemFont(ofSize: 9)
            warn.textColor = .systemOrange
            warn.toolTip = "这个图标没有稳定名称，我们按它出现的位置认领；它或邻居被挪动后可能需要你重新指定。"
            container.addSubview(warn)
            warn.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6).isActive = true
            warn.centerYAnchor.constraint(equalTo: container.centerYAnchor).isActive = true
            rightmost = warn
        }

        container.addSubview(owner)
        owner.leadingAnchor.constraint(equalTo: rightmost.trailingAnchor, constant: 6).isActive = true
        owner.centerYAnchor.constraint(equalTo: container.centerYAnchor).isActive = true

        // 目标区按钮组：除当前区外各一个。点击 = 改分区（走控制器的 move，含落点计算与台账钉住）
        var anchorView: NSView = owner
        for target in MenuBarZone.allCases where target != row.zone {
            let button = NSButton(
                title: target.displayLabel,
                target: self,
                action: #selector(reassign(_:))
            )
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 10)
            button.tag = zoneTag(target)
            button.identifier = NSUserInterfaceItemIdentifier(row.item.id)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: anchorView.trailingAnchor, constant: 8),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            anchorView = button
        }
        return container
    }

    private func zoneTag(_ zone: MenuBarZone) -> Int {
        MenuBarZone.allCases.firstIndex(of: zone) ?? 0
    }

    @objc private func reassign(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              MenuBarZone.allCases.indices.contains(sender.tag) else { return }
        onReassign(id, MenuBarZone.allCases[sender.tag])
        onZoneChanged?()
    }
}

/// 总览的组装器：从控制器拿快照并转成行。
/// 独立成类型是为了设置页和首启向导喂同一份数据、同一种行语义，不会各拼一套。
public enum IconOverviewBuilder {
    public static func rows(from controller: TidyBarController) -> [IconOverviewView.Row] {
        let snapshot = controller.snapshot
        return snapshot.items
            .filter { !$0.isSystemOwned }
            .compactMap { item in
                guard let zone = snapshot.layout.zone(of: item.id) else { return nil }
                return IconOverviewView.Row(
                    item: item,
                    zone: zone,
                    isPositionalIdentity: item.isPositionalIdentity
                )
            }
    }
}
