import AppKit

/// 应用装配层：唯一持有 AppKit 生命周期依赖的地方。
/// 骨架阶段的目标是「能跑起来 + 诚实标注哪些能力尚未接通」，不假装已具备隐藏能力。
public final class TidyBarApplication: NSObject, NSApplicationDelegate {
    private var eventEngine: EventEngine?
    private var panelController: TidyBarPanelController?
    private var controller: TidyBarController?
    private var tickTimer: Timer?
    private var statusItem: NSStatusItem?
    /// 两条分隔符（报告 A2）。它们同样是**我们自己的图标**：用户改边界时拖的是它们，
    /// 不需要为了挪一条线去搬动别人的图标。位置只从现场读回，不自记坐标。
    private var dividerItems: [NSStatusItem] = []
    private var searchUI: TidyBarSearchUI?
    /// 注销/关机/launchd 回收发来的信号不保证会走 applicationWillTerminate，显式挂信号源
    private var shutdown: GracefulShutdown?
    private var isExiting = false
    private var hotKey: GlobalHotKey?
    private var hotKeyNote = "未启用"
    private var settingsWindow: TidyBarSettingsWindowController?
    private var wizard: FirstRunWizardController?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var rescanObservers: [NSObjectProtocol] = []
    private let enumerator = BackgroundEnumerator()

    private let settingsStore: SettingsStoring
    private let services: SystemServices
    /// 用于量「启动到接管」这一段真实耗时（报告 §4.3 的 2s 预算）
    /// 分隔符字形：窄、可辨、不与常见状态项字形冲突
    private static let dividerGlyph = "│"
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
        let reader = AccessibilityMenuBarReader()
        // 搬动图标与否由**已确认名单**决定，不是代码里的常量：名单空 → 走占位移动器，
        // 只读只点不搬；这台机器这个系统版本真跑过闸门并记录过 → 才换真实移动器。
        let gate = DragGateStore(url: AppPaths.dragGateFile).load()
        let confirmed = gate.allowsTakeover(
            os: MachineIdentity.osVersion(),
            machine: MachineIdentity.hardwareID()
        )
        return SystemServices(
            reader: reader,
            mover: confirmed
                ? AccessibilityMenuBarMover(
                    reader: reader,
                    cursor: AppKitCursorReader(),
                    poster: CGDragEventPoster(primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0),
                    config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
                )
                : UnverifiedMenuBarMover(),
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
        self.controller = barController

        let panel = TidyBarPanelController(services: services)
        panel.onItemClick = { [weak barController, weak panel] item in
            guard let barController else { return }
            let outcome = barController.activate(itemID: item.id)
            // 代点失败必须有可见反馈：图标在面板里点不动又不说原因，是这类工具最常见的差评来源
            panel?.setActivationNotice(outcome.countsAsPressed ? nil : outcome.userReadable)
        }
        self.panelController = panel

        let search = TidyBarSearchUI()
        search.queryHandler = { [weak barController] query in barController?.search(query) ?? [] }
        search.activateHandler = { [weak barController] item in
            barController?.activate(itemID: item.id) ?? .actionUnsupported
        }
        search.zoneLabel = { [weak barController] id in
            guard let zone = barController?.snapshot.layout.zone(of: id) else { return "未分类" }
            return TidyBarController.zoneLabel(zone)
        }
        self.searchUI = search

        let events = EventEngine()
        events.onEvent = { [weak self, weak barController, weak panel] event in
            guard let self, let barController, let panel else { return }
            barController.handle(event: event)
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
            ) { [weak self] _ in self?.scheduleRefresh(reason: .itemAppeared) },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.scheduleRefresh(reason: .itemDisappeared) },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.scheduleRefresh(reason: .frontmostAppChanged) },
        ]

        let hotKey = GlobalHotKey { [weak self, weak barController] in
            guard let self, let barController else { return }
            barController.handle(event: .init(trigger: .hotkey, location: NSEvent.mouseLocation))
            self.syncPanel(barController: barController, panel: panel)
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
            guard let self, let barController, let panel else { return }
            self.syncPanel(barController: barController, panel: panel)
            // 每次交互都可能续期，收起点跟着重算
            self.scheduleAutoConceal(barController: barController, panel: panel)
        }

        // 自动收起改用"只在展开时挂的一次性定时器"。
        //
        // 原来是一条常驻 0.25s repeating Timer：面板收起时它每 0.25 秒醒一次，
        // 去做一件必然返回 false 的判断。40 分钟就是约 9600 次无意义唤醒——
        // 空闲 CPU 超预算的头号嫌疑就是它，而不是什么深奥的系统行为。
        // 现在收起状态下**没有任何周期任务**，展开时才挂表，且挂的是"到点即收"的那一条。
        scheduleAutoConceal(barController: barController, panel: panel)

        statusItem = makeStatusItem(controller: barController)
        presentWizardIfNeeded(barController: barController)
        barController.start(scansSynchronously: false)

        // 冷启动全量枚举实测 ≈2.6s：同步做会击穿「启动到接管 2s」预算，
        // 还会让菜单栏在启动瞬间卡住，因此首扫交给后台调度器，结果回主线程落地。
        scheduleRefresh(reason: .userRequested)
        reportStartup(barController: barController)
        // 自检必须在**真 app 进程**里跑：探针 CLI 没有 NSApp 激活策略与完整 run loop，
        // 键盘焦点这类断言在它里面必然失败，测出来的是环境不等价而不是产品有 bug。
        if ProcessInfo.processInfo.environment["TIDYBAR_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettings()
            }
        }
        if ProcessInfo.processInfo.environment["TIDYBAR_SELFCHECK_CONCEAL"] == "1" {
            concealSelfCheck(barController: barController, panel: panel)
        }
        if ProcessInfo.processInfo.environment["TIDYBAR_SELFCHECK_SEARCH"] == "1" {
            searchSelfCheck(barController: barController)
        }

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

    /// 按"剩余可见时间"挂一次性收起表；不需要收起时**不挂任何表**。
    private func scheduleAutoConceal(barController: TidyBarController, panel: TidyBarPanelController?) {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        rescanObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        rescanObservers = []
        tickTimer?.invalidate()
        tickTimer = nil
        guard let remaining = barController.remainingRevealTime else { return }
        let timer = Timer(timeInterval: max(0.05, remaining), repeats: false) { [weak self, weak barController, weak panel] _ in
            guard let self, let barController else { return }
            if barController.tick() {
                panel?.hide()
            }
            self.scheduleAutoConceal(barController: barController, panel: panel)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
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
        let scanStarted = Date()
        enumerator.request(
            reason: reason,
            scan: { reader.discoverItems() },
            apply: { [weak self, weak controller] items in
                fprint("重扫｜触发=" + reason.rawValue + "｜图标 " + String(items.count)
                     + "｜耗时 " + String(format: "%.0f", Date().timeIntervalSince(scanStarted) * 1000) + "ms")
                guard let self else { return }
                controller?.layoutEngine.migrateLegacyLayoutIfNeeded(observed: items)
                if let outcome = controller?.layoutEngine.lastMigration {
                    fprint("台账迁移｜老条目 \(outcome.migrated) 项，当场对上 \(outcome.matched) 项；旧布局已备份可回退")
                }
                controller?.applyScan(items)
                self.syncDividerPositions(from: items)
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
        demo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TidyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        item.menu = menu
        return item
    }

    /// 呼出搜索面板。
    ///
    /// 为什么还挂在 ☰ 菜单里而不是全局快捷键（报告 A8 的 ⌥Space）：
    /// `NSEvent.addGlobalMonitorForEvents` 只能**观察**按键、不能吞掉它，
    /// 用 ⌥Space 呼出的同时会把一个空格打进用户正在输入的文本框里——这比没有快捷键更糟。
    /// 真要全局热键必须走 RegisterEventHotKey（Carbon）或 CGEventTap 才能消费掉按键，
    /// 而这两条都还没在本项目里验证过，所以先不假装支持。
    @objc private func presentSearch() {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        searchUI?.present(anchorX: NSEvent.mouseLocation.x, screenHeight: screenHeight)
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

    /// 摆出/收起两条分隔符。
    ///
    /// 只有接管已在本机解锁才允许摆：没有分隔符时改分区靠"同区同伴"给落点，
    /// 有分隔符才谈得上"按位置自动归区"。摆出来后拖动它 = 用已验过的 ⌘ 拖拽搬我们自己的图标。
    @objc private func toggleDividers() {
        if dividerItems.isEmpty {
            for _ in 0..<2 {
                let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                divider.button?.title = Self.dividerGlyph
                divider.button?.toolTip = "TidyBar 分隔符：⌘ 拖动它调整区的边界"
                dividerItems.append(divider)
            }
            fprint("已摆出 2 条分隔符，可 ⌘ 拖动调整边界")
        } else {
            dividerItems.forEach { NSStatusBar.system.removeStatusItem($0) }
            dividerItems.removeAll()
            controller?.dividerCenters = (nil, nil)
            controller?.dividerIDs = []
            fprint("已收起分隔符")
        }
        controller?.refreshItems()
    }

    /// 从现场读回分隔符位置（左/右两条的中心 x），并据此重算每个图标的归属。
    private func syncDividerPositions(from items: [ManagedItem]) {
        guard !dividerItems.isEmpty else {
            controller?.dividerCenters = (nil, nil)
            return
        }
        let centers = items.filter { $0.title == Self.dividerGlyph }
            .map { $0.frame.midX }
            .sorted()
        guard centers.count >= 2 else {
            // 只读到一条（刚摆出来还没被枚举到，或某个 App 吞了位置）：宁可当作没有边界
            controller?.dividerCenters = (nil, nil)
            return
        }
        controller?.dividerCenters = (centers.first, centers.last)
        controller?.dividerIDs = Set(items.filter { $0.title == Self.dividerGlyph }.map(\.id))
        controller?.realignToDividers()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = TidyBarSettingsWindowController(controller: barControllerProxy, hotKeyDescription: hotKeyNote)
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
        controller.move(request.itemID, to: request.zone)
    }

    @objc private func openAccessibilitySettings() {
        services.accessibility.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
