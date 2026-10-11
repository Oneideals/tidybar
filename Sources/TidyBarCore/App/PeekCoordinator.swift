import AppKit
import CoreGraphics

/// 抽屉单项物理浮现协调器（状态机）。
///
/// 核心突破：
/// 将抽屉中被点击的图标 X 瞬间平移至 TidyBar 控制按钮右侧（常显区）；
/// 随后恢复推杆长度至 10,000pt，使所有其他收纳项安全退回屏外，
/// 唯独目标图标真实、稳定地驻留在系统菜单栏中。
/// 原生点击、右键菜单、光标悬停无缝兼容，全流程无弹窗/幕布闪烁、零焦点抢占。
@MainActor
public final class PeekCoordinator {
    public enum State: Equatable, Sendable {
        case idle
        case movingOut(itemID: String)
        case presented(itemID: String)
        case movingBack(itemID: String)

        public var currentItemID: String? {
            switch self {
            case .idle: return nil
            case .movingOut(let id), .presented(let id), .movingBack(let id): return id
            }
        }
    }

    public private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((State) -> Void)?

    private let services: SystemServices
    private weak var controller: TidyBarController?
    private let setPusherCollapsed: (Bool) -> Void
    private let proxyClickRelay: (ManagedItem, MenuBarClickRelay.Button) -> Void
    private let presentProxy: ((ManagedItem, Bool) -> CGRect?)?
    private let dismissProxy: (() -> Void)?

    private var watchdogTimer: Timer?
    private var rehideTimer: Timer?
    private var lastInteractionAt: Date = Date()
    private var presentedAt: Date = Date()
    private var currentPresentedItem: ManagedItem?

    private let queue = DispatchQueue(label: "local.tidybar.peek-coordinator", qos: .userInitiated)

    public init(
        services: SystemServices,
        controller: TidyBarController,
        setPusherCollapsed: @escaping (Bool) -> Void,
        proxyClickRelay: @escaping (ManagedItem, MenuBarClickRelay.Button) -> Void,
        presentProxy: ((ManagedItem, Bool) -> CGRect?)? = nil,
        dismissProxy: (() -> Void)? = nil
    ) {
        self.services = services
        self.controller = controller
        self.setPusherCollapsed = setPusherCollapsed
        self.proxyClickRelay = proxyClickRelay
        self.presentProxy = presentProxy
        self.dismissProxy = dismissProxy
    }

    // MARK: - 交互通知

    /// 外部交互（如菜单栏内点击、光标悬停、代点反馈等）续期
    public func noteInteraction() {
        lastInteractionAt = Date()
    }

    // MARK: - 启动浮现

    public func peek(item: ManagedItem, autoRightClick: Bool = false) {
        guard state == .idle else { return }
        guard services.cursor.isSessionInteractive else { return }

        presentedAt = Date()
        lastInteractionAt = Date()

        // 方案 A（虚拟代理图标模式）：0ms 瞬间浮现于常显区，推杆完全不缩短，零全部展开过程
        if let presentProxy {
            state = .presented(itemID: item.id)
            controller?.peekedItemID = item.id
            var targetItem = item
            if let frame = presentProxy(item, autoRightClick), frame.width > 10, frame.minX > 0 {
                targetItem = ManagedItem(
                    id: item.id,
                    ownerBundleID: item.ownerBundleID,
                    title: item.title,
                    frame: frame,
                    isSystemOwned: item.isSystemOwned,
                    lastActivatedAt: item.lastActivatedAt,
                    identitySource: item.identitySource,
                    ordinalInOwner: item.ordinalInOwner,
                    ownerItemCount: item.ownerItemCount
                )
                controller?.updateItemFrame(id: item.id, frame: frame)
            }
            currentPresentedItem = targetItem
            startRehidePolling(item: targetItem)
            return
        }

        state = .movingOut(itemID: item.id)
        controller?.peekedItemID = item.id

        // 挂 3 秒看门狗：防止任何异常导致状态机悬挂
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.abortToIdle(message: "浮现移动操作超时（看门狗触发）")
            }
        }

        // 极速收起推杆（0ms 延迟，零遮罩闪烁），让隐藏区项进入 AX 可达范围
        setPusherCollapsed(true)

        // 立即执行平移操作
        executeMoveOut(item: item, autoRightClick: autoRightClick)
    }

    private func executeMoveOut(item: ManagedItem, autoRightClick: Bool) {
        let reader = self.services.reader
        let mover = self.services.mover
        let ownsItem: (ManagedItem) -> Bool = { [weak self] cand in
            self?.controller?.owns(cand) ?? false
        }

        self.queue.async { [weak self] in
            guard let self else { return }
            var live: [ManagedItem] = []
            var target: ManagedItem?
            var prevX: CGFloat = -1

            // 智能采样：等待 WindowServer 跨进程平移动画完全静止（位移差 < 1.0pt）
            for attempt in 1...20 {
                live = reader.discoverItems()
                target = live.first { cand in
                    guard cand.frame.width > 0, cand.centerX > 0 else { return false }
                    if cand.matches(id: item.id) { return true }
                    if let ob = item.ownerBundleID, let cb = cand.ownerBundleID,
                       ob.caseInsensitiveCompare(cb) == .orderedSame {
                        if !item.title.isEmpty && (cand.title == item.title || cand.title.contains(item.title) || item.title.contains(cand.title)) { return true }
                        if item.ordinalInOwner == cand.ordinalInOwner { return true }
                    }
                    return false
                }
                if let t = target {
                    if prevX > 0 && abs(t.centerX - prevX) < 1.0 {
                        fprint("PeekCoordinator: 第 \(attempt) 次探测目标图标已平移到位且稳定静止 \(t.id), centerX=\(t.centerX)")
                        break
                    }
                    prevX = t.centerX
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
            guard let target else {
                fprint("PeekCoordinator: 未在菜单栏找到目标图标 item=\(item.id) title=\(item.title) liveCount=\(live.count)")
                DispatchQueue.main.async { self.abortToIdle(message: "未在菜单栏找到目标图标") }
                return
            }

            // 查找 TidyBar 切换按钮
            let toggle = live.first {
                ownsItem($0) && $0.frame.width <= 32 && $0.centerX > 0
            }
            guard let toggle else {
                fprint("PeekCoordinator: 未找到控制按钮锚点 liveCount=\(live.count)")
                DispatchQueue.main.async { self.abortToIdle(message: "未找到控制按钮锚点") }
                return
            }

            // 目标落点：拖到切换按钮右侧紧贴常显区
            let dropTargetX = toggle.frame.maxX + target.frame.width / 2 + 4
            fprint("PeekCoordinator: executeMoveOut target=\(target.id) currentX=\(target.centerX) dropTargetX=\(dropTargetX) toggleX=\(toggle.centerX)")

            guard let mover else {
                DispatchQueue.main.async { self.abortToIdle(message: "无可用移动器") }
                return
            }

            // 执行物理平移（支持瞬态遮挡快速重试 1 次）
            var moveSuccess = false
            for retry in 1...2 {
                do {
                    _ = try mover.move(itemID: target.id, toX: dropTargetX)
                    moveSuccess = true
                    break
                } catch {
                    if retry == 1 {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    fprint("PeekCoordinator: 物理移出失败：\(error)")
                    DispatchQueue.main.async { self.abortToIdle(message: "物理移出失败：\(error)") }
                    return
                }
            }
            guard moveSuccess else { return }

            // 验证落点：X 必须位于按钮右侧
            let afterMove = reader.discoverItems()
            guard let verified = afterMove.first(where: {
                ($0.matches(id: target.id) || ($0.ownerBundleID?.caseInsensitiveCompare(target.ownerBundleID ?? "") == .orderedSame && $0.ordinalInOwner == target.ordinalInOwner))
                && $0.centerX > toggle.centerX
            }) else {
                fprint("PeekCoordinator: 落点校验未通过")
                DispatchQueue.main.async { self.abortToIdle(message: "落点校验未通过") }
                return
            }

            fprint("PeekCoordinator: 移出成功 verifiedX=\(verified.centerX)")
            DispatchQueue.main.async {
                self.finishMoveOut(verifiedItem: verified, autoRightClick: autoRightClick)
            }
        }
    }

    private func finishMoveOut(verifiedItem: ManagedItem, autoRightClick: Bool) {
        guard case .movingOut = state else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        // 撑回推杆，隐藏所有其他收纳项
        setPusherCollapsed(false)

        currentPresentedItem = verifiedItem
        controller?.updateItemFrame(id: verifiedItem.id, frame: verifiedItem.frame)
        state = .presented(itemID: verifiedItem.id)

        // 若要求自动右键，派发带 syntheticEventTag 的原生右键交互
        if autoRightClick {
            proxyClickRelay(verifiedItem, .secondary)
        }

        startRehidePolling(item: verifiedItem)
    }

    // MARK: - 回收轮询

    private func startRehidePolling(item: ManagedItem) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkRehideCondition(item: item)
            }
        }
    }

    public func updatePresentedItem(_ item: ManagedItem) {
        if case .presented = state {
            currentPresentedItem = item
        }
    }

    private func isItemMenuPresented(_ item: ManagedItem) -> Bool? {
        if services.reader.isMenuPresented(for: item) == true {
            return true
        }
        let owner = item.ownerBundleID ?? ManagedItem.ownerFromID(item.id)
        if let owner, !owner.isEmpty {
            let matchingApps = NSWorkspace.shared.runningApplications.filter {
                guard let bid = $0.bundleIdentifier else { return false }
                let low = bid.lowercased(), target = owner.lowercased()
                return low == target || low.hasPrefix(target) || target.hasPrefix(low)
            }
            if !matchingApps.isEmpty {
                let matchingPIDs = Set(matchingApps.map(\.processIdentifier))
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                for w in list {
                    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                    let ownerName = w[kCGWindowOwnerName as String] as? String ?? ""
                    let isApp = matchingPIDs.contains(pid)
                        || matchingApps.contains { app in
                            app.localizedName != nil && !app.localizedName!.isEmpty && ownerName.caseInsensitiveCompare(app.localizedName!) == .orderedSame
                        }
                    guard isApp else { continue }
                    guard let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                          let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                          frame.width > 20 && frame.height > 20 else { continue }
                    let layer = w[kCGWindowLayer as String] as? Int ?? 0

                    // 严防将状态项自身图标窗口（如 Doubao 的 52x52 layer 27 窗口）误判为已展开的菜单弹窗
                    if (layer == 25 || layer == 27) && frame.width <= 70 && frame.height <= 70 {
                        continue
                    }

                    if layer >= 3 {
                        return true
                    }
                    if layer == 0 {
                        // 支持在 layer 0 呈现的瞬态弹出面板（如 OPPO 互联等无边框浮动面板）
                        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
                        let appKitTop = primaryHeight - frame.minY
                        for screen in NSScreen.screens {
                            let menuBarBottom = screen.frame.maxY - (screen.frame.height - screen.visibleFrame.height)
                            if abs(appKitTop - menuBarBottom) <= 45 && frame.height < 800 && frame.width < 900 {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return services.reader.isMenuPresented(for: item)
    }

    private func checkRehideCondition(item: ManagedItem) {
        guard case .presented(let itemID) = state, item.matches(id: itemID) else {
            rehideTimer?.invalidate()
            rehideTimer = nil
            return
        }

        let isPresented = isItemMenuPresented(item)
        let isMouseDown = NSEvent.pressedMouseButtons != 0
        let mouseLoc = NSEvent.mouseLocation
        let delay = controller?.settings.rehideDelay ?? 2.0

        // 交互续期：优先采用 currentPresentedItem 的物理真实坐标，杜绝快照历史坐标污染；扩大悬停容差至 ±48pt
        let itemFrame = currentPresentedItem?.frame
            ?? controller?.items.first(where: { $0.matches(id: item.id) })?.frame
            ?? controller?.snapshot.items.first(where: { $0.matches(id: item.id) })?.frame
            ?? item.frame
        let hoverArea = itemFrame.insetBy(dx: -48, dy: -16)
        var isHovering = hoverArea.contains(mouseLoc)
        if !isHovering, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) {
            let menuBarBottom = screen.frame.maxY - (screen.frame.height - screen.visibleFrame.height)
            if mouseLoc.y >= menuBarBottom - 8 && mouseLoc.y <= screen.frame.maxY + 8 {
                if abs(mouseLoc.x - itemFrame.midX) <= 60 {
                    isHovering = true
                }
            }
        }
        if isPresented != false || isMouseDown || isHovering {
            lastInteractionAt = Date()
        }

        // 初始宽限保护：刚浮现的前 4.0 秒内给予充分时间供用户移动光标至菜单栏，避免手速慢导致被提前收回
        let now = Date()
        if now.timeIntervalSince(presentedAt) < 4.0 {
            lastInteractionAt = now
        }

        let shouldRehide = RehidePolicy.shouldRehide(
            now: now,
            lastInteractionAt: lastInteractionAt,
            rehideDelay: delay,
            isMenuPresented: isPresented,
            isMouseDown: isMouseDown,
            cursorLocation: mouseLoc,
            itemFrame: itemFrame
        )

        if shouldRehide {
            fprint("PeekCoordinator: shouldRehide=true item=\(item.id) isPresented=\(String(describing: isPresented)) isMouseDown=\(isMouseDown) mouseLoc=\(mouseLoc) itemFrame=\(itemFrame)")
            rehideTimer?.invalidate()
            rehideTimer = nil
            rehide(item: item)
        }
    }

    // MARK: - 移回隐藏区

    public func rehide(item: ManagedItem) {
        guard case .presented = state else { return }
        rehideTimer?.invalidate()
        rehideTimer = nil

        if let dismissProxy {
            dismissProxy()
            controller?.peekedItemID = nil
            currentPresentedItem = nil
            state = .idle
            return
        }

        state = .movingBack(itemID: item.id)

        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishMoveBack(success: false)
            }
        }

        // 瞬间收起推杆，让隐藏区就位
        setPusherCollapsed(true)

        executeMoveBack(item: item)
    }

    private func executeMoveBack(item: ManagedItem) {
        let reader = self.services.reader
        let mover = self.services.mover
        let ownsItem: (ManagedItem) -> Bool = { [weak self] cand in
            self?.controller?.owns(cand) ?? false
        }

        self.queue.async { [weak self] in
            guard let self else { return }
            var live: [ManagedItem] = []
            var target: ManagedItem?
            for attempt in 1...10 {
                live = reader.discoverItems()
                target = live.first { cand in
                    guard cand.frame.width > 0, cand.centerX > 0 else { return false }
                    if cand.id.caseInsensitiveCompare(item.id) == .orderedSame { return true }
                    if let ob = item.ownerBundleID, let cb = cand.ownerBundleID,
                       ob.caseInsensitiveCompare(cb) == .orderedSame {
                        if !item.title.isEmpty && (cand.title == item.title || cand.title.contains(item.title) || item.title.contains(cand.title)) { return true }
                        if item.ordinalInOwner == cand.ordinalInOwner { return true }
                    }
                    return false
                }
                if target != nil {
                    fprint("PeekCoordinator: 回收探测命中目标图标 \(target!.id), centerX=\(target!.centerX)")
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard let target else {
                fprint("PeekCoordinator: executeMoveBack 未在菜单栏找到目标图标 item=\(item.id)")
                DispatchQueue.main.async { self.finishMoveBack(success: false) }
                return
            }

            // 找到右分隔符（tidybar_separator）或 TidyBar 控制按钮作为隐藏区右边界
            let separator = live.first { cand in
                if cand.title == "╎" || cand.title == "┆" { return true }
                return cand.ownerBundleID == Bundle.main.bundleIdentifier && cand.frame.width <= 2
            }
            let toggle = live.first {
                ownsItem($0) && $0.frame.width <= 32 && $0.centerX > 0
            }
            let boundaryX = separator?.centerX ?? (toggle?.frame.minX ?? (target.centerX - 50))

            // 目标落点：拖到分隔符左侧（隐藏区末位）
            let dropTargetX = max(50, boundaryX - target.frame.width / 2 - 4)

            guard let mover else {
                DispatchQueue.main.async { self.finishMoveBack(success: false) }
                return
            }

            var moveSuccess = false
            for retry in 1...2 {
                do {
                    _ = try mover.move(itemID: target.id, toX: dropTargetX)
                    moveSuccess = true
                    break
                } catch {
                    if retry == 1 {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    DispatchQueue.main.async { self.finishMoveBack(success: false) }
                    return
                }
            }
            guard moveSuccess else { return }

            DispatchQueue.main.async {
                self.finishMoveBack(success: true)
            }
        }
    }

    private func finishMoveBack(success: Bool) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        setPusherCollapsed(false)

        controller?.peekedItemID = nil
        currentPresentedItem = nil
        state = .idle

        if !success {
            NSLog("TIDYBAR PeekCoordinator finishMoveBack: 移回失败，保持现有分区不予重排以防误伤其他图标")
        }
    }

    private func abortToIdle(message: String) {
        NSLog("TIDYBAR PeekCoordinator abortToIdle: \(message)")
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        setPusherCollapsed(false)
        rehideTimer?.invalidate()
        rehideTimer = nil

        controller?.peekedItemID = nil
        currentPresentedItem = nil
        state = .idle
    }

    // MARK: - 销毁与锁屏取消

    public func cancelAndDrain() {
        fprint("PeekCoordinator: cancelAndDrain called, stack:\n\(Thread.callStackSymbols.prefix(6).joined(separator: "\n"))")
        rehideTimer?.invalidate()
        rehideTimer = nil
        if let dismissProxy {
            dismissProxy()
            controller?.peekedItemID = nil
            currentPresentedItem = nil
            state = .idle
            return
        }
        abortToIdle(message: "应用退出或系统锁屏，取消浮现状态")
    }
}
