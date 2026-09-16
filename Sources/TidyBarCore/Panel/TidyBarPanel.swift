import AppKit

/// 收纳面板（对标 Ice Bar / Bartender Bar，报告 A3）。
/// 无边框透明 NSPanel，窗口层级压在菜单栏之上，失焦不抢主界面焦点。
public final class TidyBarPanel: NSPanel {
    public init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 42),
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
        ignoresMouseEvents = false
        // 面板不显示在窗口切换器里
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

/// 真实菜单栏截图与明确占位；不使用应用图标代替状态项。
public final class TidyBarPanelView: NSView {
    public var items: [ManagedItem] = [] {
        didSet {
            guard oldValue != items else { return }
            updateTrackingAreas()
            needsDisplay = true
        }
    }
    /// 一行操作反馈（例如"这个 App 不允许工具代点"）。空表示不显示。
    public var notice: String? {
        didSet { needsDisplay = true }
    }
    /// 真实缩略图，键为图标 id。缺项表示尚未抓到（或被拒授权），此时画占位。
    public var images: [String: CGImage] = [:] {
        didSet {
            if images.count != oldValue.count || images.contains(where: { oldValue[$0.key] !== $0.value }) {
                capturedBackground = Self.backgroundColor(in: Array(images.values))
            }
            needsDisplay = true
        }
    }
    private var capturedBackground: NSColor?

    /// 截图带着菜单栏底色；使用边角像素的中位色，使整条抽屉与图标背景保持一致。
    private static func backgroundColor(in images: [CGImage]) -> NSColor? {
        let colors = images.flatMap { image -> [NSColor] in
            let bitmap = NSBitmapImageRep(cgImage: image)
            return [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]
                .compactMap { x, y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
        }.filter { $0.alphaComponent > 0.9 }
        guard !colors.isEmpty else { return nil }
        func median(_ component: (NSColor) -> CGFloat) -> CGFloat { colors.map(component).sorted()[colors.count / 2] }
        return NSColor(deviceRed: median(\.redComponent), green: median(\.greenComponent),
                       blue: median(\.blueComponent), alpha: 1)
    }

    private var captionColor: NSColor {
        guard let color = capturedBackground else { return .secondaryLabelColor }
        return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722 > 0.55
            ? .black : .white
    }
    public var onClick: ((ManagedItem) -> Void)?
    public var onRightClick: ((ManagedItem) -> Void)?
    public var onHoverChanged: ((Bool) -> Void)?
    public var onRequestCaptureAuthorization: (() -> Void)?
    private var pressedItemID: String?
    private var rightPressedItemID: String?
    private var pressedAuthorizationNotice = false
    var missingImageMessage: String? { didSet { needsDisplay = true } }
    var emptyMessage = "暂无收纳图标" {
        didSet { needsDisplay = true }
    }

    private var hoveredIndex: Int? {
        didSet {
            if oldValue != hoveredIndex {
                needsDisplay = true
                updateTooltip()
            }
        }
    }
    private var trackingArea: NSTrackingArea?

    public var hasCaptureAuthorization: Bool = false { didSet { needsDisplay = true } }

    private var footerText: String? { notice?.isEmpty == false ? notice : missingImageMessage }
    private var noticeAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: captionColor,
                .paragraphStyle: paragraph]
    }

    public func contentLayout(maximumWidth: CGFloat) -> PanelGeometry.ContentLayout {
        let metrics = PanelGeometry.Metrics()
        let sizes = items.map { item -> CGSize in
            let presentation = MenuBarIconStyle.presentation(
                for: item,
                bitmap: images[item.id],
                captureAuthorized: hasCaptureAuthorization
            )
            let dummy = CGRect(x: 0, y: 0, width: 200, height: metrics.itemSide)
            let glyphRect = MenuBarIconStyle.glyphRect(for: presentation, in: dummy)
            return CGSize(width: max(metrics.itemSide, glyphRect.width), height: metrics.itemSide)
        }
        let minimumWidth = footerText == nil ? PanelGeometry.Minimums.panelWidth : min(280, maximumWidth)
        let initial = PanelGeometry.contentLayout(itemSizes: sizes, maximumWidth: maximumWidth, minimumWidth: minimumWidth)
        let footerHeight: CGFloat
        if let text = footerText, !text.isEmpty {
            let width = max(1, initial.size.width - metrics.contentInset * 2)
            let measured = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000),
                options: [.usesLineFragmentOrigin], attributes: noticeAttributes)
            footerHeight = ceil(measured.height) + metrics.contentInset
        } else { footerHeight = 0 }
        return PanelGeometry.contentLayout(itemSizes: sizes, maximumWidth: maximumWidth,
                                           minimumWidth: minimumWidth, footerHeight: footerHeight)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override public func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let foundIndex = contentLayout(maximumWidth: bounds.width).itemFrames.firstIndex { $0.contains(point) }
        if hoveredIndex != foundIndex {
            hoveredIndex = foundIndex
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override public func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHoverChanged?(false)
    }

    private func updateTooltip() {
        guard let index = hoveredIndex, index < items.count else {
            toolTip = nil
            return
        }
        let item = items[index]
        let name = item.title.isEmpty ? (item.ownerBundleID ?? "未命名图标") : item.title
        toolTip = name
    }

    override public func draw(_ dirtyRect: NSRect) {
        let metrics = PanelGeometry.Metrics()
        let layout = contentLayout(maximumWidth: bounds.width)
        let isSingleRow = bounds.height <= metrics.rowHeight + 8
        let cornerRadius: CGFloat = isSingleRow ? min(16, bounds.height / 2) : 12
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        let background = capturedBackground ?? NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        background.setFill()
        path.fill()
        let strokeColor = NSColor.separatorColor.withAlphaComponent(0.25)
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if items.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = emptyMessage.size(withAttributes: attributes)
            let footerHeight = layout.footerFrame.map { $0.maxY + metrics.contentInset / 2 } ?? 0
            emptyMessage.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                          y: (bounds.maxY + footerHeight) / 2 - size.height / 2), withAttributes: attributes)
        }

        if let text = footerText, let rect = layout.footerFrame {
            (text as NSString).draw(in: rect, withAttributes: noticeAttributes)
        }

        for (index, item) in items.enumerated() {
            let rect = layout.itemFrames[index]

            // 悬停时呈现轻柔半透明高亮
            if hoveredIndex == index {
                let hoverColor = NSColor.labelColor.withAlphaComponent(0.08)
                hoverColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6).fill()
            }

            let presentation = MenuBarIconStyle.presentation(
                for: item,
                bitmap: images[item.id],
                captureAuthorized: hasCaptureAuthorization
            )
            MenuBarIconStyle.draw(presentation, for: item, in: rect)
        }
    }

    /// 计算等比自适应矩形（保证任意尺寸图标均居中且绝不产生纵横比变形）
    public static func aspectFit(size: CGSize, in container: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = round(size.width * scale)
        let h = round(size.height * scale)
        let x = round(container.midX - w / 2)
        let y = round(container.midY - h / 2)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedItemID = item(at: point)?.id
        pressedAuthorizationNotice = onRequestCaptureAuthorization != nil && notice == nil
            && contentLayout(maximumWidth: bounds.width).footerFrame?.contains(point) == true
    }

    override public func mouseUp(with event: NSEvent) {
        let initialID = pressedItemID
        let authorization = pressedAuthorizationNotice
        pressedItemID = nil
        pressedAuthorizationNotice = false
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point), item.id == initialID { onClick?(item) }
        else if authorization && contentLayout(maximumWidth: bounds.width).footerFrame?.contains(point) == true {
            onRequestCaptureAuthorization?()
        }
    }

    override public func rightMouseDown(with event: NSEvent) {
        rightPressedItemID = item(at: convert(event.locationInWindow, from: nil))?.id
    }

    override public func rightMouseUp(with event: NSEvent) {
        let initialID = rightPressedItemID
        rightPressedItemID = nil
        guard let item = item(at: convert(event.locationInWindow, from: nil)), item.id == initialID else { return }
        onRightClick?(item)
    }

    private func item(at point: CGPoint) -> ManagedItem? {
        for (item, rect) in zip(items, contentLayout(maximumWidth: bounds.width).itemFrames) {
            if rect.contains(point) { return item }
        }
        return nil
    }

    func cancelPendingClick() {
        pressedItemID = nil
        rightPressedItemID = nil
        pressedAuthorizationNotice = false
    }
}

/// 面板显隐控制：几何计算 + 屏幕参数变化时自动重新定位（报告 A3 第 3 条机制）。
public final class TidyBarPanelController: NSObject {
    public let panel = TidyBarPanel()
    private let panelView = TidyBarPanelView()
    private let screenObserver: ScreenObserving
    private let accessibility: AccessibilityTrustReading
    private let reader: MenuBarReading
    private let capturer: MenuBarIconCapturing
    private let bitmaps: IconBitmapStore
    private var lastAnchorX: CGFloat = 0
    private var lastScreen: ScreenInfo?
    private struct CaptureRequest {
        let items: [ManagedItem]
        let generation: Int
        let excludingWindowNumbers: [CGWindowID]
        let isValid: () -> Bool
        let completion: (Set<String>) -> Void
    }
    private var captureQueue: [CaptureRequest] = []
    private var captureRunning = false
    private var reservedCaptures: [String: Int] = [:]
    private var attemptedFrames: [String: CGRect] = [:]
    private var bitmapGeneration = 0

    public var onItemClick: ((ManagedItem) -> Void)? {
        didSet { panelView.onClick = onItemClick }
    }

    public var onRightClick: ((ManagedItem) -> Void)? {
        didSet { panelView.onRightClick = onRightClick }
    }

    public var onHoverChanged: ((Bool) -> Void)? {
        didSet { panelView.onHoverChanged = onHoverChanged }
    }

    /// 用户主动点击权限提示后交给装配层处理；预热和显示绝不自动申请权限。
    public var onRequestCaptureAuthorization: (() -> Void)? {
        didSet { updateContent() }
    }

    /// 内存压力时调用：位图全部丢弃，下次呼出面板按需重抓。
    /// 缓存自己实现了 `removeAll`，但**没人调它**就等于没有上限——
    /// "20MB 以内"这件事必须由一条真实的清理路径来保证。
    public func purgeBitmaps() {
        bitmapGeneration += 1
        attemptedFrames.removeAll()
        bitmaps.purge()
        panelView.images = [:]
        updateContent()
    }

    /// 当前位图缓存占用（字节），供性能面板与用例断言。
    public var bitmapCacheBytes: Int { bitmaps.currentBytes }
    public var hasCaptureAuthorization: Bool { capturer.isAuthorized }

    public func prewarmBitmaps(for items: [ManagedItem], excludingWindowNumbers: [CGWindowID] = [], isValid: @escaping () -> Bool,
                              completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let generation = bitmapGeneration
        enqueueCapture(items, excludingWindowNumbers: excludingWindowNumbers, isValid: isValid) { [weak self] rejected in
            guard let self, self.bitmapGeneration == generation, !rejected.isEmpty,
                  isValid(), self.capturer.isAuthorized else { completion(); return }
            // 位置在截图期间变化时只补抓一次，并重新获取观测绑定；不能反复截图旧坐标。
            let originals = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let reader = self.reader
            var delivered = false
            let timeout = DispatchWorkItem { if !delivered { delivered = true; completion() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let observed = reader.discoverItems()
                DispatchQueue.main.async { [weak self] in
                    guard !delivered else { return }
                    delivered = true
                    timeout.cancel()
                    guard let self, self.bitmapGeneration == generation, isValid() else { completion(); return }
                    let fresh = observed.filter { item in
                        guard rejected.contains(item.id), let original = originals[item.id],
                              original.ownerBundleID == item.ownerBundleID,
                              original.identitySource == item.identitySource else { return false }
                        return item.identitySource != .ownerOrdinal
                            || (original.ordinalInOwner == item.ordinalInOwner && original.ownerItemCount == item.ownerItemCount)
                    }
                    self.enqueueCapture(fresh, excludingWindowNumbers: excludingWindowNumbers, isValid: isValid) { _ in completion() }
                }
            }
        }
    }

    /// 给面板加一行反馈文字（代点失败原因等）。
    public func setActivationNotice(_ text: String?) {
        panelView.notice = text
        updateContent()
    }

    public init(
        services: SystemServices,
        capturer: MenuBarIconCapturing = UnverifiedMenuBarIconCapturer(),
        bitmaps: IconBitmapStore = IconBitmapStore()
    ) {
        self.screenObserver = services.screens
        self.accessibility = services.accessibility
        self.reader = services.reader
        self.capturer = capturer
        self.bitmaps = bitmaps
        super.init()
        panelView.wantsLayer = true
        panel.contentView = panelView
        screenObserver.addObserver { [weak self] in
            self?.repositionIfNeeded()
        }
    }

    /// 已验证截图按身份读取，折叠或移动坐标不会使其失效。
    public func cachedImages(for items: [ManagedItem]) -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for item in items {
            if let image = bitmaps.image(for: item) { result[item.id] = image }
        }
        return result
    }

    /// 显示时只补缺失且安全可见的项；失败的相同帧不因重复重绘而不断抓取。
    public func requestMissingBitmaps(for items: [ManagedItem], onBitmapsReady: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let screens = screenObserver.screens
        let missing = bitmaps.needsCapture(items).filter { item in
            reservedCaptures[item.id] == nil && attemptedFrames[item.id] != item.frame
                && screens.contains { IconCaptureGeometry.isVisibleMenuBarFrame(item.frame, on: $0) }
        }
        guard !missing.isEmpty, capturer.isAuthorized else { onBitmapsReady(); return }
        enqueueCapture(missing, isValid: { true }) { _ in onBitmapsReady() }
    }

    private func enqueueCapture(_ items: [ManagedItem], excludingWindowNumbers: [CGWindowID] = [], isValid: @escaping () -> Bool, completion: @escaping (Set<String>) -> Void) {
        var seen: Set<String> = []
        let unique = items.filter { seen.insert($0.id).inserted }
        for item in unique { reservedCaptures[item.id, default: 0] += 1 }
        captureQueue.append(CaptureRequest(items: unique, generation: bitmapGeneration, excludingWindowNumbers: excludingWindowNumbers, isValid: isValid, completion: completion))
        startNextCapture()
    }

    private func verifiedScreen(for item: ManagedItem, screens: [ScreenInfo], allowOcclusion: Bool = false) -> ScreenInfo? {
        guard let screen = screens.first(where: { IconCaptureGeometry.isVisibleMenuBarFrame(item.frame, on: $0) }) else { return nil }
        if !allowOcclusion {
            if let current = reader.currentFrame(of: item) {
                let dx = abs(current.origin.x - item.frame.origin.x)
                let dy = abs(current.origin.y - item.frame.origin.y)
                let dw = abs(current.width - item.frame.width)
                let dh = abs(current.height - item.frame.height)
                if dx > 2 || dy > 2 || dw > 2 || dh > 2 { return nil }
            }
            guard reader.hitTest(expected: item, at: CGPoint(x: item.centerX, y: item.frame.midY)) == .verified else { return nil }
        }
        return screen
    }

    private func startNextCapture() {
        precondition(Thread.isMainThread)
        guard !captureRunning, !captureQueue.isEmpty else { return }
        captureRunning = true
        let request = captureQueue.removeFirst()
        var finished = false
        var rejected: Set<String> = []
        var incoming: [(ManagedItem, CGImage, ScreenInfo)] = []
        var timeout: DispatchWorkItem?
        func finish(ingest: Bool) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            timeout = nil
            if ingest, request.generation == bitmapGeneration, request.isValid(), capturer.isAuthorized {
                let screens = screenObserver.screens
                let allowOcclusion = !request.excludingWindowNumbers.isEmpty
                let valid = incoming.filter { item, _, screen in
                    if verifiedScreen(for: item, screens: screens, allowOcclusion: allowOcclusion) == screen { return true }
                    rejected.insert(item.id)
                    return false
                }
                if request.isValid() {
                    for (item, image, _) in valid {
                        bitmaps.ingest(image, for: item)
                        attemptedFrames[item.id] = nil
                    }
                }
            }
            for item in request.items {
                let remaining = (reservedCaptures[item.id] ?? 1) - 1
                reservedCaptures[item.id] = remaining > 0 ? remaining : nil
            }
            captureRunning = false
            updateContent()
            request.completion(rejected)
            startNextCapture()
        }
        guard request.isValid(), request.generation == bitmapGeneration, capturer.isAuthorized else {
            finish(ingest: false)
            return
        }
        let screens = screenObserver.screens
        let allowOcclusion = !request.excludingWindowNumbers.isEmpty
        var groups: [CGDirectDisplayID: (screen: ScreenInfo, items: [ManagedItem])] = [:]
        for item in request.items {
            attemptedFrames[item.id] = item.frame
            guard let screen = verifiedScreen(for: item, screens: screens, allowOcclusion: allowOcclusion) else { rejected.insert(item.id); continue }
            if groups[screen.identifier] == nil { groups[screen.identifier] = (screen, []) }
            groups[screen.identifier]?.items.append(item)
        }
        guard request.isValid(), !groups.isEmpty else { finish(ingest: false); return }
        var remaining = groups.count
        let deadline = DispatchWorkItem { finish(ingest: false) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        for group in groups.values {
            guard request.isValid(), capturer.isAuthorized else { finish(ingest: false); return }
            let region = group.items.reduce(CGRect.null) { $0.union($1.frame) }.integral
            guard IconCaptureGeometry.isVisibleMenuBarFrame(region, on: group.screen) else {
                remaining -= 1
                if remaining == 0 { finish(ingest: true) }
                continue
            }
            capturer.capture(frame: region, scale: CGFloat(group.screen.scaleFactor), excludingWindowNumbers: request.excludingWindowNumbers) { result in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    guard request.isValid() else { finish(ingest: false); return }
                    if case .success(let image) = result {
                        for item in group.items {
                            if let crop = IconCaptureGeometry.crop(from: image, frame: item.frame, screenFrame: region,
                                displayPixelSize: CGSize(width: image.width, height: image.height)) {
                                incoming.append((item, crop, group.screen))
                            }
                        }
                    }
                    remaining -= 1
                    if remaining == 0 { finish(ingest: true) }
                }
            }
        }
    }

    public func show(items: [ManagedItem], screen: ScreenInfo?, anchorX: CGFloat) {
        precondition(Thread.isMainThread)
        guard let screen else { return }
        // 悬停等快照更新只刷新内容，不能把已经打开的抽屉重新移动到鼠标旁。
        if !isVisible { lastAnchorX = anchorX }
        lastScreen = screen
        bitmaps.retain(alive: Set(items.map(\.id)))
        panelView.items = items
        updateContent()
        panel.orderFrontRegardless()
        requestMissingBitmaps(for: items) { [weak self] in
            guard let self, self.isVisible else { return }
            self.updateContent()
        }
    }

    private func updateContent() {
        panelView.hasCaptureAuthorization = hasCaptureAuthorization
        panelView.images = cachedImages(for: panelView.items)
        panelView.emptyMessage = accessibility.isTrusted ? "暂无收纳图标" : "请授权辅助功能"
        panelView.missingImageMessage = !hasCaptureAuthorization
            ? "请授权屏幕录制以显示真实菜单栏图标"
            : nil
        panelView.onRequestCaptureAuthorization = !hasCaptureAuthorization ? onRequestCaptureAuthorization : nil
        guard let screen = lastScreen else { return }
        let maximumWidth = screen.frame.width - PanelGeometry.Margin.screenEdge * 2
        var layout = panelView.contentLayout(maximumWidth: maximumWidth)
        var frame = PanelGeometry.adjustedForNotch(
            PanelGeometry.panelFrame(screen: screen, itemCount: panelView.items.count, anchorX: lastAnchorX, contentSize: layout.size),
            screen: screen
        )
        if frame.width < layout.size.width {
            layout = panelView.contentLayout(maximumWidth: frame.width)
            frame = CGRect(x: frame.minX, y: frame.maxY - layout.size.height,
                           width: frame.width, height: layout.size.height)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    public func hide() {
        panelView.cancelPendingClick()
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    private func repositionIfNeeded() {
        guard isVisible else { return }
        let screen = screenObserver.screens.first { $0.identifier == lastScreen?.identifier } ?? screenObserver.primaryScreen
        show(items: panelView.items, screen: screen, anchorX: lastAnchorX)
    }
}
