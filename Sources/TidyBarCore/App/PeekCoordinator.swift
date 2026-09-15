import AppKit
import CoreGraphics

/// 抽屉单项物理浮现协调器（状态机）。
///
/// 核心突破：
/// 不使用任何视觉覆盖遮罩，而是在幕布窗口掩护下，将抽屉中被点击的图标 X
/// 物理拖到 TidyBar 按钮右侧；随后撤去幕布并将推杆重新撑开至 10,000pt。
/// 此时所有其他收纳项均被推到屏外，只有 X 单独且真实地浮现在菜单栏。
/// 原生点击、右键菜单、光标悬停无缝兼容。
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
    private let makeSession: () -> MenuBarAccessSession?
    private let curtainFactory: (CGFloat) -> CurtainWindow
    private let setPusherCollapsed: (Bool) -> Void
    private let proxyClickRelay: (ManagedItem, MenuBarClickRelay.Button) -> Void

    private var activeCurtain: CurtainWindow?
    private var watchdogTimer: Timer?
    private var rehideTimer: Timer?
    private var lastInteractionAt: Date = Date()
    private var currentPresentedItem: ManagedItem?

    private let queue = DispatchQueue(label: "local.tidybar.peek-coordinator", qos: .userInitiated)

    init(
        services: SystemServices,
        controller: TidyBarController,
        makeSession: @escaping () -> MenuBarAccessSession?,
        curtainFactory: @escaping (CGFloat) -> CurtainWindow,
        setPusherCollapsed: @escaping (Bool) -> Void,
        proxyClickRelay: @escaping (ManagedItem, MenuBarClickRelay.Button) -> Void
    ) {
        self.services = services
        self.controller = controller
        self.makeSession = makeSession
        self.curtainFactory = curtainFactory
        self.setPusherCollapsed = setPusherCollapsed
        self.proxyClickRelay = proxyClickRelay
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

        state = .movingOut(itemID: item.id)
        controller?.peekedItemID = item.id
        lastInteractionAt = Date()

        raiseCurtainAndCollapsePusher { [weak self] curtain in
            guard let self, case .movingOut(let itemID) = self.state, itemID == item.id else { return }
            self.executeMoveOut(item: item, autoRightClick: autoRightClick)
        }
    }

    private func executeMoveOut(item: ManagedItem, autoRightClick: Bool) {
        guard let session = makeSession() else {
            abortToIdle(message: "无法获取菜单栏访问会话")
            return
        }

        session.whenPrepared { [weak self] in
            guard let self, case .movingOut(let itemID) = self.state, itemID == item.id else {
                session.cancel()
                return
            }

            let reader = self.services.reader
            let mover = self.services.mover
            let ownsItem: (ManagedItem) -> Bool = { [weak self] cand in
                self?.controller?.owns(cand) ?? false
            }

            self.queue.async { [weak self] in
                guard let self else { return }
                let live = reader.discoverItems()
                let target = live.first { cand in
                    guard cand.frame.width > 0, cand.centerX > 0 else { return false }
                    if cand.id == item.id { return true }
                    if let ob = item.ownerBundleID, ob == cand.ownerBundleID {
                        if !item.title.isEmpty && cand.title == item.title { return true }
                        if item.ordinalInOwner == cand.ordinalInOwner { return true }
                    }
                    return false
                }
                guard let target else {
                    NSLog("TIDYBAR PeekCoordinator: 未在菜单栏找到目标图标 item=\(item.id) title=\(item.title) liveCount=\(live.count)")
                    DispatchQueue.main.async { self.abortToIdle(message: "未在菜单栏找到目标图标") }
                    return
                }

                // 查找 TidyBar 切换按钮
                let toggle = live.first {
                    ownsItem($0) && $0.frame.width <= 32 && $0.centerX > 0
                }
                guard let toggle else {
                    NSLog("TIDYBAR PeekCoordinator: 未找到控制按钮锚点 liveCount=\(live.count)")
                    DispatchQueue.main.async { self.abortToIdle(message: "未找到控制按钮锚点") }
                    return
                }

                // 目标落点：拖到切换按钮右侧紧贴常显区
                let dropTargetX = toggle.frame.maxX + target.frame.width / 2 + 4
                NSLog("TIDYBAR PeekCoordinator: executeMoveOut target=\(target.id) currentX=\(target.centerX) dropTargetX=\(dropTargetX) toggleX=\(toggle.centerX)")

                // 关键修复：在投递 ⌘ 拖拽事件前撤除幕布，确保 AXUIElementCopyElementAtPosition 能直接命中真实图标，
                // 彻底消除由于遮罩窗口覆盖导致 mover.move 抛出 sourceNotInteractable 失败的问题。
                DispatchQueue.main.sync {
                    self.dismissCurtain()
                }

                guard let mover else {
                    DispatchQueue.main.async { self.abortToIdle(message: "无可用移动器") }
                    return
                }

                do {
                    _ = try mover.move(itemID: target.id, toX: dropTargetX)
                } catch {
                    NSLog("TIDYBAR PeekCoordinator: 物理移出失败：\(error)")
                    DispatchQueue.main.async { self.abortToIdle(message: "物理移出失败：\(error)") }
                    return
                }

                // 验证落点：X 必须位于按钮右侧
                let afterMove = reader.discoverItems()
                guard let verified = afterMove.first(where: { $0.id == target.id && $0.centerX > toggle.centerX }) else {
                    NSLog("TIDYBAR PeekCoordinator: 落点校验未通过")
                    DispatchQueue.main.async { self.abortToIdle(message: "落点校验未通过") }
                    return
                }

                NSLog("TIDYBAR PeekCoordinator: 移出成功 verifiedX=\(verified.centerX)")
                DispatchQueue.main.async {
                    self.finishMoveOut(verifiedItem: verified, autoRightClick: autoRightClick)
                }
            }
        }
    }

    private func finishMoveOut(verifiedItem: ManagedItem, autoRightClick: Bool) {
        guard case .movingOut = state else { return }

        // 撑回推杆，隐藏所有其他收纳项
        setPusherCollapsed(false)
        dismissCurtain()

        currentPresentedItem = verifiedItem
        controller?.updateItemFrame(id: verifiedItem.id, frame: verifiedItem.frame)
        state = .presented(itemID: verifiedItem.id)

        // 光标平滑吸附至目标图标物理中心
        let primaryHeight = services.screens.primaryScreen?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        let cgPoint = CGPoint(x: verifiedItem.centerX, y: primaryHeight - verifiedItem.frame.midY)
        CGWarpMouseCursorPosition(cgPoint)

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

    private func checkRehideCondition(item: ManagedItem) {
        guard case .presented(let itemID) = state, itemID == item.id else {
            rehideTimer?.invalidate()
            rehideTimer = nil
            return
        }

        let isPresented = services.reader.isMenuPresented(for: item)
        let isMouseDown = NSEvent.pressedMouseButtons != 0
        let mouseLoc = NSEvent.mouseLocation
        let delay = controller?.settings.rehideDelay ?? 6.0

        let shouldRehide = RehidePolicy.shouldRehide(
            now: Date(),
            lastInteractionAt: lastInteractionAt,
            rehideDelay: delay,
            isMenuPresented: isPresented,
            isMouseDown: isMouseDown,
            cursorLocation: mouseLoc,
            itemFrame: item.frame
        )

        if shouldRehide {
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

        state = .movingBack(itemID: item.id)

        raiseCurtainAndCollapsePusher { [weak self] curtain in
            guard let self, case .movingBack(let itemID) = self.state, itemID == item.id else { return }
            self.executeMoveBack(item: item)
        }
    }

    private func executeMoveBack(item: ManagedItem) {
        guard let session = makeSession() else {
            finishMoveBack(success: false)
            return
        }

        session.whenPrepared { [weak self] in
            guard let self, case .movingBack(let itemID) = self.state, itemID == item.id else {
                session.cancel()
                return
            }

            let reader = self.services.reader
            let mover = self.services.mover
            let ownsItem: (ManagedItem) -> Bool = { [weak self] cand in
                self?.controller?.owns(cand) ?? false
            }

            self.queue.async { [weak self] in
                guard let self else { return }
                let live = reader.discoverItems()
                let target = live.first { cand in
                    guard cand.frame.width > 0, cand.centerX > 0 else { return false }
                    if cand.id == item.id { return true }
                    if let ob = item.ownerBundleID, ob == cand.ownerBundleID {
                        if !item.title.isEmpty && cand.title == item.title { return true }
                        if item.ordinalInOwner == cand.ordinalInOwner { return true }
                    }
                    return false
                }
                guard let target else {
                    NSLog("TIDYBAR PeekCoordinator: executeMoveBack 未在菜单栏找到目标图标 item=\(item.id)")
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

                DispatchQueue.main.sync {
                    self.dismissCurtain()
                }

                guard let mover else {
                    DispatchQueue.main.async { self.finishMoveBack(success: false) }
                    return
                }

                do {
                    _ = try mover.move(itemID: target.id, toX: dropTargetX)
                } catch {
                    DispatchQueue.main.async { self.finishMoveBack(success: false) }
                    return
                }

                DispatchQueue.main.async {
                    self.finishMoveBack(success: true)
                }
            }
        }
    }

    private func finishMoveBack(success: Bool) {
        setPusherCollapsed(false)
        dismissCurtain()

        controller?.peekedItemID = nil
        currentPresentedItem = nil
        state = .idle

        if !success {
            controller?.realignToDividers()
        }
    }

    // MARK: - 幕布与看门狗管理

    private func raiseCurtainAndCollapsePusher(completion: @escaping (CurtainWindow) -> Void) {
        dismissCurtain()

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let toggleX = controller?.snapshot.items.first(where: { controller?.owns($0) ?? false && $0.frame.width <= 32 })?.frame.minX
            ?? (screen.visibleFrame.maxX - 60)

        let curtain = curtainFactory(toggleX)
        self.activeCurtain = curtain
        curtain.orderFrontRegardless()

        // 升起幕布后，将推杆归零（收起推杆，让隐藏项回到屏幕）
        setPusherCollapsed(true)

        // 挂 3 秒硬看门狗：任何步骤超时均强制撑回推杆并撤下幕布
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.abortToIdle(message: "幕布或移动操作超时（看门狗触发）")
            }
        }

        // 等待 60ms 布局消化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            completion(curtain)
        }
    }

    private func dismissCurtain() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        activeCurtain?.orderOut(nil)
        activeCurtain = nil
    }

    private func abortToIdle(message: String) {
        NSLog("TIDYBAR PeekCoordinator abortToIdle: \(message)")
        setPusherCollapsed(false)
        dismissCurtain()
        rehideTimer?.invalidate()
        rehideTimer = nil

        controller?.peekedItemID = nil
        currentPresentedItem = nil
        state = .idle
    }

    // MARK: - 销毁与锁屏取消

    public func cancelAndDrain() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        abortToIdle(message: "应用退出或系统锁屏，取消浮现状态")
    }
}
