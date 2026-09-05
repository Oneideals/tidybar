import AppKit

private let iconPasteboardType = NSPasteboard.PasteboardType("com.tidybar.icon-id")

/// 图标总览：对标 Bartender 的真实三行菜单栏托盘（设置首页与首启向导共用）。
///
/// 核心架构与设计规范：
/// 1. 严格三行托盘：对应「显示区」「隐藏区」「始终隐藏区」；
/// 2. 纯正菜单栏拟物托盘（Lane Shelf）：高度与质感对标 macOS 状态栏，自适应暗色/浅色深邃半透明底色；
/// 3. 真实图标单元（Icon Cell）：34x34pt 方形单元，显示真实高分辨率 App 图标或矢量微标，无冗余宽文本条；
/// 4. 自适应优雅折行：托盘容纳多图标时（如 28 项隐藏区），自动折为双行，所有图标一览无余，杜绝横向滚动截断；
/// 5. 原生拖放（Drag & Drop）与快捷菜单：支持拖拽跨行吸附投递，同时支持单击/右键一键移动；
/// 6. 实时悬停检查器（Inspector）：悬停任意图标即时展示 App 名、Bundle ID 与分区状态。
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
    private let lanesStack = NSStackView()
    private var lanes: [MenuBarZone: LaneView] = [:]
    private let inspectorCard = NSView()
    private let inspectorIconView = NSImageView()
    private let inspectorTextLabel = NSTextField(labelWithString: "")
    private let smartApplyButton = NSButton()

    public init(onReassign: @escaping (String, MenuBarZone) -> Void) {
        self.onReassign = onReassign
        super.init(frame: CGRect(x: 0, y: 0, width: 720, height: 380))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("不用 nib 加载") }

    private func setup() {
        lanesStack.orientation = .vertical
        lanesStack.alignment = .width
        lanesStack.distribution = .gravityAreas
        lanesStack.spacing = 14
        lanesStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lanesStack)

        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let lane = LaneView(
                zone: zone,
                onMoveItem: { [weak self] itemID, targetZone in
                    self?.onReassign(itemID, targetZone)
                    self?.onZoneChanged?()
                },
                onHoverItem: { [weak self] item, itemZone in
                    self?.updateInspector(item: item, zone: itemZone)
                }
            )
            lanes[zone] = lane
            lanesStack.addArrangedSubview(lane)
        }

        // 底部悬停检查器与操作指南
        setupInspectorCard()

        NSLayoutConstraint.activate([
            lanesStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            lanesStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            lanesStack.topAnchor.constraint(equalTo: topAnchor),

            inspectorCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            inspectorCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            inspectorCard.topAnchor.constraint(equalTo: lanesStack.bottomAnchor, constant: 14),
            inspectorCard.heightAnchor.constraint(equalToConstant: 34),
            inspectorCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func setupInspectorCard() {
        inspectorCard.wantsLayer = true
        inspectorCard.layer?.cornerRadius = 8
        inspectorCard.layer?.borderWidth = 1
        inspectorCard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inspectorCard)

        inspectorIconView.translatesAutoresizingMaskIntoConstraints = false
        inspectorIconView.imageScaling = .scaleProportionallyUpOrDown
        inspectorCard.addSubview(inspectorIconView)

        inspectorTextLabel.font = NSFont.systemFont(ofSize: 11)
        inspectorTextLabel.textColor = .secondaryLabelColor
        inspectorTextLabel.lineBreakMode = .byTruncatingTail
        inspectorTextLabel.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.addSubview(inspectorTextLabel)

        smartApplyButton.title = "🪄 一键智能推荐收纳"
        smartApplyButton.bezelStyle = .rounded
        smartApplyButton.controlSize = .small
        smartApplyButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        smartApplyButton.target = self
        smartApplyButton.action = #selector(applySmartRecommendations)
        smartApplyButton.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.addSubview(smartApplyButton)

        NSLayoutConstraint.activate([
            inspectorIconView.leadingAnchor.constraint(equalTo: inspectorCard.leadingAnchor, constant: 10),
            inspectorIconView.centerYAnchor.constraint(equalTo: inspectorCard.centerYAnchor),
            inspectorIconView.widthAnchor.constraint(equalToConstant: 18),
            inspectorIconView.heightAnchor.constraint(equalToConstant: 18),

            inspectorTextLabel.leadingAnchor.constraint(equalTo: inspectorIconView.trailingAnchor, constant: 8),
            inspectorTextLabel.trailingAnchor.constraint(lessThanOrEqualTo: smartApplyButton.leadingAnchor, constant: -8),
            inspectorTextLabel.centerYAnchor.constraint(equalTo: inspectorCard.centerYAnchor),

            smartApplyButton.trailingAnchor.constraint(equalTo: inspectorCard.trailingAnchor, constant: -8),
            smartApplyButton.centerYAnchor.constraint(equalTo: inspectorCard.centerYAnchor),
        ])

        updateInspector(item: nil, zone: nil)
    }

    @objc private func applySmartRecommendations() {
        let recommendations = SmartItemClassifier.classifyAll(items: rows.map(\.item))
        for rec in recommendations {
            onReassign(rec.itemID, rec.recommendedZone)
        }
        onZoneChanged?()
    }

    private func updateInspector(item: ManagedItem?, zone: MenuBarZone?) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        inspectorCard.layer?.backgroundColor = isDark
            ? NSColor.white.withAlphaComponent(0.04).cgColor
            : NSColor.black.withAlphaComponent(0.03).cgColor
        inspectorCard.layer?.borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor

        if let item = item, let zone = zone {
            let appName = item.title.isEmpty ? (item.ownerBundleID ?? "未知应用") : item.title
            let bundle = item.ownerBundleID ?? "未知来源"
            let posHint = item.isPositionalIdentity ? " · [位置匹配]" : ""
            let rec = SmartItemClassifier.classify(item: item)
            inspectorIconView.image = AppIconResolver.resolve(for: item)
            inspectorIconView.isHidden = false
            inspectorTextLabel.stringValue = "\(appName)（\(bundle)）\(posHint) ｜ 当前：\(zone.displayLabel) ｜ 智能推荐：\(rec.recommendedZone.displayLabel)（\(rec.category.rawValue) · \(rec.reason)）"
            inspectorTextLabel.textColor = .labelColor
        } else {
            inspectorIconView.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "提示")
            inspectorIconView.isHidden = false
            inspectorTextLabel.stringValue = "💡 提示：支持图标直接跨托盘拖拽，也可点击右侧「一键智能推荐收纳」按人机交互规则一键分类。"
            inspectorTextLabel.textColor = .secondaryLabelColor
        }
    }

    /// 唯一的刷新入口：整表按分区重画。
    public func reload(rows: [Row]) {
        self.rows = rows
        for zone in [MenuBarZone.visible, .hidden, .alwaysHidden] {
            let members = rows.filter { $0.zone == zone }
            lanes[zone]?.reload(rows: members)
        }
        updateInspector(item: nil, zone: nil)
    }
}

// MARK: - 单个泳道视图（包含标题栏和真实菜单栏托盘）

private final class LaneView: NSView {
    let zone: MenuBarZone
    let onMoveItem: (String, MenuBarZone) -> Void
    let onHoverItem: (ManagedItem?, MenuBarZone) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")
    private let shelf: LaneShelfView

    init(
        zone: MenuBarZone,
        onMoveItem: @escaping (String, MenuBarZone) -> Void,
        onHoverItem: @escaping (ManagedItem?, MenuBarZone) -> Void
    ) {
        self.zone = zone
        self.onMoveItem = onMoveItem
        self.onHoverItem = onHoverItem
        self.shelf = LaneShelfView(zone: zone, onDrop: onMoveItem, onHover: onHoverItem)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let titleText: String
        let color: NSColor
        let hintText: String
        switch zone {
        case .visible:
            titleText = "🟢 显示区 (Shown)"
            color = .systemGreen
            hintText = "始终在菜单栏常驻可见"
        case .hidden:
            titleText = "🟠 隐藏区 (Hidden)"
            color = .systemOrange
            hintText = "默认收纳折叠，点击 ☰ 呼出"
        case .alwaysHidden:
            titleText = "⚪️ 始终隐藏 (Always Hidden)"
            color = .systemGray
            hintText = "完全隐藏，展开抽屉中亦不显示"
        }

        titleLabel.stringValue = titleText
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = color
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        hintLabel.stringValue = "—  \(hintText)"
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hintLabel)

        countBadge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countBadge.textColor = .tertiaryLabelColor
        countBadge.alignment = .right
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(countBadge)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            hintLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            countBadge.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            countBadge.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        shelf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shelf)

        NSLayoutConstraint.activate([
            shelf.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            shelf.leadingAnchor.constraint(equalTo: leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: trailingAnchor),
            shelf.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload(rows: [IconOverviewView.Row]) {
        countBadge.stringValue = "\(rows.count) 项"
        shelf.reload(rows: rows)
    }
}

// MARK: - 拟物菜单栏托盘（LaneShelfView）

private final class LaneShelfView: NSView {
    override var isFlipped: Bool { true }

    let zone: MenuBarZone
    let onDrop: (String, MenuBarZone) -> Void
    let onHover: (ManagedItem?, MenuBarZone) -> Void

    private var itemCells: [DraggableIconCellView] = []
    private let emptyLabel = NSTextField(labelWithString: "")
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    private var shelfHeightConstraint: NSLayoutConstraint?

    init(
        zone: MenuBarZone,
        onDrop: @escaping (String, MenuBarZone) -> Void,
        onHover: @escaping (ManagedItem?, MenuBarZone) -> Void
    ) {
        self.zone = zone
        self.onDrop = onDrop
        self.onHover = onHover
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        registerForDraggedTypes([iconPasteboardType])
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        let emptyHint: String
        switch zone {
        case .visible:
            emptyHint = "暂无图标（拖拽图标到此处设为常驻可见）"
        case .hidden:
            emptyHint = "暂无图标（拖拽图标到此处收进隐藏抽屉）"
        case .alwaysHidden:
            emptyHint = "暂无图标（拖拽图标到此处彻底隐藏）"
        }
        emptyLabel.stringValue = emptyHint
        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let hConstraint = heightAnchor.constraint(equalToConstant: 48)
        hConstraint.priority = .defaultHigh
        hConstraint.isActive = true
        self.shelfHeightConstraint = hConstraint

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(calibratedWhite: 0.15, alpha: 0.85)
            : NSColor(calibratedWhite: 0.94, alpha: 0.85)
        bgColor.setFill()
        path.fill()

        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        } else {
            let borderColor = isDark
                ? NSColor(calibratedWhite: 0.28, alpha: 0.5)
                : NSColor(calibratedWhite: 0.82, alpha: 0.8)
            borderColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }

    func reload(rows: [IconOverviewView.Row]) {
        itemCells.forEach { $0.removeFromSuperview() }
        itemCells.removeAll()

        emptyLabel.isHidden = !rows.isEmpty

        let sorted = rows.sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        for row in sorted {
            let cell = DraggableIconCellView(
                row: row,
                onMoveItem: onDrop,
                onHover: { [weak self] item in
                    guard let self = self else { return }
                    self.onHover(item, self.zone)
                }
            )
            addSubview(cell)
            itemCells.append(cell)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()

        let availableWidth = bounds.width - 24 // 左右留 12pt 内边距
        let itemSize: CGFloat = 34
        let spacing: CGFloat = 6
        let topInset: CGFloat = 7
        let bottomInset: CGFloat = 7

        guard availableWidth > itemSize else { return }

        let itemsPerRow = max(1, Int((availableWidth + spacing) / (itemSize + spacing)))

        var currentX: CGFloat = 12
        var currentY: CGFloat = topInset

        for (index, cell) in itemCells.enumerated() {
            if index > 0 && index % itemsPerRow == 0 {
                currentX = 12
                currentY += itemSize + spacing
            }
            cell.frame = CGRect(x: currentX, y: currentY, width: itemSize, height: itemSize)
            currentX += itemSize + spacing
        }

        let rowsCount = itemCells.isEmpty ? 1 : Int(ceil(Double(itemCells.count) / Double(itemsPerRow)))
        let desiredHeight = itemCells.isEmpty
            ? 48
            : (CGFloat(rowsCount) * itemSize + CGFloat(max(0, rowsCount - 1)) * spacing + topInset + bottomInset)

        if shelfHeightConstraint?.constant != desiredHeight {
            shelfHeightConstraint?.constant = desiredHeight
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let h = shelfHeightConstraint?.constant ?? 48
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
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

// MARK: - 精致纯图标单元（DraggableIconCellView）

private final class DraggableIconCellView: NSView, NSDraggingSource {
    let row: IconOverviewView.Row
    let onMoveItem: (String, MenuBarZone) -> Void
    let onHover: (ManagedItem?) -> Void

    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private let iconImageView = NSImageView()
    private var trackingArea: NSTrackingArea?

    init(
        row: IconOverviewView.Row,
        onMoveItem: @escaping (String, MenuBarZone) -> Void,
        onHover: @escaping (ManagedItem?) -> Void
    ) {
        self.row = row
        self.onMoveItem = onMoveItem
        self.onHover = onHover
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.image = AppIconResolver.resolve(for: row.item)
        addSubview(iconImageView)

        let displayName = row.item.title.isEmpty ? (row.item.ownerBundleID ?? "图标") : row.item.title
        var tip = "\(displayName)\n来源：\(row.item.ownerBundleID ?? "系统")\n分区：\(row.zone.displayLabel)"
        if row.isPositionalIdentity {
            tip += "\n[按位置认领：名称随未读或标题变化]"
        }
        toolTip = tip

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 22),
            iconImageView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover(row.item)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)

        let bgColor: NSColor
        if isPressed {
            bgColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
        } else if isHovered {
            bgColor = NSColor.labelColor.withAlphaComponent(0.14)
        } else {
            bgColor = NSColor.labelColor.withAlphaComponent(0.04)
        }
        bgColor.setFill()
        path.fill()

        let strokeColor = isHovered
            ? NSColor.separatorColor.withAlphaComponent(0.4)
            : NSColor.separatorColor.withAlphaComponent(0.1)
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Mouse & Dragging Source

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
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


// MARK: - 总览的组装器

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
