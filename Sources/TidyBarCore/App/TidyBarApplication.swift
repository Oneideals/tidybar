import AppKit
import CoreGraphics

/// 应用装配层：唯一持有 AppKit 生命周期依赖的地方。
/// 骨架阶段的目标是「能跑起来 + 诚实标注哪些能力尚未接通」，不假装已具备隐藏能力。
@MainActor
public final class TidyBarApplication: NSObject, NSApplicationDelegate {
    private var eventEngine: EventEngine?
    private var panelController: TidyBarPanelController?
    private var controller: TidyBarController?
    private var tickTimer: Timer?
    private var ruleTimer: Timer?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var foldMenuItem: NSMenuItem?
    private var isMenuBarFolded: Bool { controller?.isMenuBarFolded ?? true }
    private var hasPerformedInitialFold = false
    private var alignmentScheduled = false
    private var layoutAdjustmentDepth = 0
    private var restoreSavedOrderRequested = false
    private var isReconcilingLayout = false
    private var arrangement: MenuBarArrangement?
    private var menuBarAccess: MenuBarAccessSession?
    private var clickRelay: MenuBarClickRelay?
    private var isRelayingClick = false
    private var isHoldingUnobservedMenu = false
    private var revealsAlwaysHiddenForClick = false
    private var lastCaptureAuthorization = false
    private var alignmentRequested = false
    private var terminationRequested = false
    private var lastDemoMode = false
    private var lastLayoutError: String?
    private var needsManualRealignment = false
    /// 分隔符：用户改边界时拖动它；折叠时由它自身扩展大跨度直接隐藏左侧全部收纳项
    private var dividerItems: [NSStatusItem] = []
    /// 存储各个分隔符对应在 NSStatusBarWindow.contentView 上的系统水平最小宽度约束（借鉴 Ice 项目机制）。
    /// AppKit 默认有 width == view.width + 16 的约束，导致即使 length=0 也会留下 16pt 幽灵空隙。
    /// 展开时将该约束设为 inactive 并强制 contentSize 为 0 宽，折叠时重新激活。
    private var dividerConstraints: [String: NSLayoutConstraint] = [:]
    /// 借鉴 Ice 的 10,000pt 推杆设计：超大跨度确保在多屏/超宽屏/高分屏下 100% 将隐藏项推到屏幕外。
    private static let expandedPushLength: CGFloat = 10_000
    private var searchUI: TidyBarSearchUI?
    /// 抽屉单项物理浮现协调器与幕布截图扫描器
    private var peekCoordinator: PeekCoordinator?
    private var proxyStatusItem: NSStatusItem?
    private var proxyPresentedItem: ManagedItem?
    private var captureSweep: CaptureSweep?
    private var isPusherCollapsedOverride = false
    /// 注销/关机/launchd 回收发来的信号不保证会走 applicationWillTerminate，显式挂信号源
    private var shutdown: GracefulShutdown?
    private var isExiting = false
    private var hotKey: GlobalHotKey?
    private var hotKeyNote = "未启用"
    private var settingsWindow: TidyBarSettingsWindowController?
    private var ruleEditor: RuleEditorWindowController?
    private let stylingController = MenuBarStylingController()
    private var wizard: FirstRunWizardController?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var rescanObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private let enumerator = BackgroundEnumerator()

    private let settingsStore: SettingsStoring
    private let services: SystemServices
    /// 用于量「启动到接管」这一段真实耗时（报告 §4.3 的 2s 预算）
    /// 分隔符字形：窄、可辨、不与常见状态项字形冲突
    private static let dividerGlyph = "│"
    private static let alwaysHiddenDividerGlyph = "┆"
    private let launchedAt = Date()

    /// 默认装配按机器与系统的验证记录选择移动器；实际权限会在扫描时刷新。
    public init(
        settingsStore: SettingsStoring = UserDefaultsSettingsStore(),
        services: SystemServices? = nil
    ) {
        self.settingsStore = settingsStore
        self.services = services ?? TidyBarApplication.defaultServices()
        super.init()
    }

    private static func defaultServices() -> SystemServices {
        // reader 自己就是点击转发的实现方（它才知道每个元素在 AX 树里的位置）。
        let reader = AccessibilityMenuBarReader()
        // 搬动图标与否由**已确认名单**决定，不是代码里的常量：名单空 → 走占位移动器，
        // 只读只点不搬；这台机器这个系统版本真跑过闸门并记录过 → 才换真实移动器。
        let gate = DragGateStore(url: AppPaths.dragGateFile).load()
        let confirmed = gate.allowsTakeover(
            os: MachineIdentity.osVersion(),
            machine: MachineIdentity.hardwareID()
        )
        let trust = AppKitAccessibilityTrust()
        return SystemServices(
            reader: reader,
            mover: confirmed
                ? AccessibilityMenuBarMover(
                    reader: reader,
                    cursor: AppKitCursorReader(),
                    poster: CGDragEventPoster(),
                    config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
                )
                : UnverifiedMenuBarMover(),
            cursor: AppKitCursorReader(),
            accessibility: trust,
            screens: AppKitScreenObserver(),
            activator: reader
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let journal = LayoutJournal(directory: AppPaths.journalDirectory)
        let engine = LayoutEngine(
            layout: journal.readCommittedLayout() ?? MenuBarLayout(),
            services: services,
            journal: journal,
            ledger: IdentityLedgerStore(url: AppPaths.identityLedgerFile)
        )
        engine.legacyBackupURL = AppPaths.supportDirectory()
            .appendingPathComponent("layout.committed.pre-ledger.json")
        let settings = settingsStore.load()
        let barController = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: settings.rehideDelay),
            settings: settings,
            store: settingsStore
        )
        barController.onToggleDividers = { [weak self] in
            self?.toggleDividers()
        }
        barController.areDividersPlaced = { [weak self] in
            !(self?.dividerItems.isEmpty ?? true)
        }
        barController.onToggleMenuBarFold = { [weak self] in
            self?.toggleMenuBarFold()
        }
        barController.isMenuBarFoldedQuery = { [weak self] in
            guard let self else { return false }
            return self.isMenuBarFolded
        }
        barController.onToggleDrawer = { [weak self] in
            self?.toggleDrawer()
        }
        barController.onSearchRequested = { [weak self] in
            self?.presentSearch()
        }
        barController.onRequestPhysicalArrangement = { [weak self] restoreOrder in
            guard let self else { return }
            self.endHeldMenuAccess()
            self.restoreSavedOrderRequested = self.restoreSavedOrderRequested || restoreOrder
            self.hasPerformedInitialFold = false
            self.lastLayoutError = nil
            self.setupDividers()
            self.applyMenuBarFoldState()
            self.scheduleAlignment()
        }
        self.controller = barController
        barController.onBeginLayoutAdjustment = { [weak self] in self?.beginLayoutAdjustment() ?? [] }
        barController.onEndLayoutAdjustment = { [weak self] in self?.endLayoutAdjustment() }

        let capturer = ScreenCaptureKitIconCapturer()
        let panel = TidyBarPanelController(services: services, capturer: capturer)
        lastCaptureAuthorization = capturer.isAuthorized
        let coordinator = PeekCoordinator(
            services: services,
            controller: barController,
            setPusherCollapsed: { [weak self] collapsed in
                self?.setPusherCollapsed(collapsed)
            },
            proxyClickRelay: { [weak self] item, button in
                _ = self?.requestProxyClick(item, button: button, unfold: false)
            },
            presentProxy: { [weak self] item, autoRightClick in
                self?.presentProxyItem(item: item, autoRightClick: autoRightClick)
            },
            dismissProxy: { [weak self] in
                self?.dismissProxyItem()
            }
        )
        self.peekCoordinator = coordinator

        let sweep = CaptureSweep(
            services: services,
            panelController: panel,
            setPusherCollapsed: { [weak self] collapsed in
                self?.setPusherCollapsed(collapsed)
            },
            toggleMinXProvider: { [weak self] in
                if let btn = self?.statusItem?.button?.window {
                    return btn.frame.minX
                }
                let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
                return screen.visibleFrame.maxX - 60
            },
            isBusyProvider: { [weak self, weak barController, weak coordinator] in
                self?.isRelayingClick == true ||
                self?.isReconcilingLayout == true ||
                barController?.isPhysicalLayoutBusy == true ||
                coordinator?.state != .idle
            }
        )
        self.captureSweep = sweep

        panel.onItemClick = { [weak self] item in
            self?.handleDrawerItemClick(item, autoRightClick: false)
        }
        panel.onRightClick = { [weak self] item in
            self?.handleDrawerItemClick(item, autoRightClick: true)
        }
        panel.onRequestCaptureAuthorization = { [weak self] in
            if capturer.isAuthorized { self?.scheduleAlignment() }
            else {
                capturer.requestAuthorization()
                self?.openScreenCaptureSettings()
            }
        }
        self.panelController = panel
        panel.onHoverChanged = { [weak self, weak barController] inside in
            guard self?.isRelayingClick == false, self?.isHoldingUnobservedMenu == false else { return }
            barController?.setInteractionActive(inside)
        }

        let search = TidyBarSearchUI()
        search.queryHandler = { [weak barController] query in barController?.search(query) ?? [] }
        search.activateHandler = { [weak self] item in
            self?.handleDrawerItemClick(item, autoRightClick: false)
            return .menuPresented
        }
        search.zoneLabel = { [weak barController] id in
            guard let zone = barController?.snapshot.layout.zone(of: id) else { return "未分类" }
            return TidyBarController.zoneLabel(zone)
        }
        search.imageProvider = { [weak panel] item in
            panel?.cachedImages(for: [item])[item.id]
        }
        self.searchUI = search

        barController.emptySpacePredicate = { [weak self, weak barController] location in
            guard let self, let barController else { return true }
            let screens = self.services.screens.screens
            guard let screen = screens.first(where: { $0.frame.contains(location) }) ?? self.services.screens.primaryScreen else {
                return false
            }
            return ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
                point: location,
                screen: screen,
                statusItems: barController.snapshot.items,
                ignoredItemIDs: barController.dividerIDs
            )
        }

        barController.onEmptyBarClick = { [weak self] in
            guard let self, let barController = self.controller else { return }
            let mouseLoc = NSEvent.mouseLocation
            // 仅当点击直接落在折叠按钮自身窗口内时排除（交由按钮自身 action 响应）
            if let toggleWindow = self.statusItem?.button?.window, toggleWindow.frame.contains(mouseLoc) {
                return
            }
            let screens = self.services.screens.screens
            if let screen = screens.first(where: { $0.frame.contains(mouseLoc) }) ?? self.services.screens.primaryScreen {
                guard ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
                    point: mouseLoc,
                    screen: screen,
                    statusItems: barController.snapshot.items,
                    ignoredItemIDs: barController.dividerIDs
                ) else {
                    return
                }
            }
            switch barController.settings.emptyBarClickAction {
            case .toggleFold:
                self.toggleMenuBarFold()
            case .toggleDrawer:
                self.toggleDrawer()
            }
        }
        barController.onScrollOrSwipe = { [weak self] in
            guard let self else { return }
            switch self.controller?.settings.scrollOrSwipeAction ?? .toggleFold {
            case .toggleFold:
                self.toggleMenuBarFold()
            case .toggleDrawer:
                self.toggleDrawer()
            }
        }

        let events = EventEngine()
        events.onEvent = { [weak self, weak barController] event in
            guard self?.isRelayingClick == false, self?.isHoldingUnobservedMenu == false else { return }
            barController?.handle(event: event)
        }
        events.onConcealRequest = { [weak self, weak barController, weak panel] in
            guard self?.isRelayingClick == false, self?.isHoldingUnobservedMenu == false else { return }
            if let panelWindow = panel?.panel, panelWindow.isVisible, panelWindow.frame.contains(NSEvent.mouseLocation) {
                return
            }
            barController?.conceal()
        }
        events.onMenuBarInteraction = { [weak self] in
            self?.peekCoordinator?.noteInteraction()
        }
        events.onManualLayoutChange = { [weak self] in
            guard let self, self.hasPerformedInitialFold,
                  self.controller?.isDemoMode == false else { return }
            self.enumerator.invalidatePendingResults()
            self.needsManualRealignment = true
            if self.layoutAdjustmentDepth > 0 || self.isRelayingClick {
                self.hasPerformedInitialFold = false
                self.arrangement?.cancel()
                self.clickRelay?.cancel()
                self.menuBarAccess?.cancel()
            }
            self.endHeldMenuAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.scheduleRefresh(reason: .userRequested)
            }
        }
        events.start()
        self.eventEngine = events

        // 菜单栏变化 → 重扫。这是 A7（新图标检测 <500ms）的前提，
        // 也是"空闲时没有任何周期任务"设计的另一半：平时零轮询，
        // 系统通知菜单栏变了才去扫，且经去抖合并。
        // 没有这一段时，新出现的图标要等用户手动刷新才被看见。
        rescanObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh(reason: .itemAppeared) } },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh(reason: .itemDisappeared) } },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    if let self, self.menuBarAccess != nil,
                       let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       active.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == active.processIdentifier {
                        if self.isHoldingUnobservedMenu {
                            self.menuBarAccess?.preventForegroundRestoration(cancelling: false)
                            self.endHeldMenuAccess()
                            self.controller?.conceal()
                        }
                        let deliveringClick = self.isRelayingClick && self.clickRelay?.hasSentClick == true
                        self.menuBarAccess?.preventForegroundRestoration(cancelling: !deliveringClick)
                        if !deliveringClick {
                            self.arrangement?.cancel()
                            self.clickRelay?.cancel()
                        }
                    }
                    self?.scheduleRefresh(reason: .frontmostAppChanged)
                }
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh(reason: .screenParametersChanged) } },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuBarAccess?.preventForegroundRestoration()
                    self?.endHeldMenuAccess()
                    self?.arrangement?.cancel()
                    self?.clickRelay?.cancel()
                    self?.scheduleRefresh(reason: .screenParametersChanged)
                }
            },
        ]
        services.screens.addObserver { [weak self] in
            DispatchQueue.main.async { self?.scheduleRefresh(reason: .screenParametersChanged) }
        }
        let sessions = DistributedNotificationCenter.default()
        sessionObservers = [
            sessions.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasPerformedInitialFold = false
                    self?.needsManualRealignment = false
                    self?.enumerator.invalidatePendingResults()
                    self?.peekCoordinator?.cancelAndDrain()
                    self?.arrangement?.cancel()
                    self?.clickRelay?.cancel()
                    self?.menuBarAccess?.cancel()
                    self?.endHeldMenuAccess()
                    self?.tickTimer?.invalidate()
                    self?.tickTimer = nil
                    self?.panelController?.hide()
                }
            },
            sessions.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isReconcilingLayout { self.alignmentRequested = true }
                    self.scheduleRefresh(reason: .screenParametersChanged)
                }
            },
            sessions.addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    self.captureSweep?.run(items: controller.drawerItems + controller.visibleItems) { [weak self] in
                        self?.settingsWindow?.refresh()
                    }
                }
            },
        ]

        let hotKey = GlobalHotKey { [weak self, weak barController] in
            guard let self, let barController else { return }
            self.endHeldMenuAccess()
            barController.handle(event: .init(trigger: .hotkey, location: NSEvent.mouseLocation))
            self.syncPanel(barController: barController, panel: panel)
            self.applyMenuBarFoldState()
        }
        if hotKey.register() {
            hotKeyNote = "⌥Space（已注册）"
            barController.confirmHotKeyTrigger()
        } else {
            hotKeyNote = "不可用：" + (hotKey.failureReason ?? "未知原因")
            barController.retireHotKeyTrigger(reason: hotKey.failureReason ?? "注册失败")
        }
        self.hotKey = hotKey

        // 内存压力时清掉位图缓存。缓存自己实现了 `purge`，但**从来没人调用它**，
        // 那"≤20MB"就只是单测里成立的一句声明。这里用 GCD 压力源：
        // 本 SDK 并没有 `NSApplication.didReceiveMemoryWarningNotification` 这个通知名（编译即报错），
        // 而 dispatch 源能在 warning/critical 真实级别上触发。
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        pressure.setEventHandler { [weak panel] in
            panel?.purgeBitmaps()
        }
        pressure.resume()
        memoryPressureSource = pressure

        // 面板绘制与收起排表都由**快照**驱动，而不是散落在各个调用点上。
        // 教训：先前把 scheduleAutoConceal 挂在事件回调里，自检一绕开事件直接 handle()
        // 就出现"展得开、再也收不回"——挂表时机绑在调用点上必然漏，绑在状态上不会。
        barController.onSnapshot = { [weak self, weak barController, weak panel] _ in
            guard let self, let barController, let panel, !self.terminationRequested else { return }
            self.syncPanel(barController: barController, panel: panel)
            self.applyMenuBarFoldState()
            self.stylingController.update(enabled: barController.settings.stylingEnabled, screen: self.services.screens.primaryScreen)
            if self.lastDemoMode != barController.isDemoMode {
                self.lastDemoMode = barController.isDemoMode
                self.scheduleAlignment()
            }
            // 每次交互都可能续期，收起点跟着重算
            self.scheduleAutoConceal(barController: barController, panel: panel)
            self.syncRuleMonitoring(barController)
            self.settingsWindow?.refresh()
            self.wizard?.refresh()
        }

        // 自动收起改用"只在展开时挂的一次性定时器"。
        //
        // 原来是一条常驻 0.25s repeating Timer：面板收起时它每 0.25 秒醒一次，
        // 去做一件必然返回 false 的判断。40 分钟就是约 9600 次无意义唤醒——
        // 空闲 CPU 超预算的头号嫌疑就是它，而不是什么深奥的系统行为。
        // 现在收起状态下**没有任何周期任务**，展开时才挂表，且挂的是"到点即收"的那一条。
        scheduleAutoConceal(barController: barController, panel: panel)
        stylingController.update(enabled: barController.settings.stylingEnabled, screen: services.screens.primaryScreen)

        // 预设 Preferred Position：推杆（separator）必须紧邻折叠按钮（toggle）左侧。
        // Preferred Position 从右向左度量，数值越大越靠左。推杆必须位于 togglePos + 1 处，
        // 确保推杆能撑开并将所有位于其左侧的隐藏图标正确推出屏幕左侧。
        if let togglePos = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Double {
            UserDefaults.standard.set(togglePos + 1, forKey: "NSStatusItem Preferred Position tidybar_separator")
            UserDefaults.standard.synchronize()
        } else if let togglePosInt = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Int {
            UserDefaults.standard.set(Double(togglePosInt) + 1.0, forKey: "NSStatusItem Preferred Position tidybar_separator")
            UserDefaults.standard.synchronize()
        } else {
            UserDefaults.standard.set(645, forKey: "NSStatusItem Preferred Position tidybar_toggle")
            UserDefaults.standard.set(655, forKey: "NSStatusItem Preferred Position tidybar_separator")
            UserDefaults.standard.synchronize()
        }

        statusItem = makeStatusItem(controller: barController)
        setupDividers()
        applyMenuBarFoldState()
        presentWizardIfNeeded(barController: barController)
        barController.start(scansSynchronously: false)

        // 冷启动全量枚举实测 ≈2.6s：同步做会击穿「启动到接管 2s」预算，
        // 还会让菜单栏在启动瞬间卡住，因此首扫交给后台调度器，结果回主线程落地。
        scheduleRefresh(reason: .userRequested)
        reportStartup(barController: barController)
        // 自检必须在**真 app 进程**里跑：探针 CLI 没有 NSApp 激活策略与完整 run loop，
        // 键盘焦点这类断言在它里面必然失败，测出来的是环境不等价而不是产品有 bug。
        // 启动时自动打开设置面板，方便用户查看与控制（支持 TIDYBAR_NO_WINDOW=1 静默后台启动）
        if ProcessInfo.processInfo.environment["TIDYBAR_NO_WINDOW"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }
        if ProcessInfo.processInfo.environment["TIDYBAR_SELFCHECK_CONCEAL"] == "1" {
            concealSelfCheck(barController: barController, panel: panel)
        }
        if ProcessInfo.processInfo.environment["TIDYBAR_SELFCHECK_SEARCH"] == "1" {
            searchSelfCheck(barController: barController)
        }
        if ProcessInfo.processInfo.environment["TIDYBAR_REVEAL_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak barController, weak panel] in
                guard let self, let barController, let panel else { return }
                barController.handle(event: .init(trigger: .dividerClick, location: NSEvent.mouseLocation))
                self.syncPanel(barController: barController, panel: panel)
            }
        }

        // 收尾信号：TERM=注销/关机，HUP=终端/launchd 回收，INT=Ctrl-C。
        // SIGKILL 不可捕获，那正是 LayoutJournal 要处理的场景，别把功劳记到这里。
        let shutdown = GracefulShutdown()
        shutdown.arm { @Sendable [weak self] sig in
            let name = Self.signalName(sig)
            // 信号回调在专用队列上，碰 AppKit 与落盘一律回主线程
            DispatchQueue.main.async {
                guard let self else { exit(0) }
                self.stopBeforeExit(reason: "signal:\(name)") { exit(0) }
            }
        }
        self.shutdown = shutdown
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !terminationRequested, !isReconcilingLayout else { return true }
        openSettings()
        return true
    }

    /// 按"剩余可见时间"挂一次性收起表；不需要收起时**不挂任何表**。
    private func scheduleAutoConceal(barController: TidyBarController, panel: TidyBarPanelController? = nil, duration: TimeInterval? = nil) {
        tickTimer?.invalidate()
        tickTimer = nil
        guard !barController.isPhysicalLayoutBusy, !isRelayingClick, !isHoldingUnobservedMenu,
              services.cursor.isSessionInteractive else { return }

        let timeout = duration ?? barController.remainingRevealTime
        guard let remaining = timeout, remaining > 0 else { return }
        let timer = Timer(timeInterval: max(0.05, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let barController = self.controller, self.services.cursor.isSessionInteractive else { return }
                if let panelWindow = self.panelController?.panel, panelWindow.isVisible, panelWindow.frame.contains(NSEvent.mouseLocation) {
                    barController.setInteractionActive(true)
                    return
                }
                if NSEvent.pressedMouseButtons != 0 {
                    barController.noteInteraction()
                    return
                }
                barController.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// 仅有启用的自动规则时才挂分钟级兜底；应用切换、唤醒和图标刷新会立即求值。
    private func syncRuleMonitoring(_ controller: TidyBarController) {
        guard controller.hasAutomaticRules else {
            ruleTimer?.invalidate()
            ruleTimer = nil
            return
        }
        guard ruleTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateAutomaticRules() }
        }
        let now = Date()
        timer.fireDate = now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        RunLoop.main.add(timer, forMode: .common)
        ruleTimer = timer
    }

    private func evaluateAutomaticRules() {
        guard !terminationRequested, !needsManualRealignment, !isRelayingClick, !isHoldingUnobservedMenu,
              services.cursor.isSessionInteractive else { return }
        controller?.evaluateRulesWithCurrentContext()
    }

    /// 自动收起自检（`TIDYBAR_SELFCHECK_CONCEAL=1`）。
    ///
    /// 为什么必须有它：改成"只在展开时挂一次性表"之后，空闲不挂表是想要的效果，
    /// 但如果我把挂表时机接错，症状是**面板再也收不起来**——一个更糟、却同样"省 CPU"的 bug。
    /// 光看空闲 CPU 下降无法区分这两种情况，所以必须正面验一次"展开→自行收起"。
    private func concealSelfCheck(barController: TidyBarController, panel: TidyBarPanelController) {
        let delay = barController.settings.rehideDelay
        barController.handle(event: .init(trigger: .dividerClick, location: NSEvent.mouseLocation))
        syncPanel(barController: barController, panel: panel)
        let opened = panel.isVisible
        let started = Date()
        var samples = 0
        var closedAt: TimeInterval?
        while closedAt == nil && Date().timeIntervalSince(started) < delay + 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            samples += 1
            if !panel.isVisible { closedAt = Date().timeIntervalSince(started) }
        }
        let line = "收起自检｜delay=\(delay)s 展开成功=\(opened ? "yes" : "no") 自行收起=\(closedAt.map { String(format: "%.1fs", $0) } ?? "未发生") 采样=\(samples) 次"
        fprint(line)
        print(line)
        exit(opened && closedAt != nil ? 0 : 1)
    }

    nonisolated private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGTERM: return "SIGTERM"
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        default: return "SIG\(sig)"
        }
    }

    /// 退出前收尾。正常终止与信号终止共用，且只允许执行一次——
    /// 重复执行会写出两份"已提交布局"，看起来无害，实则让日志里的退出原因不再唯一。
    private func flushForExit(reason: String) {
        guard !isExiting else { return }
        isExiting = true
        shutdown?.disarm()
        peekCoordinator?.cancelAndDrain()
        eventEngine?.stop()
        tickTimer?.invalidate()
        ruleTimer?.invalidate()
        sessionObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        sessionObservers.removeAll()
        if let proxy = proxyStatusItem {
            NSStatusBar.system.removeStatusItem(proxy)
            proxyStatusItem = nil
        }
        controller?.flushForTermination()
        endMenuBarAccess()
        fprint("退出收尾完成｜原因=\(reason)｜半空拖拽已抬起")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        flushForExit(reason: "NSApp.terminate")
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        stopBeforeExit(reason: "NSApp.terminate") { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func stopBeforeExit(reason: String, completion: @escaping @MainActor @Sendable () -> Void) {
        terminationRequested = true
        peekCoordinator?.cancelAndDrain()
        enumerator.invalidatePendingResults()
        controller?.setPhysicalLayoutBusy(true)
        arrangement?.cancel()
        clickRelay?.cancel()
        menuBarAccess?.cancel()
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            self?.flushForExit(reason: reason)
            completion()
        }
        let drain: @MainActor () -> Void = { [weak self] in
            let drainClicks: @MainActor () -> Void = { [weak self] in
                if let relay = self?.clickRelay { relay.cancelAndDrain(finish) }
                else { DispatchQueue.main.async(execute: finish) }
            }
            if let arrangement = self?.arrangement { arrangement.cancelAndDrain(drainClicks) }
            else { drainClicks() }
        }
        if let menuBarAccess { menuBarAccess.whenPrepared(drain) }
        else { drain() }
    }

    private func endMenuBarAccess() {
        let access = menuBarAccess
        menuBarAccess = nil
        access?.end()
    }

    /// 无法继续观测菜单时交还按钮操作权；只有用户主动离开或发起新操作才结束短菜单访问。
    private func endHeldMenuAccess() {
        guard isHoldingUnobservedMenu else { return }
        isHoldingUnobservedMenu = false
        revealsAlwaysHiddenForClick = false
        endMenuBarAccess()
        controller?.setInteractionActive(false)
        if alignmentRequested {
            alignmentRequested = false
            scheduleAlignment()
        }
    }

    /// 后台扫描一次，结果回主线程落地
    private func scheduleRefresh(reason: EnumerationCadence.Trigger, allowAlignment: Bool = true) {
        if reason == .screenParametersChanged {
            if isHoldingUnobservedMenu {
                menuBarAccess?.preventForegroundRestoration(cancelling: false)
                endHeldMenuAccess()
            }
            // 同一批 ID 在解锁、唤醒或换屏后可能已换位置，旧就绪状态不能沿用。
            hasPerformedInitialFold = false
            needsManualRealignment = false
            enumerator.invalidatePendingResults()
            if isReconcilingLayout { alignmentRequested = true; arrangement?.cancel(); menuBarAccess?.cancel() }
            if isRelayingClick { alignmentRequested = true; clickRelay?.cancel(); menuBarAccess?.cancel() }
        }
        guard controller != nil, !terminationRequested, !isReconcilingLayout, !isRelayingClick,
              !isHoldingUnobservedMenu, services.cursor.isSessionInteractive else { return }
        let captureAuthorized = panelController?.hasCaptureAuthorization == true
        if captureAuthorized && !lastCaptureAuthorization { scheduleAlignment() }
        lastCaptureAuthorization = captureAuthorized
        if reason == .screenParametersChanged { applyMenuBarFoldState() }
        let reader = services.reader
        let scanStarted = Date()
        enumerator.request(
            reason: reason,
            scan: { reader.discoverItems() },
            apply: { [weak self] items in
                fprint("重扫｜触发=" + reason.rawValue + "｜图标 " + String(items.count)
                     + "｜耗时 " + String(format: "%.0f", Date().timeIntervalSince(scanStarted) * 1000) + "ms")
                guard let self, let controller = self.controller,
                      !self.terminationRequested, !self.isReconcilingLayout, !self.isRelayingClick,
                      self.services.cursor.isSessionInteractive else { return }
                controller.layoutEngine.migrateLegacyLayoutIfNeeded(observed: items)
                if let outcome = controller.layoutEngine.lastMigration {
                    fprint("台账迁移｜老条目 \(outcome.migrated) 项，当场对上 \(outcome.matched) 项；旧布局已备份可回退")
                }
                let previousAssignments = controller.managedZoneAssignments
                let previousCapability = controller.capability
                let previousIDs = Set(controller.assignableItems.map(\.id))
                let currentIDs = Set(items.filter { !controller.owns($0) && !$0.isSystemOwned }.map(\.id))
                let hiddenIDs = Set(controller.snapshot.layout.items(in: .hidden) + controller.snapshot.layout.items(in: .alwaysHidden))
                let missingIDs = previousIDs.subtracting(currentIDs)
                let addedIDs = currentIDs.subtracting(previousIDs)
                let isMissingDueToFold = self.isMenuBarFolded && !missingIDs.isEmpty && missingIDs.isSubset(of: hiddenIDs)
                let genuineMissing = isMissingDueToFold ? Set<String>() : missingIDs
                let isInitialScan = previousIDs.isEmpty || !self.hasPerformedInitialFold
                let membershipChanged = !isInitialScan && (!addedIDs.isEmpty || !genuineMissing.isEmpty)
                if membershipChanged { self.hasPerformedInitialFold = false }
                controller.applyScan(items)
                let requiresAlignment = membershipChanged || previousAssignments != controller.managedZoneAssignments
                    || (previousCapability != controller.capability && controller.capability == .fullDrag)
                if requiresAlignment {
                    self.hasPerformedInitialFold = false
                    self.applyMenuBarFoldState()
                }
                self.syncDividerPositions(from: items)
                if self.needsManualRealignment, NSEvent.pressedMouseButtons == 0 {
                    self.needsManualRealignment = false
                    if !self.isMenuBarFolded {
                        controller.realignToDividers()
                    }
                }
                self.evaluateAutomaticRules()
                self.settingsWindow?.refresh()
                if self.isMenuBarFolded {
                    self.captureSweep?.run(items: controller.drawerItems + controller.visibleItems) { [weak self] in
                        self?.settingsWindow?.refresh()
                    }
                }
                let elapsed = Date().timeIntervalSince(self.launchedAt)
                fprint(String(format: "首扫完成｜图标 %d 个｜距启动 %.2fs（预算 2s）", items.count, elapsed))

                let isPartitioned = self.isCurrentLayoutCorrectlyPartitioned(from: items)
                if isPartitioned {
                    self.hasPerformedInitialFold = true
                    fprint("首扫判定：当前菜单栏物理布局已满足分区规则，直接维持折叠，无需启动拖拽重排")
                }

                if allowAlignment && !isPartitioned && (requiresAlignment || reason == .userRequested || isInitialScan) {
                    self.scheduleAlignment()
                }
            }
        )
    }

    // MARK: - 面板同步

    private func syncPanel(barController: TidyBarController, panel: TidyBarPanelController) {
        guard !barController.isPhysicalLayoutBusy, !isRelayingClick, services.cursor.isSessionInteractive else { panel.hide(); return }
        let snapshot = barController.snapshot

        if snapshot.isRevealed {
            let drawerItems = barController.drawerItems
            fprint("syncPanel: items=\(snapshot.items.count), drawerItems=\(drawerItems.count)")
            let mouseLoc = NSEvent.mouseLocation
            let currentScreen = services.screens.screens.first { $0.frame.contains(mouseLoc) } ?? services.screens.primaryScreen
            let anchor: CGFloat
            if let screen = currentScreen, screen.frame.contains(mouseLoc) {
                anchor = mouseLoc.x
            } else if let toggleMidX = statusItem?.button?.window?.frame.midX,
                      let currentScreen, currentScreen.frame.minX <= toggleMidX && toggleMidX <= currentScreen.frame.maxX {
                anchor = toggleMidX
            } else {
                anchor = currentScreen?.frame.midX ?? 800
            }
            panel.show(
                items: drawerItems,
                screen: currentScreen,
                anchorX: anchor
            )
        } else {
            panel.hide()
        }
    }

    @discardableResult
    private func requestProxyClick(
        _ item: ManagedItem,
        button: MenuBarClickRelay.Button,
        unfold: Bool = true,
        completionHandler: (@MainActor (ActivationOutcome) -> Void)? = nil
    ) -> ActivationOutcome {
        guard let controller, !terminationRequested, !isReconcilingLayout, !isRelayingClick,
              !controller.isPhysicalLayoutBusy else { return .busy }
        guard services.accessibility.isTrusted, services.cursor.isSessionInteractive else { return .interrupted }
        endHeldMenuAccess()
        let request = MenuBarClickRelay.Request(item: item, button: button, cursor: services.cursor)
        let returnToDrawer = controller.snapshot.isRevealed
        isRelayingClick = true
        revealsAlwaysHiddenForClick = controller.snapshot.layout.zone(of: item.id) == .alwaysHidden
        enumerator.invalidatePendingResults()
        tickTimer?.invalidate()
        tickTimer = nil
        if unfold {
            panelController?.hide()
            searchUI?.dismiss()
            controller.setMenuBarFolded(false)
            controller.setInteractionActive(true)
        }
        let relay = clickRelay ?? MenuBarClickRelay(reader: services.reader, cursor: services.cursor)
        clickRelay = relay
        let started = relay.start(request, screens: self.services.screens.screens,
            onActivation: { [weak self] outcome in
                guard self?.terminationRequested == false else { return }
                self?.controller?.reportActivation(itemID: item.id, outcome: outcome)
                if !unfold {
                    self?.peekCoordinator?.noteInteraction()
                }
            }, completion: { [weak self] outcome in
                guard let self, !self.terminationRequested else { return }
                if !outcome.countsAsPressed || outcome == .menuObservationUnavailable {
                    self.controller?.reportActivation(itemID: item.id, outcome: outcome)
                }
                if !unfold {
                    self.peekCoordinator?.noteInteraction()
                }
                self.finishProxyClick(outcome, returnToDrawer: returnToDrawer, unfold: unfold)
                completionHandler?(outcome)
            })
        if !started {
            self.finishProxyClick(.busy, returnToDrawer: returnToDrawer, unfold: unfold)
            completionHandler?(.busy)
        }
        return .queued
    }

    private func finishProxyClick(_ outcome: ActivationOutcome, returnToDrawer: Bool, unfold: Bool = true) {
        isRelayingClick = false
        if outcome == .menuObservationUnavailable {
            isHoldingUnobservedMenu = true
            controller?.setInteractionActive(true)
            statusItem?.button?.toolTip = outcome.userReadable
            return
        }
        revealsAlwaysHiddenForClick = false
        endMenuBarAccess()
        if unfold {
            controller?.setInteractionActive(false)
            if outcome == .menuPresented {
                controller?.conceal()
            } else if !outcome.countsAsPressed {
                controller?.conceal()
                let canFallbackToPeek = (outcome == .notInteractable || outcome == .itemNotFound) &&
                    (controller?.capability == .fullDrag) && (peekCoordinator?.state == .idle)
                if !canFallbackToPeek {
                    panelController?.setActivationNotice(outcome.userReadable)
                    if returnToDrawer && services.cursor.isSessionInteractive { controller?.toggleDrawer() }
                }
            } else {
                // 只确认发送，尚未观察到菜单时不宣称成功；留下展开的原生图标供直接操作。
                controller?.noteInteraction()
            }
            applyMenuBarFoldState()
            if alignmentRequested {
                alignmentRequested = false
                scheduleAlignment()
            } else { scheduleRefresh(reason: .userRequested, allowAlignment: false) }
        }
    }

    private func isTidyBarOwnItem(_ item: ManagedItem) -> Bool {
        controller?.owns(item) ?? (item.ownerBundleID == (Bundle.main.bundleIdentifier ?? "local.tidybar.app"))
    }

    // MARK: - 本工具自己的菜单栏入口

    private func makeStatusItem(controller barController: TidyBarController) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "tidybar_toggle"
        item.button?.title = isMenuBarFolded ? "◀" : "▶"
        item.button?.toolTip = "TidyBar：点击展开/折叠或打开抽屉，右键弹出菜单"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusMenu = makeStatusMenu(controller: barController)
        return item
    }

    private func makeStatusMenu(controller barController: TidyBarController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(
            title: barController.isPhysicalLayoutBusy ? "正在整理菜单栏…" : "模式：\(barController.capability.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        if let lastLayoutError {
            let note = NSMenuItem(title: lastLayoutError, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        if let reason = barController.capabilityReason {
            let note = NSMenuItem(title: "↳ \(reason)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let foldItem = NSMenuItem(
            title: isMenuBarFolded ? "展开菜单栏图标" : "折叠菜单栏图标",
            action: #selector(toggleMenuBarFold),
            keyEquivalent: ""
        )
        self.foldMenuItem = foldItem
        foldItem.isEnabled = true
        menu.addItem(foldItem)

        menu.addItem(withTitle: "呼出收纳抽屉", action: #selector(toggleDrawer), keyEquivalent: "")
        menu.addItem(withTitle: panelController?.hasCaptureAuthorization == true ? "刷新菜单栏缩略图" : "允许显示真实菜单栏图标…",
                     action: #selector(requestMenuBarIconCapture), keyEquivalent: "")
        // 分区分配先走菜单：跨区拖拽要等接管闸门开放，而"把某个图标收进隐藏区"
        // 这个意图本身不依赖拖拽，不必让它陪着闸门一起等着。
        menu.addItem(withTitle: "搜索图标…", action: #selector(presentSearch), keyEquivalent: "f")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: dividerItems.isEmpty ? "摆放分隔符（划定三个区）" : "收起分隔符",
                     action: #selector(toggleDividers), keyEquivalent: "")
        if !barController.pendingNewItems.isEmpty {
            menu.addItem(TidyBarMenuBuilder.newItemQuestions(
                controller: barController,
                target: self,
                answerSelector: #selector(answerNewItem(_:))
            ))
        }
        menu.addItem(
            TidyBarMenuBuilder.zoneAssignment(
                controller: barController,
                target: self,
                assignSelector: #selector(assignZone(_:))
            )
        )
        menu.addItem(
            TidyBarMenuBuilder.profilesMenu(
                controller: barController,
                target: self,
                applySelector: #selector(applyProfileFromMenu(_:)),
                saveSelector: #selector(saveProfilePrompt)
            )
        )
        menu.addItem(withTitle: "规则编辑器…", action: #selector(openRuleEditor), keyEquivalent: "")
        if !barController.settings.rules.isEmpty {
            let root = NSMenuItem(title: "编辑已有规则", action: nil, keyEquivalent: "")
            let rules = NSMenu()
            for rule in barController.settings.rules {
                let item = rules.addItem(withTitle: rule.name + (rule.isEvaluable ? "" : "（需选择目标）"),
                                         action: #selector(editRule(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = rule.id.uuidString
            }
            root.submenu = rules
            menu.addItem(root)
        }
        menu.addItem(
            TidyBarMenuBuilder.firstRunGuide(
                accessibilityGranted: services.accessibility.isTrusted,
                target: self,
                openSettingsSelector: #selector(openAccessibilitySettings),
                doneSelector: #selector(dismissGuide),
                skipSelector: #selector(dismissGuide)
            )
        )
        menu.addItem(withTitle: "刷新图标快照", action: #selector(refreshItems), keyEquivalent: "r")
        let demo = menu.addItem(withTitle: "演示模式（一键收起）", action: #selector(toggleDemoMode), keyEquivalent: "d")
        demo.state = barController.isDemoMode ? .on : .off
        demo.isEnabled = barController.isDemoMode || (barController.capability == .fullDrag && hasPerformedInitialFold)
        demo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TidyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        return menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        endHeldMenuAccess()
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        let isOptionClick = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        NSLog("TIDYBAR: statusItemClicked! right=\(isRightClick) opt=\(isOptionClick) folded=\(isMenuBarFolded)")
        if isRightClick {
            guard let controller else { return }
            let menu = makeStatusMenu(controller: controller)
            statusMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else if isOptionClick {
            // 按住 Option 点击打开收纳抽屉
            toggleDrawer()
        } else {
            // 单击：单一图标统一折叠/展开，点一下展开，再点一下收起
            toggleMenuBarFold()
        }
    }

    @objc public func toggleDrawer() {
        guard !isRelayingClick else { return }
        endHeldMenuAccess()
        if controller?.snapshot.isRevealed != true { panelController?.setActivationNotice(nil) }
        controller?.toggleDrawer()
    }

    private func handleDrawerItemClick(_ item: ManagedItem, autoRightClick: Bool) {
        guard !terminationRequested, let controller else { return }
        fprint("handleDrawerItemClick item=\(item.id) capability=\(controller.capability) autoRightClick=\(autoRightClick)")
        panelController?.hide()
        searchUI?.dismiss()
        endHeldMenuAccess()
        // 方案 A（虚拟代理图标模式）：点击抽屉里的图标，直接在长显（常显）区域瞬间呈现代理图标，零推杆折叠、零全展开
        if let peek = peekCoordinator {
            if case .presented = peek.state {
                peek.cancelAndDrain()
            }
            if peek.state == .idle {
                fprint("启动 PeekCoordinator 将图标直接显示在长显区域 item=\(item.id)")
                peek.peek(item: item, autoRightClick: autoRightClick)
                return
            }
        }
        // 降级兜底：若暂不具备浮现能力，走代理展开点击
        requestProxyClick(item, button: autoRightClick ? .secondary : .primary, unfold: true)
    }

    // MARK: - 常显区虚拟代理状态项（方案 A）

    private func presentProxyItem(item: ManagedItem, autoRightClick: Bool) -> CGRect? {
        fprint("presentProxyItem item=\(item.id) title=\(item.title)")
        if let togglePos = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Double {
            UserDefaults.standard.set(togglePos - 1.0, forKey: "NSStatusItem Preferred Position tidybar_proxy")
            UserDefaults.standard.synchronize()
        } else if let togglePosInt = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Int {
            UserDefaults.standard.set(Double(togglePosInt) - 1.0, forKey: "NSStatusItem Preferred Position tidybar_proxy")
            UserDefaults.standard.synchronize()
        } else {
            UserDefaults.standard.set(644.0, forKey: "NSStatusItem Preferred Position tidybar_proxy")
            UserDefaults.standard.synchronize()
        }

        let proxy: NSStatusItem
        if let existing = proxyStatusItem {
            proxy = existing
        } else {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            newItem.autosaveName = "tidybar_proxy"
            newItem.button?.target = self
            newItem.button?.action = #selector(proxyStatusItemClicked(_:))
            newItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.proxyStatusItem = newItem
            proxy = newItem
        }

        self.proxyPresentedItem = item

        var iconImg: NSImage?
        if let bitmap = panelController?.cachedImage(for: item) {
            let glyphHeight: CGFloat = 18
            let aspect = CGFloat(bitmap.width) / max(1, CGFloat(bitmap.height))
            let width = max(18, min(40, glyphHeight * aspect))
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = NSSize(width: width, height: glyphHeight)
            let img = NSImage(size: NSSize(width: width, height: glyphHeight))
            img.addRepresentation(rep)
            img.isTemplate = false
            iconImg = img
            proxy.length = width + 6
        } else if let bundleID = item.ownerBundleID,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            appIcon.size = NSSize(width: 18, height: 18)
            iconImg = appIcon
            proxy.length = 24
        }
        if let iconImg {
            proxy.button?.image = iconImg
            proxy.button?.imagePosition = .imageOnly
            proxy.button?.title = ""
        } else {
            proxy.button?.image = nil
            let title = !item.title.isEmpty ? item.title : (item.ownerBundleID ?? "App")
            proxy.button?.title = title
            proxy.button?.imagePosition = .noImage
            proxy.length = NSStatusItem.variableLength
        }
        proxy.button?.toolTip = !item.title.isEmpty ? item.title : (item.ownerBundleID ?? "App")
        proxy.button?.window?.ignoresMouseEvents = false
        proxy.isVisible = true

        if autoRightClick, let btn = proxy.button {
            DispatchQueue.main.async { [weak self] in
                self?.handleProxyItemRightClick(item: item, sender: btn)
            }
        }

        return proxy.button?.window?.frame
    }

    private func dismissProxyItem() {
        fprint("dismissProxyItem")
        proxyStatusItem?.isVisible = false
        proxyStatusItem?.length = 0
        proxyStatusItem?.button?.image = nil
        proxyStatusItem?.button?.title = ""
        proxyPresentedItem = nil
    }

    @objc private func proxyStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let item = proxyPresentedItem else { return }
        peekCoordinator?.noteInteraction()
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        fprint("proxyStatusItemClicked isRight=\(isRightClick) item=\(item.id)")
        if isRightClick {
            handleProxyItemRightClick(item: item, sender: sender)
        } else {
            handleProxyItemLeftClick(item: item)
        }
    }

    private func handleProxyItemLeftClick(item: ManagedItem) {
        peekCoordinator?.noteInteraction()
        var activated = false
        if let bundleID = item.ownerBundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate()
            activated = app.activationPolicy != .accessory
        }
        let outcome = services.activator?.activate(itemID: item.id) ?? (services.reader as? MenuBarActivating)?.activate(itemID: item.id) ?? .actionUnsupported
        if outcome.countsAsPressed {
            activated = true
        }
        if !activated, let btn = proxyStatusItem?.button {
            handleProxyItemRightClick(item: item, sender: btn)
        }
    }

    private func handleProxyItemRightClick(item: ManagedItem, sender: NSStatusBarButton) {
        peekCoordinator?.noteInteraction()
        let outcome = services.activator?.showMenu(itemID: item.id) ?? (services.reader as? MenuBarActivating)?.showMenu(itemID: item.id) ?? .actionUnsupported
        if !outcome.countsAsPressed {
            // 弹出优雅的操作菜单兜底
            let menu = NSMenu(title: item.title)
            let appName = !item.title.isEmpty ? item.title : (item.ownerBundleID ?? "应用")
            let openItem = NSMenuItem(title: "打开 \(appName)", action: #selector(openProxyAppFromMenu(_:)), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)

            let showDrawerItem = NSMenuItem(title: "在收纳抽屉中查看", action: #selector(showInDrawerFromProxy(_:)), keyEquivalent: "")
            showDrawerItem.target = self
            menu.addItem(showDrawerItem)

            menu.addItem(NSMenuItem.separator())
            let dismissItem = NSMenuItem(title: "收起图标", action: #selector(dismissProxyItemManually(_:)), keyEquivalent: "")
            dismissItem.target = self
            menu.addItem(dismissItem)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    @objc private func openProxyAppFromMenu(_ sender: NSMenuItem) {
        guard let item = proxyPresentedItem else { return }
        handleProxyItemLeftClick(item: item)
    }

    @objc private func showInDrawerFromProxy(_ sender: NSMenuItem) {
        peekCoordinator?.cancelAndDrain()
        toggleDrawer()
    }

    @objc private func dismissProxyItemManually(_ sender: NSMenuItem) {
        peekCoordinator?.cancelAndDrain()
    }

    public func setPusherCollapsed(_ collapsed: Bool) {
        fprint("setPusherCollapsed collapsed=\(collapsed) dividerCount=\(dividerItems.count)")
        isPusherCollapsedOverride = collapsed
        applyMenuBarFoldState()
    }

    /// 呼出搜索面板。
    ///
    /// 为什么还挂在 ☰ 菜单里而不是全局快捷键（报告 A8 的 ⌥Space）：
    /// `NSEvent.addGlobalMonitorForEvents` 只能**观察**按键、不能吞掉它，
    /// 用 ⌥Space 呼出的同时会把一个空格打进用户正在输入的文本框里——这比没有快捷键更糟。
    /// 真要全局热键必须走 RegisterEventHotKey（Carbon）或 CGEventTap 才能消费掉按键，
    /// 而这两条都还没在本项目里验证过，所以先不假装支持。
    @objc private func presentSearch() {
        endHeldMenuAccess()
        let targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        searchUI?.presentCentered(on: targetScreen)
    }

    private func searchSelfCheck(barController: TidyBarController) {
        guard let search = searchUI else { return }
        search.present(anchorX: NSEvent.mouseLocation.x, screenHeight: NSScreen.main?.frame.height ?? 900)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        // 断言写错过一次：文本框成为首响应者后，AppKit 会把**字段编辑器(NSText)**
            // 设为 firstResponder，所以只认 NSTextField 会把"其实成功了"判成失败。
            let responder = search.panel.firstResponder
            let focused = responder is NSTextField || responder is NSText
            let line = "搜索自检｜visible=\(search.panel.isVisible ? "yes" : "no") canBecomeKey=\(search.panel.canBecomeKey ? "yes" : "no") 输入框取得焦点=\(focused ? "yes" : "no") 结果行数=\(search.resultRowCount)"
            fprint(line)
            print(line)
            exit((search.panel.isVisible && focused) ? 0 : 1)
        }
    }

    // MARK: - 菜单栏原地折叠（Way 1）与分隔符控制

    @objc public func toggleMenuBarFold() {
        guard !isRelayingClick else { return }
        endHeldMenuAccess()
        NSLog("TIDYBAR: toggleMenuBarFold! now folded=\(isMenuBarFolded), will set to \(!isMenuBarFolded)")
        setMenuBarFolded(!isMenuBarFolded)
    }

    public func setMenuBarFolded(_ folded: Bool) {
        guard let controller else { return }
        if dividerItems.isEmpty {
            setupDividers()
        }
        NSLog("TIDYBAR: setMenuBarFolded to \(folded)")
        controller.setMenuBarFolded(folded)
        applyMenuBarFoldState()
        if !folded, panelController?.hasCaptureAuthorization == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, let panel = self.panelController else { return }
                let reader = self.services.reader
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    var live = reader.discoverItems()
                    Thread.sleep(forTimeInterval: 0.08)
                    let second = reader.discoverItems()
                    var maxDrift: CGFloat = 0
                    for item in second {
                        if let prev = live.first(where: { $0.id == item.id }) {
                            maxDrift = max(maxDrift, abs(item.frame.minX - prev.frame.minX))
                        }
                    }
                    if maxDrift > 1.5 {
                        Thread.sleep(forTimeInterval: 0.12)
                        live = reader.discoverItems()
                    } else {
                        live = second
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        panel.prewarmBitmaps(for: live.filter { $0.frame.width > 0 && $0.centerX > 0 }, isValid: { true }) { [weak self] in
                            self?.settingsWindow?.refresh()
                        }
                    }
                }
            }
        }
    }

    private func fetchHorizontalConstraint(for divider: NSStatusItem) -> NSLayoutConstraint? {
        guard let button = divider.button,
              let contentView = button.window?.contentView else { return nil }
        let constraints = contentView.constraintsAffectingLayout(for: .horizontal)
        return constraints.first(where: { $0.secondItem === button.superview })
    }

    private func applyMenuBarFoldState() {
        guard layoutAdjustmentDepth == 0 else { return }

        let separator = dividerItems.first { $0.autosaveName == "tidybar_separator" }
        let alwaysHiddenSeparator = dividerItems.first { $0.autosaveName == "tidybar_always_hidden_separator" }

        // 动态捕获可能延迟挂载的水平约束
        if let sep = separator, dividerConstraints["tidybar_separator"] == nil {
            dividerConstraints["tidybar_separator"] = fetchHorizontalConstraint(for: sep)
        }
        if let ahSep = alwaysHiddenSeparator, dividerConstraints["tidybar_always_hidden_separator"] == nil {
            dividerConstraints["tidybar_always_hidden_separator"] = fetchHorizontalConstraint(for: ahSep)
        }

        let permanentlyHidden = !(controller?.snapshot.layout.items(in: .alwaysHidden).isEmpty ?? true)
        let shouldShowAlwaysHidden = permanentlyHidden && !revealsAlwaysHiddenForClick
        let alwaysHiddenConstraint = dividerConstraints["tidybar_always_hidden_separator"]
        if shouldShowAlwaysHidden {
            alwaysHiddenConstraint?.isActive = true
            alwaysHiddenSeparator?.length = Self.expandedPushLength
            alwaysHiddenSeparator?.button?.window?.ignoresMouseEvents = true
        } else {
            alwaysHiddenSeparator?.length = 0
            alwaysHiddenConstraint?.isActive = false
            if let window = alwaysHiddenSeparator?.button?.window {
                window.setContentSize(CGSize(width: 0, height: window.frame.height))
                window.ignoresMouseEvents = true
            }
        }
        alwaysHiddenSeparator?.button?.title = Self.alwaysHiddenDividerGlyph
        alwaysHiddenSeparator?.button?.target = nil
        alwaysHiddenSeparator?.button?.action = nil

        let separatorConstraint = dividerConstraints["tidybar_separator"]
        let effectiveFolded = isMenuBarFolded && !isPusherCollapsedOverride
        if effectiveFolded {
            separatorConstraint?.isActive = true
            separator?.length = Self.expandedPushLength
            separator?.button?.window?.ignoresMouseEvents = true
        } else {
            separator?.length = 0
            separatorConstraint?.isActive = false
            if let window = separator?.button?.window {
                window.setContentSize(CGSize(width: 0, height: window.frame.height))
                window.ignoresMouseEvents = true
            }
        }
        separator?.button?.title = Self.dividerGlyph
        separator?.button?.target = nil
        separator?.button?.action = nil

        statusItem?.button?.title = isMenuBarFolded ? "◀" : "▶"
        statusItem?.button?.toolTip = lastLayoutError ?? "TidyBar：点击展开/折叠菜单栏，右键打开菜单"
        foldMenuItem?.title = isMenuBarFolded ? "展开菜单栏图标" : "折叠菜单栏图标"
    }

    /// 两个独立分界：普通展开只缩回右侧分隔符，左侧始终隐藏区仍保持遮挡。
    public func setupDividers() {
        guard dividerItems.isEmpty else { return }
        if let togglePos = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Double {
            UserDefaults.standard.set(togglePos + 1, forKey: "NSStatusItem Preferred Position tidybar_separator")
            UserDefaults.standard.synchronize()
        } else if let togglePosInt = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tidybar_toggle") as? Int {
            UserDefaults.standard.set(Double(togglePosInt) + 1.0, forKey: "NSStatusItem Preferred Position tidybar_separator")
            UserDefaults.standard.synchronize()
        }
        for (name, glyph) in [("tidybar_separator", Self.dividerGlyph),
                          ("tidybar_always_hidden_separator", Self.alwaysHiddenDividerGlyph)] {
            let divider = NSStatusBar.system.statusItem(withLength: 0)
            divider.autosaveName = name
            divider.button?.title = glyph
            divider.button?.target = nil
            divider.button?.action = nil
            divider.button?.window?.ignoresMouseEvents = true
            divider.button?.toolTip = "TidyBar 分区边界"
            if let constraint = fetchHorizontalConstraint(for: divider) {
                dividerConstraints[name] = constraint
            }
            dividerItems.append(divider)
        }
    }

    private func beginLayoutAdjustment() -> [ManagedItem] {
        guard controller?.capability == .fullDrag else { return services.reader.discoverItems() }
        expandDividersForAdjustment()
        let live = services.reader.discoverItems()
        syncDividerPositions(from: live)
        return live
    }

    private func expandDividersForAdjustment() {
        layoutAdjustmentDepth += 1
        if layoutAdjustmentDepth == 1 {
            setupDividers()
            let separator = dividerItems.first { $0.autosaveName == "tidybar_separator" }
            let alwaysHiddenSeparator = dividerItems.first { $0.autosaveName == "tidybar_always_hidden_separator" }
            dividerConstraints["tidybar_always_hidden_separator"]?.isActive = false
            alwaysHiddenSeparator?.length = 22
            if let window = alwaysHiddenSeparator?.button?.window {
                window.setContentSize(CGSize(width: 22, height: window.frame.height))
                window.ignoresMouseEvents = false
            }
            alwaysHiddenSeparator?.button?.title = Self.alwaysHiddenDividerGlyph

            dividerConstraints["tidybar_separator"]?.isActive = false
            separator?.length = 22
            if let window = separator?.button?.window {
                window.setContentSize(CGSize(width: 22, height: window.frame.height))
                window.ignoresMouseEvents = false
            }
            separator?.button?.title = Self.dividerGlyph
        }
    }

    private func endLayoutAdjustment() {
        guard layoutAdjustmentDepth > 0 else { return }
        layoutAdjustmentDepth -= 1
        if layoutAdjustmentDepth == 0 {
            applyMenuBarFoldState()
            if controller?.snapshot.isRevealed == true || controller?.snapshot.isMenuBarExpanded == true {
                controller?.noteInteraction()
            }
        }
    }

    private func scheduleAlignment(after delay: TimeInterval = 0.3) {
        guard !terminationRequested, !dividerItems.isEmpty, services.cursor.isSessionInteractive else { return }
        if isRelayingClick || isHoldingUnobservedMenu || peekCoordinator?.state != .idle { alignmentRequested = true; return }
        if isReconcilingLayout {
            alignmentRequested = true
            arrangement?.cancel()
            menuBarAccess?.cancel()
            return
        }
        guard !alignmentScheduled else { return }
        alignmentScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.alignmentScheduled = false
            guard !self.dividerItems.isEmpty else { return }
            self.executeFoldingByCalculatedZones()
        }
    }

    /// 摆出/收起分隔符
    @objc private func toggleDividers() {
        guard !isReconcilingLayout, !isRelayingClick, !terminationRequested else { return }
        endHeldMenuAccess()
        if dividerItems.isEmpty {
            setupDividers()
            alignDividerToVisibleBoundary()
            fprint("已摆出分隔符与折叠控制器")
        } else {
            hasPerformedInitialFold = false
            if controller?.isDemoMode == true { controller?.toggleDemoMode() }
            dividerItems.forEach { NSStatusBar.system.removeStatusItem($0) }
            dividerItems.removeAll()
            controller?.dividerCenters = (nil, nil)
            controller?.dividerIDs = []
            fprint("已收起分隔符")
        }
        controller?.refreshItems()
        if let items = controller?.snapshot.items {
            syncDividerPositions(from: items)
        }
        settingsWindow?.refresh()
    }

    /// 主线程只准备与展示状态；输入及落位复核在串行工作队列，避免阻塞自己的状态项。
    public func alignDividerToVisibleBoundary() {
        guard let controller, controller.capability == .fullDrag,
              !terminationRequested, !needsManualRealignment, let mover = services.mover else { return }
        if isRelayingClick || isHoldingUnobservedMenu || peekCoordinator?.state != .idle { alignmentRequested = true; return }
        guard services.cursor.isSessionInteractive else {
            lastLayoutError = "屏幕未解锁，已暂停菜单栏整理"
            return
        }
        guard services.cursor.userIdleTime >= 2, !services.cursor.isPrimaryButtonPressed, !services.cursor.isSecondaryButtonPressed else {
            lastLayoutError = "等待键鼠空闲后整理菜单栏"
            statusItem?.button?.toolTip = lastLayoutError
            scheduleAlignment(after: 2)
            return
        }
        if isReconcilingLayout { alignmentRequested = true; arrangement?.cancel(); menuBarAccess?.cancel(); return }
        guard !controller.isAwaitingRecovery else {
            lastLayoutError = "正在等待上次布局恢复所需的图标"
            return
        }

        // 预检：若当前物理布局已处于正确分区，绝不盲目缩回推杆或逐个搬移图标，直接保持折叠并标记就绪
        if !restoreSavedOrderRequested {
            let live = services.reader.discoverItems()
            if isCurrentLayoutCorrectlyPartitioned(from: live) {
                hasPerformedInitialFold = true
                lastLayoutError = nil
                controller.reportPhysicalLayout(.idle)
                applyMenuBarFoldState()
                fprint("整理预检：菜单栏已满足分区规则，无需缩回推杆与搬运图标")
                return
            }
        }

        isReconcilingLayout = true
        hasPerformedInitialFold = false
        lastLayoutError = nil
        enumerator.invalidatePendingResults()
        expandDividersForAdjustment()
        controller.setPhysicalLayoutBusy(true)
        guard let access = MenuBarAccessSession() else {
            isReconcilingLayout = false
            controller.setPhysicalLayoutBusy(false)
            let message = "请在当前桌面打开 TidyBar 后重试整理"
            lastLayoutError = message
            controller.reportPhysicalLayout(.failed(message))
            endLayoutAdjustment()
            return
        }
        menuBarAccess = access
        statusItem?.button?.toolTip = "正在整理菜单栏位置…"
        let owner = Bundle.main.bundleIdentifier ?? "local.tidybar.app"
        let controls = DividerGeometry.Controls(
            leftDivider: ManagedItem.stableID(ownerBundleID: owner, title: Self.alwaysHiddenDividerGlyph),
            rightDivider: ManagedItem.stableID(ownerBundleID: owner, title: Self.dividerGlyph),
            toggle: ManagedItem.stableID(ownerBundleID: owner, title: statusItem?.button?.title ?? "☰"))
        let wasDemo = controller.isDemoMode
        let runner = arrangement ?? MenuBarArrangement(reader: services.reader, mover: mover, cursor: services.cursor)
        arrangement = runner
        access.whenPrepared { [weak self] in
            guard let self, !self.terminationRequested else { return }
            guard !access.isCancelled, self.services.cursor.isSessionInteractive else {
                self.isReconcilingLayout = false
                controller.setPhysicalLayoutBusy(false)
                controller.reportPhysicalLayout(.failed("整理已暂停，点击菜单栏入口可重试"))
                let shouldRestoreSettings = self.settingsWindow?.window?.isVisible == true
                if shouldRestoreSettings {
                    self.menuBarAccess?.preventForegroundRestoration(cancelling: false)
                }
                self.endLayoutAdjustment()
                self.endMenuBarAccess()
                if shouldRestoreSettings {
                    self.settingsWindow?.showAgain()
                }
                if self.alignmentRequested {
                    self.alignmentRequested = false
                    self.scheduleAlignment()
                } else { self.scheduleRefresh(reason: .userRequested, allowAlignment: false) }
                return
            }
            runner.start(layout: controller.snapshot.layout, controls: controls,
                         expectedItems: Set(controller.assignableItems.map(\.id)), defaultZone: controller.settings.newItemZone,
                         screens: services.screens.screens,
                         restoreSavedOrder: self.restoreSavedOrderRequested || controller.settings.activeProfileName != nil) { [weak self] result in
                guard let self, let controller = self.controller, !self.terminationRequested else { return }
                self.enumerator.invalidatePendingResults()
                let finish: (Bool) -> Void = { [weak self] mayRetryAfterScan in
                    guard let self, !self.terminationRequested else { return }
                    self.isReconcilingLayout = false
                    controller.setPhysicalLayoutBusy(false)
                    let shouldRestoreSettings = self.settingsWindow?.window?.isVisible == true
                    if shouldRestoreSettings {
                        self.menuBarAccess?.preventForegroundRestoration(cancelling: false)
                    }
                    self.endLayoutAdjustment()
                    self.endMenuBarAccess()
                    if shouldRestoreSettings {
                        self.settingsWindow?.showAgain()
                    }
                    if self.alignmentRequested {
                        self.alignmentRequested = false
                        self.scheduleAlignment()
                    } else {
                        self.scheduleRefresh(reason: .userRequested, allowAlignment: mayRetryAfterScan)
                    }
                }
                switch result {
                case .success(let items):
                    controller.acceptArrangementResult(items)
                    self.syncDividerPositions(from: items)
                    self.hasPerformedInitialFold = true
                    self.restoreSavedOrderRequested = false
                    self.lastLayoutError = nil
                    let captured: () -> Void = {
                        guard !self.terminationRequested else { return }
                        let total = controller.drawerItems.count
                        let cached = self.panelController?.cachedImages(for: controller.drawerItems).count ?? 0
                        fprint("抽屉原样图标｜已捕获 \(cached)/\(total)｜屏幕录制权限=\(self.panelController?.hasCaptureAuthorization == true ? "已授予" : "未授予")")
                        finish(false)
                        guard self.hasPerformedInitialFold else {
                            controller.reportPhysicalLayout(.failed("菜单栏位置已改变，正在重新读取"))
                            return
                        }
                        fprint("物理分组完成，菜单栏折叠已就绪")
                        controller.reportPhysicalLayout(.completed)
                    }
                    if let panel = self.panelController {
                        panel.prewarmBitmaps(for: controller.drawerItems,
                            isValid: { [weak self] in
                                self?.terminationRequested == false && !access.isCancelled
                                    && self?.alignmentRequested == false && self?.services.cursor.isSessionInteractive == true
                            }, completion: captured)
                    } else { captured() }
                case .failure(let failure):
                    var mayRetryAfterScan = false
                    if case .cancelled = failure {} else {
                        self.lastLayoutError = failure.message
                        fprint(failure.message)
                        if case .moveFailed(_, .unsupportedOS) = failure { controller.layoutEngine.markDraggingUnsupported() }
                        if case .itemsChanged = failure { mayRetryAfterScan = true }
                        if wasDemo && controller.isDemoMode { controller.toggleDemoMode() }
                    }
                    finish(mayRetryAfterScan)
                    controller.reportPhysicalLayout(.failed("菜单栏整理未完成：\(failure.message)"))
                }
            }
        }
    }

    @objc public func executeFoldingByCalculatedZones() {
        alignDividerToVisibleBoundary()
    }

    private func isCurrentLayoutCorrectlyPartitioned(from items: [ManagedItem]) -> Bool {
        guard let controller else { return true }
        let owner = Bundle.main.bundleIdentifier ?? "local.tidybar.app"
        let controls = DividerGeometry.Controls(
            leftDivider: ManagedItem.stableID(ownerBundleID: owner, title: Self.alwaysHiddenDividerGlyph),
            rightDivider: ManagedItem.stableID(ownerBundleID: owner, title: Self.dividerGlyph),
            toggle: ManagedItem.stableID(ownerBundleID: owner, title: statusItem?.button?.title ?? "☰")
        )
        let exemptIDs: Set<String> = controller.peekedItemID.map { [$0] } ?? []
        if DividerGeometry.isCorrectlyPartitioned(
            items: items,
            layout: controller.snapshot.layout,
            controls: controls,
            defaultZone: controller.settings.newItemZone,
            exempt: exemptIDs
        ) {
            return true
        }

        // 真实运行时判定：推杆折叠或 0 宽态下，分隔符无可见字符或处于离屏推开状态
        // 此时以 toggle（折叠控制按钮）为物理界限：
        // - 所有常显项（.visible）及系统项必须位于 toggle 右侧（centerX > toggle.centerX）
        // - 所有收纳隐藏项（.hidden 及 .alwaysHidden）必须位于 toggle 左侧（centerX < toggle.centerX，包含负坐标离屏区）
        guard let toggle = items.first(where: {
            ($0.ownerBundleID == owner || $0.ownerBundleID == "local.tidybar.app") &&
            ($0.title == statusItem?.button?.title || $0.title == "◀" || $0.title == "▶" || $0.title == "☰" || $0.id == controls.toggle || $0.frame.width >= 16)
        }) else {
            return false
        }

        let defaultZone = controller.settings.newItemZone
        let layout = controller.snapshot.layout

        let nonTidyBarItems = items.filter {
            $0.ownerBundleID != owner && $0.ownerBundleID != "local.tidybar.app"
        }
        guard !nonTidyBarItems.isEmpty else { return true }

        for item in nonTidyBarItems {
            if exemptIDs.contains(item.id) { continue }
            let zone = item.isSystemOwned ? .visible : (layout.zone(of: item.id) ?? defaultZone)
            switch zone {
            case .visible:
                if item.centerX <= toggle.centerX {
                    return false
                }
            case .hidden, .alwaysHidden:
                if item.centerX >= toggle.centerX {
                    return false
                }
                if self.isMenuBarFolded && item.centerX > 0 {
                    return false
                }
            }
        }

        return true
    }

    /// 只更新真实边界。后台扫描不应把暂时的物理位置覆盖成用户分配。
    private func syncDividerPositions(from items: [ManagedItem]) {
        let markers = items.filter {
            isTidyBarOwnItem($0) && ($0.title == Self.dividerGlyph || $0.title == Self.alwaysHiddenDividerGlyph)
        }.sorted { $0.centerX < $1.centerX }
        controller?.dividerIDs = Set(markers.map(\.id))
        if markers.count == 2 {
            controller?.dividerCenters = (markers[0].centerX, markers[1].centerX)
        } else if dividerItems.count == 2 {
            let edges = dividerItems.compactMap { $0.button?.window?.frame.maxX }.sorted()
            controller?.dividerCenters = edges.count == 2 ? (edges[0] - 4, edges[1] - 4) : (nil, nil)
        } else {
            controller?.dividerCenters = (nil, nil)
        }
    }

    @objc public func openSettings() {
        guard !terminationRequested else { return }
        endHeldMenuAccess()
        if controller?.snapshot.items.isEmpty ?? true {
            controller?.refreshItems()
        }
        if settingsWindow == nil {
            settingsWindow = TidyBarSettingsWindowController(controller: barControllerProxy, hotKeyDescription: hotKeyNote)
        }
        // 将截图缓存接入设置面板，确保图标风格与菜单栏/抽屉一致
        settingsWindow?.imageProvider = { [weak self] item in
            self?.panelController?.cachedImages(for: [item])[item.id]
        }
        if let controller {
            let allItems = controller.drawerItems + controller.visibleItems
            self.panelController?.requestMissingBitmaps(for: controller.visibleItems) { [weak self] in
                self?.settingsWindow?.refresh()
            }
            if self.isMenuBarFolded {
                self.captureSweep?.run(items: allItems) { [weak self] in
                    self?.settingsWindow?.refresh()
                }
            } else {
                let reader = self.services.reader
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let live = reader.discoverItems()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let panel = self.panelController else { return }
                        panel.prewarmBitmaps(for: live.filter { $0.frame.width > 0 && $0.centerX > 0 }, isValid: { true }) { [weak self] in
                            self?.settingsWindow?.refresh()
                        }
                    }
                }
            }
        }
        settingsWindow?.showAgain()
    }

    @objc private func answerNewItem(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ZoneAssignmentRequest, let controller else { return }
        controller.answerNewItem(request.itemID, zone: request.zone)
    }

    /// 首启向导：三步、可跳过；完成状态是安全落地的（`AppSettings` 已改成逐字段解码）。
    private func presentWizardIfNeeded(barController: TidyBarController) {
        guard !barController.settings.hasCompletedFirstRunGuide, wizard == nil else { return }
        let wizard = FirstRunWizardController(controller: barController) { [weak self, weak barController] in
            barController?.update { $0.hasCompletedFirstRunGuide = true }
            self?.wizard = nil
        }
        self.wizard = wizard
        wizard.showWindow(nil)
        wizard.window?.makeKeyAndOrderFront(nil)
    }

    private var barControllerProxy: TidyBarController { controller! }

    /// 分区分配：只改归属（布局意图），不搬动系统图标。
    @objc private func assignZone(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ZoneAssignmentRequest, let controller else { return }
        controller.reassignZone(request.itemID, to: request.zone)
    }

    @objc private func openAccessibilitySettings() {
        services.accessibility.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestMenuBarIconCapture() {
        endHeldMenuAccess()
        if panelController?.hasCaptureAuthorization == true { scheduleAlignment() }
        else {
            ScreenCaptureKitIconCapturer().requestAuthorization()
            openScreenCaptureSettings()
        }
    }

    /// 引导完成/跳过：当前只收起子菜单。刻意**不往 AppSettings 加字段**——
    /// 它是合成 Codable，加一个存储字段会让老用户已存的设置解码失败并被静默重置，
    /// 那比"引导每次都还在"严重得多。等有了迁移机制（报告 P1-C）再持久化。
    @objc private func dismissGuide() {}

    @objc private func revealHiddenArea() {
        controller?.handle(event: .init(trigger: .dividerClick, location: NSEvent.mouseLocation))
    }

    @objc private func refreshItems() {
        // 走调度器而不是同步扫：连点两下不应排两个 2.6s 的全量扫描
        scheduleRefresh(reason: .userRequested)
    }

    @objc private func toggleDemoMode() {
        controller?.toggleDemoMode()
    }

    @objc private func applyProfileFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let controller else { return }
        guard controller.applyProfile(named: name) else {
            fprint("未完成布局档案「\(name)」，请在设置中查看原因")
            return
        }
        fprint("已切换到布局档案「\(name)」")
    }

    @objc private func saveProfilePrompt() {
        guard let controller else { return }
        let alert = NSAlert()
        alert.messageText = "另存为布局档案"
        alert.informativeText = "请输入新布局档案的名称："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "例如：工作模式"
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = raw.isEmpty ? "未命名档案" : raw
            controller.saveProfile(named: name)
            fprint("已保存布局档案「\(name)」")
        }
    }

    @objc private func openRuleEditor() {
        presentRuleEditor(editing: nil)
    }

    @objc private func editRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let rule = controller?.settings.rules.first(where: { $0.id.uuidString == id }) else { return }
        presentRuleEditor(editing: rule)
    }

    private func presentRuleEditor(editing existing: DisplayRule?) {
        guard let controller else { return }
        let editor = RuleEditorWindowController(controller: controller, editing: existing) { [weak self] newRule in
            controller.update {
                if let index = $0.rules.firstIndex(where: { $0.id == newRule.id }) { $0.rules[index] = newRule }
                else { $0.rules.append(newRule) }
            }
            fprint("已保存规则「\(newRule.name)」")
            self?.evaluateAutomaticRules()
        }
        self.ruleEditor = editor
        editor.showWindow(self)
        editor.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reportStartup(barController: TidyBarController) {
        let trusted = services.accessibility.isTrusted
        fprint("启动完成｜辅助功能权限 = \(trusted ? "已授予" : "未授予（走降级模式）")｜模式 = \(barController.capability.displayName)")
        fprint("屏幕录制权限 = \(panelController?.hasCaptureAuthorization == true ? "已授予" : "未授予")")
        let footprintMB = Double(ResourceProbe.residentMemoryBytes()) / 1_048_576
        fprint(String(format: "自检｜phys_footprint = %.1fMB（预算 40MB）｜线程数 = %d（个位数为健康）", footprintMB, ResourceProbe.threadCount()))
        if !trusted {
            // 首启向导（报告 B1）在 M1 落地；这里先把系统授权入口暴露给用户
            services.accessibility.requestTrust()
        }
    }
}
