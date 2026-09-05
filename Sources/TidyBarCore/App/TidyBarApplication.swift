import AppKit

/// 应用装配层：唯一持有 AppKit 生命周期依赖的地方。
/// 骨架阶段的目标是「能跑起来 + 诚实标注哪些能力尚未接通」，不假装已具备隐藏能力。
public final class TidyBarApplication: NSObject, NSApplicationDelegate {
    private var eventEngine: EventEngine?
    private var panelController: TidyBarPanelController?
    private var controller: TidyBarController?
    private var tickTimer: Timer?
    private var statusItem: NSStatusItem?
    /// 注销/关机/launchd 回收发来的信号不保证会走 applicationWillTerminate，显式挂信号源
    private var shutdown: GracefulShutdown?
    private var isExiting = false
    private let enumerator = BackgroundEnumerator()

    private let settingsStore: SettingsStoring
    private let services: SystemServices
    /// 用于量「启动到接管」这一段真实耗时（报告 §4.3 的 2s 预算）
    private let launchedAt = Date()

    /// 默认装配：读取器为 M0 已验证的辅助功能枚举（只读，安全）；
    /// 移动器仍是未验证占位，因此 capability 自动落到「收纳面板（降级）」，不会去动系统图标。
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
        // mover 仍是未验证占位——**读得到、点得动、但不搬动**，正是接管闸门关闭时的产品形态。
        let reader = AccessibilityMenuBarReader()
        return SystemServices(
            reader: reader,
            mover: UnverifiedMenuBarMover(),
            cursor: AppKitCursorReader(),
            accessibility: AppKitAccessibilityTrust(),
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
            journal: journal
        )
        let settings = settingsStore.load()
        let barController = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: settings.rehideDelay),
            settings: settings,
            store: settingsStore
        )
        self.controller = barController

        let panel = TidyBarPanelController(services: services)
        panel.onItemClick = { [weak barController, weak panel] item in
            guard let barController else { return }
            let outcome = barController.activate(itemID: item.id)
            // 代点失败必须有可见反馈：图标在面板里点不动又不说原因，是这类工具最常见的差评来源
            panel?.setActivationNotice(outcome.countsAsPressed ? nil : outcome.userReadable)
        }
        self.panelController = panel

        let events = EventEngine()
        events.onEvent = { [weak self, weak barController, weak panel] event in
            guard let self, let barController, let panel else { return }
            barController.handle(event: event)
            self.syncPanel(barController: barController, panel: panel)
        }
        events.start()
        self.eventEngine = events

        // 心跳只服务「自动重隐藏」判定，0.25s 足够顺滑且省电（报告 §4.3 空闲 CPU 目标）
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak barController, weak panel] _ in
            guard let barController else { return }
            if barController.tick() {
                panel?.hide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        statusItem = makeStatusItem(controller: barController)
        barController.start(scansSynchronously: false)

        // 冷启动全量枚举实测 ≈2.6s：同步做会击穿「启动到接管 2s」预算，
        // 还会让菜单栏在启动瞬间卡住，因此首扫交给后台调度器，结果回主线程落地。
        scheduleRefresh(reason: .userRequested)
        reportStartup(barController: barController)

        // 收尾信号：TERM=注销/关机，HUP=终端/launchd 回收，INT=Ctrl-C。
        // SIGKILL 不可捕获，那正是 LayoutJournal 要处理的场景，别把功劳记到这里。
        let shutdown = GracefulShutdown()
        shutdown.arm { [weak self] sig in
            let name = Self.signalName(sig)
            // 信号回调在专用队列上，碰 AppKit 与落盘一律回主线程
            DispatchQueue.main.async {
                self?.flushForExit(reason: "signal:\(name)")
                exit(0)
            }
        }
        self.shutdown = shutdown
    }

    private static func signalName(_ sig: Int32) -> String {
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
        eventEngine?.stop()
        tickTimer?.invalidate()
        controller?.flushForTermination()
        fprint("退出收尾完成｜原因=\(reason)｜半空拖拽已抬起、布局已落盘")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        flushForExit(reason: "NSApp.terminate")
    }

    /// 后台扫描一次，结果回主线程落地
    private func scheduleRefresh(reason: EnumerationCadence.Trigger) {
        guard let controller else { return }
        let reader = services.reader
        enumerator.request(
            reason: reason,
            scan: { reader.discoverItems() },
            apply: { [weak controller] items in
                controller?.applyScan(items)
                let elapsed = Date().timeIntervalSince(self.launchedAt)
                fprint(String(format: "首扫完成｜图标 %d 个｜距启动 %.2fs（预算 2s）", items.count, elapsed))
            }
        )
    }

    // MARK: - 面板同步

    private func syncPanel(barController: TidyBarController, panel: TidyBarPanelController) {
        let snapshot = barController.snapshot

        if snapshot.isRevealed {
            let hiddenItems = snapshot.items.filter { snapshot.layout.zone(of: $0.id) == .hidden }
            panel.show(
                items: hiddenItems,
                screen: services.screens.primaryScreen,
                anchorX: NSEvent.mouseLocation.x
            )
        } else {
            panel.hide()
        }
    }

    // MARK: - 本工具自己的菜单栏入口

    private func makeStatusItem(controller barController: TidyBarController) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "☰"
        let menu = NSMenu()

        let summary = NSMenuItem(
            title: "模式：\(barController.capability.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        if let reason = barController.capabilityReason {
            let note = NSMenuItem(title: "↳ \(reason)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "呼出隐藏区", action: #selector(revealHiddenArea), keyEquivalent: "")
        menu.addItem(withTitle: "刷新图标快照", action: #selector(refreshItems), keyEquivalent: "r")
        let demo = menu.addItem(withTitle: "演示模式（一键收起）", action: #selector(toggleDemoMode), keyEquivalent: "d")
        demo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TidyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        item.menu = menu
        return item
    }

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

    private func reportStartup(barController: TidyBarController) {
        let trusted = services.accessibility.isTrusted
        fprint("启动完成｜辅助功能权限 = \(trusted ? "已授予" : "未授予（走降级模式）")｜模式 = \(barController.capability.displayName)")
        let footprintMB = Double(ResourceProbe.residentMemoryBytes()) / 1_048_576
        fprint(String(format: "自检｜phys_footprint = %.1fMB（预算 40MB）｜线程数 = %d（个位数为健康）", footprintMB, ResourceProbe.threadCount()))
        if !trusted {
            // 首启向导（报告 B1）在 M1 落地；这里先把系统授权入口暴露给用户
            services.accessibility.requestTrust()
        }
    }
}
