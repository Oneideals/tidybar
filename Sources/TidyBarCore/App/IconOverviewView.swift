import AppKit

private let iconPasteboardType = NSPasteboard.PasteboardType("com.tidybar.icon-id")

/// 图标总览：三行图标泳道（Bartender 风格，设置首页与首启向导共用）。
///
/// 核心交互设计：
/// 1. 对应三种状态的三行泳道：显示区（常驻）、隐藏区（收纳）、始终隐藏区；
/// 2. 图标以圆角胶囊卡片（Chip）横向陈列；
/// 3. 支持在不同泳道之间拖拽移动（Drag and Drop），拖入即自动重分配并更新台账；
/// 4. 辅助支持右键/点击菜单直接切换分区，兼顾无障碍与操作效率。
public final class IconOverviewView: NSView {
    public struct Row: Sendable, Equatable {
        public let item: ManagedItem
        public let zone: MenuBarZone
        public let isPositionalIdentity: Bool

        public init(item: ManagedItem, zone: MenuBarZone, isPositionalIdentity: Bool) {
            self.item = item
            self.zone = zone
            self.isPositionalIdentity = isPositionalIdentity
        }
    }

    /// 改分区的回调（itemID, targetZone）
    public var onReassign: (String, MenuBarZone) -> Void
    public var onZoneChanged: (() -> Void)?

    private var rows: [Row] = []
    private let stack = NSStackView()
    private var lanes: [MenuBarZone: LaneView] = [:]

    public init(onReassign: @escaping (String, MenuBarZone) -> Void) {
        self.onReassign = onReassign
        super.init(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let lane = LaneView(zone: zone) { [weak self] itemID, targetZone in
                self?.onReassign(itemID, targetZone)
                self?.onZoneChanged?()
            }
            lanes[zone] = lane
            stack.addArrangedSubview(lane)
        }
    }

    /// 唯一的刷新入口：整表按分区重画。
    public func reload(rows: [Row]) {
        self.rows = rows
        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let members = rows.filter { $0.zone == zone }
            lanes[zone]?.reload(rows: members)
        }
    }
}

/// 单个泳道视图（包含标题栏和可拖放卡片槽）
private final class LaneView: NSView {
    let zone: MenuBarZone
    let onMoveItem: (String, MenuBarZone) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let dropContainer: LaneDropContainerView

    init(zone: MenuBarZone, onMoveItem: @escaping (String, MenuBarZone) -> Void) {
        self.zone = zone
        self.onMoveItem = onMoveItem
        self.dropContainer = LaneDropContainerView(zone: zone, onDrop: onMoveItem)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let badge: String
        let color: NSColor
        let hint: String
        switch zone {
        case .visible:
            badge = "🟢 显示区"
            color = .systemGreen
            hint = "始终在菜单栏可见"
        case .hidden:
            badge = "🟠 隐藏区"
            color = .systemOrange
            hint = "收纳在抽屉面板，点击 ☰ 呼出"
        case .alwaysHidden:
            badge = "⚪️ 始终隐藏"
            color = .systemGray
            hint = "完全不展示"
        }

        titleLabel.stringValue = "\(badge) · \(hint)"
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = color
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(countLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        dropContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropContainer)

        NSLayoutConstraint.activate([
            dropContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            dropContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload(rows: [IconOverviewView.Row]) {
        countLabel.stringValue = "\(rows.count) 项"
        dropContainer.reload(rows: rows)
    }
}

/// 支持拖拽落点的卡片容器槽
private final class LaneDropContainerView: NSView {
    let zone: MenuBarZone
    let onDrop: (String, MenuBarZone) -> Void

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "拖放图标到此处…")
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    init(zone: MenuBarZone, onDrop: @escaping (String, MenuBarZone) -> Void) {
        self.zone = zone
        self.onDrop = onDrop
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.0

        registerForDraggedTypes([iconPasteboardType])
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSColor.controlBackgroundColor.withAlphaComponent(0.4)
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        path.fill()

        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    func reload(rows: [IconOverviewView.Row]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !rows.isEmpty
        for row in rows.sorted(by: { $0.item.title < $1.item.title }) {
            let chip = DraggableIconChipView(row: row, onMoveItem: onDrop)
            stack.addArrangedSubview(chip)
        }
    }

    // MARK: - Drag & Drop Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pboard = sender.draggingPasteboard.string(forType: iconPasteboardType), !pboard.isEmpty else {
            return []
        }
        isHighlighted = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let itemID = sender.draggingPasteboard.string(forType: iconPasteboardType) else {
            return false
        }
        onDrop(itemID, zone)
        return true
    }
}

/// 可拖动的图标胶囊卡片（Chip）
private final class DraggableIconChipView: NSView, NSDraggingSource {
    let row: IconOverviewView.Row
    let onMoveItem: (String, MenuBarZone) -> Void

    private var isPressed = false
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(row: IconOverviewView.Row, onMoveItem: @escaping (String, MenuBarZone) -> Void) {
        self.row = row
        self.onMoveItem = onMoveItem
        super.init(frame: CGRect(x: 0, y: 0, width: 90, height: 32))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        // 尝试读取真实 App 图标或首字母占位
        let icon = resolveIcon(for: row.item)
        iconImageView.image = icon

        titleLabel.stringValue = row.item.title.isEmpty ? (row.item.ownerBundleID ?? "图标") : row.item.title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        var tooltipText = "\(row.item.title) (\(row.item.ownerBundleID ?? "系统"))"
        if row.isPositionalIdentity {
            tooltipText += " [按位置认领]"
        }
        toolTip = tooltipText

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func resolveIcon(for item: ManagedItem) -> NSImage {
        if let bundleID = item.ownerBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        // 首字母占位图
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 18, height: 18), xRadius: 4, yRadius: 4).fill()
        let letter = String(item.title.prefix(1)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: letter.isEmpty ? "•" : letter, attributes: attrs)
        let s = str.size()
        str.draw(at: NSPoint(x: (18 - s.width) / 2, y: (18 - s.height) / 2))
        image.unlockFocus()
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = isPressed
            ? NSColor.selectedControlColor.withAlphaComponent(0.2)
            : NSColor.controlColor.withAlphaComponent(0.85)
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()
    }

    // MARK: - Mouse & Dragging Source

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        needsDisplay = true
        if event.clickCount == 1 {
            showActionMenu(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showActionMenu(with: event)
    }

    private func showActionMenu(with event: NSEvent) {
        let menu = NSMenu(title: "移动图标")
        for targetZone in MenuBarZone.allCases where targetZone != row.zone {
            let item = NSMenuItem(title: "移到：\(targetZone.displayLabel)", action: #selector(menuMoveZone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = targetZone
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuMoveZone(_ sender: NSMenuItem) {
        guard let targetZone = sender.representedObject as? MenuBarZone else { return }
        onMoveItem(row.item.id, targetZone)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: iconPasteboardTypeWriter(id: row.item.id))
        let snapshot = snapshotImage()
        item.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
        isPressed = false
        needsDisplay = true
    }

    private func iconPasteboardTypeWriter(id: String) -> NSPasteboardItem {
        let pboard = NSPasteboardItem()
        pboard.setString(id, forType: iconPasteboardType)
        return pboard
    }

    private func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            layer?.render(in: context)
        }
        image.unlockFocus()
        return image
    }

    // MARK: - NSDraggingSource
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

/// 总览的组装器：从控制器拿快照并转成行。
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
