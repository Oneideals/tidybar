import Foundation
import CoreGraphics

/// 组合根：把布局引擎、事件状态机、规则求值、设置与持久化粘在一起。
/// 不直接触碰 AppKit 视图，因此可在命令行环境下完整测试。
public final class TidyBarController {
    public enum PhysicalLayoutState: Equatable, Sendable {
        case idle, queued, arranging, completed, failed(String)

        public var message: String? {
            switch self {
            case .idle: return nil
            case .queued: return "分区已保存，等待整理菜单栏"
            case .arranging: return "正在整理菜单栏…"
            case .completed: return "菜单栏物理整理已完成"
            case .failed(let message): return message
            }
        }

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public struct Snapshot: Equatable, Sendable {
        public let layout: MenuBarLayout
        public let isRevealed: Bool
        public let isMenuBarExpanded: Bool
        public let capability: LayoutEngine.Capability
        public let items: [ManagedItem]
        public init(layout: MenuBarLayout, isRevealed: Bool, capability: LayoutEngine.Capability, items: [ManagedItem], isMenuBarExpanded: Bool = false) {
            self.layout = layout
            self.isRevealed = isRevealed
            self.isMenuBarExpanded = isMenuBarExpanded
            self.capability = capability
            self.items = items
        }
    }

    public private(set) var settings: AppSettings
    public var onSnapshot: ((Snapshot) -> Void)?

    private let engine: LayoutEngine
    /// 供装配层读取接管能力与布局真相源（只读语义由类型本身保证）
    public var layoutEngine: LayoutEngine { engine }
    private let reveal: RevealStateMachine
    private let ruleEngine: RuleEngine
    private let store: SettingsStoring
    private let contextProvider: SystemContextProviding
    private var items: [ManagedItem] = []
    private var pendingReplayID: String?
    private var demoReturnSurface: RevealStateMachine.Surface?
    private var isPreparingMovement = false
    public private(set) var physicalLayoutState: PhysicalLayoutState = .idle
    public var isPhysicalLayoutBusy: Bool { physicalLayoutState == .arranging }
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "local.tidybar.app"

    public init(
        engine: LayoutEngine,
        reveal: RevealStateMachine,
        settings: AppSettings,
        store: SettingsStoring,
        ruleEngine: RuleEngine = RuleEngine(),
        contextProvider: SystemContextProviding = LiveSystemContextProvider()
    ) {
        self.engine = engine
        self.reveal = reveal
        self.settings = settings.sanitized()
        self.store = store
        self.ruleEngine = ruleEngine
        self.contextProvider = contextProvider
    }

    public var snapshot: Snapshot {
        Snapshot(
            layout: presentationLayout,
            isRevealed: reveal.isRevealed && reveal.surface == .drawer,
            capability: engine.capability,
            items: items,
            isMenuBarExpanded: !isMenuBarFolded
        )
    }

    /// 演示只是临时显示策略。永久分配与恢复日志始终保留用户原来的布局。
    private var presentationLayout: MenuBarLayout {
        guard reveal.isDemoMode else { return engine.layout }
        var layout = engine.layout
        let userIDs = Set(assignableItems.map(\.id))
        for id in [MenuBarZone.alwaysHidden, .hidden, .visible].flatMap({ engine.layout.items(in: $0) }) where userIDs.contains(id) {
            layout.move(itemID: id, to: .hidden, position: layout.items(in: .hidden).count)
        }
        return layout
    }

    public var isMenuBarFolded: Bool { !reveal.isRevealed || reveal.surface != .menuBar }

    public var assignableItems: [ManagedItem] {
        items.filter {
            !$0.isSystemOwned && !owns($0)
        }
    }

    public var managedZoneAssignments: [String: MenuBarZone] {
        assignableItems.reduce(into: [:]) { result, item in
            result[item.id] = presentationLayout.zone(of: item.id) ?? settings.newItemZone
        }
    }

    public func setPhysicalLayoutBusy(_ busy: Bool) {
        guard isPhysicalLayoutBusy != busy else { return }
        reportPhysicalLayout(busy ? .arranging : .idle)
    }

    public func reportPhysicalLayout(_ state: PhysicalLayoutState) {
        let changed = physicalLayoutState != state
        physicalLayoutState = state
        if changed, let message = state.message { record(message) }
        publish()
    }

    func owns(_ item: ManagedItem) -> Bool {
        item.ownerBundleID == ownBundleID || dividerIDs.contains(item.id)
    }

    // 本进程已尝试过不等于恢复完成；失败后磁盘上的意图仍须保护到下次启动。
    var isAwaitingRecovery: Bool { engine.pendingIntent != nil }

    public var drawerItems: [ManagedItem] {
        guard !isDemoMode else { return [] }
        let available = assignableItems
        return presentationLayout.items(in: .hidden).compactMap { id in
            available.first { $0.id == id }
        }
    }

    public func setMenuBarFolded(_ folded: Bool, at date: Date = Date()) {
        if folded { reveal.conceal() }
        else {
            if isDemoMode { toggleDemoMode(at: date) }
            reveal.reveal(by: .dividerClick, surface: .menuBar, at: date)
        }
        publish()
    }

    public func toggleDrawer(at date: Date = Date()) {
        guard !isDemoMode, !isPhysicalLayoutBusy else { return }
        if snapshot.isRevealed { reveal.conceal() }
        else { reveal.reveal(by: .dividerClick, surface: .drawer, at: date) }
        publish()
    }

    public func setInteractionActive(_ active: Bool, at date: Date = Date()) {
        if reveal.setInteractionActive(active, at: date) { publish() }
    }

    public func noteInteraction(at date: Date = Date()) {
        reveal.noteInteraction(at: date)
        publish()
    }

    /// 当前接管能力（完整模式 / 收纳面板降级），供 UI 与诊断展示
    public var capability: LayoutEngine.Capability { engine.capability }
    /// 降级原因；nil 表示未降级
    public var capabilityReason: String? { engine.capabilityReason}

    /// 一行现状说明，设置窗口与首启向导都读它——两处各写一份迟早会说不一致。
    public var layoutEngineAllowsTakeoverDescription: String {
        var line = "模式：\(capability.displayName)"
        if !engine.ledgerRecordsSnapshot.isEmpty {
            line += "｜台账已记住 \(engine.ledgerRecordsSnapshot.count) 项分配"
        }
        return line
    }

    // MARK: - 启动

    /// 启动即恢复上次状态；孤儿意图按设置决定重放还是丢弃（报告 B4）
    @discardableResult
    public func start(now: Date = Date(), scansSynchronously: Bool = true) -> LayoutJournal.Recovery {
        pendingReplayID = nil
        let recovery = engine.recoverOnLaunch()
        if case .interrupted(let intent, _) = recovery {
            if settings.autoRecoverPendingIntent {
                pendingReplayID = intent.id
                replayWhenReady()
            } else {
                engine.discardPendingIntent()
                record("放弃上次未完成的布局变更：\(intent.itemID) → \(intent.targetZone.displayLabel)")
            }
        }
        // 真机枚举耗时 2.6s，装配层应传 false 并把扫描交给 BackgroundEnumerator
        if scansSynchronously { refreshItems() }
        return recovery
    }

    /// 分隔符（我们自己的图标）的中心 x。没有它们时退化成"按现有分区找邻居"。
    /// 分隔符自身的图标 id：重算归属时必须跳过，否则会把边界自己"收起来"
    public var dividerIDs: Set<String> = []
    public var dividerCenters: (left: CGFloat?, right: CGFloat?) = (nil, nil) {
        didSet {
            installTargetProvider()
            if replayWhenReady() { publish() }
        }
    }
    /// 供设置窗口或菜单触发/查询菜单栏物理分隔符与折叠状态
    public var onToggleDividers: (() -> Void)?
    public var areDividersPlaced: (() -> Bool)?
    public var onToggleMenuBarFold: (() -> Void)?
    public var isMenuBarFoldedQuery: (() -> Bool)?
    public var onToggleDrawer: (() -> Void)?
    public var onSearchRequested: (() -> Void)?
    /// 保存期望后由装配层排队整理；参数表示还须恢复分区内部的保存顺序。
    public var onRequestPhysicalArrangement: ((_ restoreSavedOrder: Bool) -> Void)?
    /// 装配层暂时展开自有分隔符，返回可用于实际移动的最新坐标。
    public var onBeginLayoutAdjustment: (() -> [ManagedItem])?
    public var onEndLayoutAdjustment: (() -> Void)?

    private func beginLayoutAdjustment() {
        guard let begin = onBeginLayoutAdjustment else { return }
        isPreparingMovement = true
        items = begin()
        isPreparingMovement = false
    }

    private var targetProviderInstalled = false
    private func installTargetProviderOnce() {
        guard !targetProviderInstalled else { return }
        targetProviderInstalled = true
        if engine.targetProvider == nil { installTargetProvider() }
    }

    /// 给引擎装上"合法落点"的来源。
    ///
    /// 这是"接管模式下从菜单改分区静默不生效"的正面修法：引擎要的从来不是一个像素数，
    /// 而是一个**踩在邻居槽位上**的坐标（findings/02：拖进空隙系统不报错也不动）。
    /// 有分隔符时按分区边界找邻居；没有就按现有分区里的同伴找——两种都不许猜坐标。
    private func installTargetProvider() {
        engine.targetProvider = { [weak self] itemID, zone in
            guard let self else { return nil }
            let ordered = DividerGeometry.physicalItems(self.items)
            if let item = ordered.first(where: { $0.id == itemID }),
               self.visibleBoundary != nil,
               DividerGeometry.zone(forX: item.centerX, leftEdge: self.dividerCenters.left,
                                    rightEdge: self.visibleBoundary) == zone,
               self.engine.pendingIntent?.targetPosition == nil {
                return item.centerX // 已在目标分区，无须制造一次拖拽。
            }
            let boundaries = ordered.filter { self.dividerIDs.contains($0.id) }
            if boundaries.count == 2,
               let toggle = ordered.first(where: { self.owns($0) && !self.dividerIDs.contains($0.id) }),
               let moving = ordered.firstIndex(where: { $0.id == itemID }) {
                let desired = self.engine.pendingIntent?.targetPosition != nil
                    ? DividerGeometry.arrangementOrder(items: ordered, layout: self.engine.layout,
                        leftDivider: boundaries[0].id, rightDivider: boundaries[1].id, toggle: toggle.id,
                        defaultZone: self.settings.newItemZone)
                    : DividerGeometry.foldingOrder(items: ordered, layout: self.engine.layout,
                        controls: .init(leftDivider: boundaries[0].id, rightDivider: boundaries[1].id, toggle: toggle.id),
                        defaultZone: self.settings.newItemZone)
                if let target = desired.firstIndex(of: itemID) {
                    if moving == target { return ordered[moving].centerX }
                    return MenuBarDropTarget.targetX(in: ordered, moving: moving, to: target)
                }
            }
            let edges = self.dividerCenters.left != nil && self.dividerCenters.right != nil
                ? self.dividerCenters
                : self.inferredEdges(ordered: ordered, zone: zone)
            if let x = DividerGeometry.landingX(
                for: itemID, to: zone, ordered: ordered,
                leftEdge: edges.left, rightEdge: edges.right, dividerIDs: self.dividerIDs
            ) { return x }
            if let x = DividerGeometry.boundaryLandingX(for: itemID, to: zone, ordered: ordered,
                leftEdge: self.dividerCenters.left, rightEdge: self.dividerCenters.right, dividerIDs: self.dividerIDs) { return x }
            // 分隔符还没摆出来时，退到"按当前分区归属找邻居"
            let peers = self.items.filter { $0.id != itemID && !self.owns($0) && self.engine.layout.zone(of: $0.id) == zone }
            guard !peers.isEmpty else { return nil }
            return DividerGeometry.landingX(
                for: itemID, to: zone, ordered: ordered,
                leftEdge: peers.map { $0.frame.midX }.min(), rightEdge: peers.map { $0.frame.midX }.max(),
                dividerIDs: self.dividerIDs
            )
        }
    }

    /// 只有一条分隔符时，另一侧边界只能当作无限远（用极值表达），避免把整条菜单栏判成同一个区。
    private func inferredEdges(ordered: [ManagedItem], zone: MenuBarZone) -> (left: CGFloat?, right: CGFloat?) {
        switch zone {
        case .visible: return (dividerCenters.right, dividerCenters.right)
        case .hidden: return (dividerCenters.left ?? -.greatestFiniteMagnitude, dividerCenters.right ?? .greatestFiniteMagnitude)
        case .alwaysHidden: return (dividerCenters.left, dividerCenters.left)
        }
    }

    /// 按钮是常显区的可见边界，右分隔符只是折叠机构。
    private var visibleBoundary: CGFloat? {
        items.first(where: { owns($0) && !dividerIDs.contains($0.id) })?.centerX ?? dividerCenters.right
    }

    /// 用户手动拖动后按按钮位置重算，再将折叠分隔符归位。
    public func realignToDividers() {
        guard let rightEdge = visibleBoundary, !isDemoMode, !isAwaitingRecovery, !isPhysicalLayoutBusy else { return }
        let ordered = MenuBarEnumeration.sortedLeftToRight(assignableItems)
        for zone in MenuBarZone.allCases {
            let members = ordered.filter { DividerGeometry.zone(forX: $0.centerX, leftEdge: dividerCenters.left, rightEdge: rightEdge) == zone }
            for (index, item) in members.enumerated() {
                if engine.layout.zone(of: item.id) != zone || engine.layout.position(of: item.id) != index {
                    do {
                        try engine.recordZoneOnly(itemID: item.id, zone: zone, position: index)
                        engine.pinAsUser(itemID: item.id)
                    } catch { record("分区保存失败：\(error)") }
                }
            }
        }
        publish()
        onRequestPhysicalArrangement?(false)
    }

    /// 把上次没做完的变更真的再做一次。
    ///
    /// 降级模式下故意什么都不做：那时布局只决定自有面板里显示谁，不动系统菜单栏，
    /// `recoverOnLaunch` 折叠完就已经是最终状态了——此时去拖图标等于凭猜测制造副作用。
    private func replay(_ intent: LayoutJournal.LayoutIntent) {
        let label = "\(intent.itemID) → \(intent.targetZone.displayLabel)"
        do {
            try engine.replay(intent)
            record(engine.capability == .fullDrag
                   ? "已重放上次未完成的变更：\(label)"
                   : "收纳面板模式，无需重放物理操作，已恢复上次分配：\(label)")
        } catch {
            switch engine.noteReplayFailure() {
            case .retryScheduled(let failures):
                record("重放失败（累计 \(failures) 次），下次启动继续尝试：\(error)")
            case .abandoned:
                record("重放连续失败，已放弃该意图并回到上次已提交的布局")
            case .nothingPending:
                record("重放失败且盘上已无待恢复意图：\(error)")
            }
        }
    }

    /// 初始扫描和分隔符位置可能尚未准备好；等待不消耗恢复次数。
    @discardableResult
    private func replayWhenReady() -> Bool {
        guard !isPreparingMovement, !isPhysicalLayoutBusy else { return false }
        guard let id = pendingReplayID else { return false }
        guard engine.canReplayNow else { return false }
        beginLayoutAdjustment()
        defer { onEndLayoutAdjustment?() }
        guard let intent = engine.pendingIntent, intent.id == id else {
            pendingReplayID = nil // 已被后续用户操作提交、取消或替代。
            return false
        }
        if engine.capability == .fullDrag,
           engine.targetProvider?(intent.itemID, intent.targetZone) == nil { return false }
        pendingReplayID = nil // 真正尝试后，本次进程不因后续快照反复重放。
        replay(intent)
        return true
    }

    /// 退出前收尾（正常退出与 SIGTERM/SIGHUP 共用）：释放输入，保留已持久化状态。
    public func flushForTermination() {
        engine.prepareForTermination()
    }

    public func refreshItems() {
        guard !isPhysicalLayoutBusy else { return }
        applyScan(engine.discoverItems())
    }

    /// 整理完成的坐标用于预热截图；在截图完成前继续保持输入互斥。
    public func acceptArrangementResult(_ scanned: [ManagedItem]) {
        guard isPhysicalLayoutBusy else { return }
        adoptScan(scanned)
    }

    /// 落地一次后台扫描的结果（调用方负责在主线程回调）
    public func applyScan(_ scanned: [ManagedItem]) {
        guard !isPhysicalLayoutBusy else { return }
        adoptScan(scanned)
    }

    private func adoptScan(_ scanned: [ManagedItem]) {
        engine.refreshAccessibilityCapability()
        let known = Set(items.map(\.id))
        items = scanned
        installTargetProviderOnce()
        engine.fold(items: scanned.filter { !owns($0) }, newItemZone: settings.newItemZone)
        // A7「先问我」：默认策略照样先落一个确定的分区（不能让新图标悬着，
        // 否则它到底显不显示取决于 UI 有没有画那条问题），但把选择权挂出来等用户回答。
        if settings.askAboutNewItems {
            for fresh in assignableItems where !known.contains(fresh.id) {
                if !pendingNewItems.contains(where: { $0.id == fresh.id }) {
                    pendingNewItems.append(fresh)
                }
            }
            // 队列也要收敛：用户直接在那个 App 里退出时，问题不能一直挂着
            let live = Set(scanned.map(\.id))
            pendingNewItems.removeAll { !live.contains($0.id) }
        } else if !pendingNewItems.isEmpty {
            pendingNewItems.removeAll()
        }
        replayWhenReady()
        publish()
    }

    /// 等待用户回答"这个新图标要不要收起来"（报告 A7）。
    public private(set) var pendingNewItems: [ManagedItem] = []

    /// 热键注册失败时把 `.hotkey` 从生效呼出集合里摘掉。
    ///
    /// 为什么需要这一步：`beginnerDefaults` 里本来就写着 `.hotkey`，
    /// 而注册可能因权限不足失败——那时用户按 ⌥Space 不会有半点反应，
    /// 却在设置里看到"快捷键已启用"。宁可少一种呼出方式，也不能挂一条假的路。
    public func retireHotKeyTrigger(reason: String) {
        guard settings.revealTriggers.contains(.hotkey) else { return }
        update { $0.revealTriggers.remove(.hotkey) }
        record("快捷键呼出不可用，已从生效集合摘除：\(reason)")
    }

    /// 热键注册成功后的确认记录（用户看得见"当前绑定的是哪个组合键"）。
    public func confirmHotKeyTrigger() {
        if !settings.revealTriggers.contains(.hotkey) {
            update { $0.revealTriggers.insert(.hotkey) }
        }
        record("快捷键呼出已就绪")
    }

    /// 回答一条新图标策略：落到用户选的分区并钉成"用户决定"。
    /// 没真的生效时问题必须留在队列里——"答过了却什么都没变"是最难自证的坑。
    @discardableResult
    public func answerNewItem(_ itemID: String, zone: MenuBarZone) -> Bool {
        let accepted = onRequestPhysicalArrangement == nil ? move(itemID, to: zone) : reassignZone(itemID, to: zone)
        guard accepted else { return false }
        pendingNewItems.removeAll { $0.id == itemID }
        record("新图标 " + itemID + " 的分区已保存为" + TidyBarController.zoneLabel(zone))
        publish()
        return true
    }

    // MARK: - 显隐

    /// 空白处点击触发的外部动作（如原地折叠/展开或呼出抽屉）
    public var onEmptyBarClick: (() -> Void)?
    /// 菜单栏滚轮/轻扫触发的外部动作
    public var onScrollOrSwipe: (() -> Void)?

    /// 事件层入口：只响应用户开启的呼出方式
    public func handle(event: EventEngine.Event, at date: Date = Date()) {
        guard settings.revealTriggers.contains(event.trigger) else { return }
        if isDemoMode, event.trigger == .hotkey {
            toggleDemoMode(at: date)
            return
        }
        guard !isPhysicalLayoutBusy else { return }
        if event.trigger == .emptyBarClick {
            let hitItem = items.first {
                $0.frame.contains(event.location)
                && !dividerIDs.contains($0.id)
                && !owns($0)
            }
            if hitItem != nil {
                if snapshot.isRevealed {
                    reveal.conceal()
                    publish()
                }
                return
            }
            if let onEmptyBarClick {
                onEmptyBarClick()
            } else {
                toggleDrawer(at: date)
            }
            return
        }
        if event.trigger == .scrollOrSwipe {
            if let onScrollOrSwipe {
                onScrollOrSwipe()
            } else if reveal.reveal(by: event.trigger, at: date) {
                publish()
            }
            return
        }
        if reveal.reveal(by: event.trigger, at: date) { publish() }
    }

    /// 自动收起还剩多久；`nil` 表示当前不需要任何定时器（未展开、不自动收起、演示模式）。
    /// 存在的意义就是让装配层能问出"现在到底要不要挂表"，而不是无条件每 0.25 秒醒一次。
    public var remainingRevealTime: TimeInterval? {
        reveal.remainingRevealTime(at: Date())
    }

    /// 定时器回调；返回是否发生了收起，供上层决定是否重绘
    @discardableResult
    public func tick(at date: Date = Date()) -> Bool {
        guard reveal.shouldAutoConceal(at: date) else { return false }
        reveal.conceal()
        publish()
        return true
    }

    public func conceal() {
        reveal.conceal()
        publish()
    }

    /// 一键演示模式（报告 C3）
    public func toggleDemoMode(at date: Date = Date()) {
        if isDemoMode {
            reveal.setDemoMode(false)
            if let surface = demoReturnSurface { reveal.reveal(by: .hotkey, surface: surface, at: date) }
            demoReturnSurface = nil
        } else {
            demoReturnSurface = reveal.isRevealed ? reveal.surface : nil
            reveal.setDemoMode(true)
        }
        publish()
    }

    public var isDemoMode: Bool { reveal.isDemoMode }

    // MARK: - 布局操作

    /// 用户拖拽/规则触发最终都走这里；targetX 缺失即视为降级模式（只在内存生效）
    /// 一次布局变更是谁的意思。台账据此决定"永不修剪"保护该不该生效。
    public enum ChangeOrigin: Sendable {
        /// 用户亲手点的（菜单、面板、搜索结果、新图标问答）
        case user
        /// 规则引擎推出来的
        case rule
    }

    @discardableResult
    public func move(
        _ itemID: String,
        to zone: MenuBarZone,
        targetX: CGFloat? = nil,
        position: Int? = nil,
        origin: ChangeOrigin = .user,
        at date: Date = Date()
    ) -> Bool {
        applyAssignment(itemID, to: zone, targetX: targetX, position: position,
                        origin: origin, allowLogicalFallback: false)
    }

    private func applyAssignment(
        _ itemID: String, to zone: MenuBarZone, targetX: CGFloat?, position: Int?,
        origin: ChangeOrigin, allowLogicalFallback: Bool
    ) -> Bool {
        guard !isPhysicalLayoutBusy else {
            record("菜单栏正在整理，请稍后再调整分区")
            return false
        }
        guard origin == .user || !isAwaitingRecovery else { return false }
        let prepare = !isDemoMode
        if prepare { beginLayoutAdjustment() }
        defer { if prepare { onEndLayoutAdjustment?() } }
        var usedLogicalFallback = false
        do {
            if isDemoMode { try engine.recordZoneOnly(itemID: itemID, zone: zone, position: position,
                                                     supersedingPending: origin == .user) }
            else { try engine.apply(itemID: itemID, to: zone, targetX: targetX, targetPosition: position) }
        } catch let error as LayoutEngine.EngineError {
            if case .noMovementCapability = error, allowLogicalFallback {
                do {
                    try engine.recordZoneOnly(itemID: itemID, zone: zone, position: position,
                                              supersedingPending: origin == .user)
                    usedLogicalFallback = true
                } catch {
                    record("分区保存失败：\(error)")
                    publish()
                    return false
                }
            } else {
                record(error == .noMovementCapability
                       ? "改分区未生效：接管模式下需要一个合法落点"
                       : "布局变更未生效：\(error)")
                publish()
                return false
            }
        } catch {
            record("布局变更未生效：\(error)")
            publish()
            return false
        }
        // 只有用户亲手决定的才钉住。规则改动也会走这个 move——早先注释写的是
        // "规则不走这条路"，那是错的：真走。若不区分来源，规则就会把用户的图标
        // 一个个钉成"用户决定"，免修剪保护于是变成一堆误钉。
        if origin == .user {
            pendingReplayID = nil
            engine.pinAsUser(itemID: itemID)
            record("图标已归入\(TidyBarController.zoneLabel(zone))"
                   + (usedLogicalFallback ? "（暂无合法落点，已保存面板分配）" : ""))
        }
        publish()
        return true
    }

    /// 已装配后台整理时，true 表示用户期望保存成功；实际移动结果由 physicalLayoutState 单独报告。
    /// 独立 CLI / 未装配环境继续使用原来的同步验证路径。
    @discardableResult
    public func reassignZone(_ itemID: String, to zone: MenuBarZone, position: Int? = nil, origin: ChangeOrigin = .user) -> Bool {
        guard let request = onRequestPhysicalArrangement, capability == .fullDrag, !isDemoMode else {
            return applyAssignment(itemID, to: zone, targetX: nil, position: position,
                                   origin: origin, allowLogicalFallback: true)
        }
        guard !isPhysicalLayoutBusy, origin == .user || !isAwaitingRecovery else { return false }
        do {
            try engine.recordZoneOnly(itemID: itemID, zone: zone, position: position,
                                      supersedingPending: origin == .user)
        } catch {
            reportPhysicalLayout(.failed("分区未保存：\(error.localizedDescription)"))
            return false
        }
        if origin == .user {
            pendingReplayID = nil
            engine.pinAsUser(itemID: itemID)
        }
        reportPhysicalLayout(.queued)
        request(position != nil)
        return true
    }

    /// 规则批次落地
    @discardableResult
    public func evaluateRules(context: SystemContext, isScreenShareActive: Bool = false, at date: Date = Date()) -> RuleEngine.Batch {
        guard settings.rulesEnabled, !isDemoMode, !isAwaitingRecovery, !isPhysicalLayoutBusy else { return .init(changes: []) }
        let resolvedProfiles = settings.profiles.mapValues(resolveProfile)
        let rules = settings.rules.map { saved -> DisplayRule in
            var rule = saved
            rule.actions = saved.actions.compactMap { action in
                if action.kind == .applyProfile {
                    return action.profileName.flatMap { resolvedProfiles[$0] == nil ? nil : action }
                }
                guard let savedID = action.itemID, let currentID = resolveItemID(savedID) else { return nil }
                return RuleAction(kind: action.kind, itemID: currentID)
            }
            return rule
        }
        let batch = ruleEngine.evaluate(
            rules: rules,
            context: context,
            currentLayout: engine.layout,
            isScreenShareActive: isScreenShareActive,
            profiles: resolvedProfiles,
            activeProfileName: settings.activeProfileName
        )
        let prepare = !batch.changes.isEmpty && onRequestPhysicalArrangement == nil
        if prepare { beginLayoutAdjustment() }
        defer { if prepare { onEndLayoutAdjustment?() } }
        for change in batch.changes {
            if engine.layout.zone(of: change.itemID) == change.to,
               change.position == nil || engine.layout.position(of: change.itemID) == change.position { continue }
            guard reassignZone(change.itemID, to: change.to, position: change.position, origin: .rule) else { return batch }
        }
        if let profile = batch.appliedProfiles.first, settings.activeProfileName != profile {
            settings.activeProfileName = profile
            store.save(settings)
            publish()
        }
        return batch
    }

    /// 规则和档案沿用已确认的身份台账，不把历史标题当作永远不变的 ID。
    public func resolveItemID(_ savedID: String) -> String? {
        let live = Set(assignableItems.map(\.id))
        if live.contains(savedID) { return savedID }
        let matches = engine.ledgerRecordsSnapshot.filter { $0.aliases.contains(savedID) && live.contains($0.currentID) }
        return matches.count == 1 ? matches.first?.currentID : nil
    }

    private func resolveProfile(_ profile: MenuBarLayout) -> MenuBarLayout {
        var resolved = MenuBarLayout()
        for zone in MenuBarZone.allCases {
            for id in profile.items(in: zone) {
                if let current = resolveItemID(id) { resolved.append(current, to: zone) }
            }
        }
        return resolved
    }

    /// 使用当前真实环境上下文自动求值并落地规则
    @discardableResult
    public func evaluateRulesWithCurrentContext(isScreenShareActive: Bool = false, at date: Date = Date()) -> RuleEngine.Batch {
        guard settings.rulesEnabled, !isDemoMode, !isAwaitingRecovery, !isPhysicalLayoutBusy,
              settings.rules.contains(where: { $0.isEnabled && $0.isEvaluable }) else { return .init(changes: []) }
        return evaluateRules(context: contextProvider.currentContext(), isScreenShareActive: isScreenShareActive, at: date)
    }

    // MARK: - 设置

    public var hasAutomaticRules: Bool {
        settings.rulesEnabled && !isDemoMode && !isPhysicalLayoutBusy && settings.rules.contains {
            $0.isEnabled && $0.isEvaluable && $0.conditions.allSatisfy(\.supportsAutomaticEvaluation)
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings = settings.sanitized()
        reveal.updateDelay(settings.rehideDelay)
        store.save(settings)
        publish()
    }

    /// 所有已保存的布局档案名称
    public func listProfiles() -> [String] {
        Array(settings.profiles.keys).sorted()
    }

    /// 应用某个布局档案（报告 C2）
    @discardableResult
    public func applyProfile(named name: String) -> Bool {
        guard !isPhysicalLayoutBusy else { return false }
        guard let stored = settings.profiles[name] else { return false }
        let profile = resolveProfile(stored)
        let prepare = !isDemoMode && onRequestPhysicalArrangement == nil
        if prepare { beginLayoutAdjustment() }
        defer { if prepare { onEndLayoutAdjustment?() } }
        for zone in MenuBarZone.allCases {
            for (position, itemID) in profile.items(in: zone).enumerated() {
                guard reassignZone(itemID, to: zone, position: position) else { return false }
            }
        }
        settings.activeProfileName = name
        store.save(settings)
        publish()
        return true
    }

    /// 当前菜单栏状态存为档案
    public func saveProfile(named name: String) {
        let profile = resolveProfile(engine.layout)
        update {
            $0.profiles[name] = profile
            $0.activeProfileName = name
        }
    }

    /// 删除某个布局档案
    public func deleteProfile(named name: String) {
        update {
            $0.profiles.removeValue(forKey: name)
            if $0.activeProfileName == name {
                $0.activeProfileName = nil
            }
        }
    }

    // MARK: - 搜索

    public func search(_ query: String, limit: Int = 12) -> [ManagedItem] {
        ItemSearch.rank(items, query: query, title: \.title, usageCount: { $0.lastActivatedAt == nil ? 0 : 1 })
            .prefix(limit)
            .map { $0 }
    }

    /// 面板/搜索里激活某项：先呼出隐藏区，再把点击打到真实图标上，并把结果记进诊断。
    /// 返回结果是为了让 UI 能给反馈（"这个 App 不允许代点"必须让用户看见，而不是图标默默不动）。
    @discardableResult
    public func activate(itemID: String, at date: Date = Date()) -> ActivationOutcome {
        guard !isPhysicalLayoutBusy else { return .busy }
        if engine.layout.zone(of: itemID) == .alwaysHidden {
            reveal.reveal(by: .hotkey, at: date)
        }
        let outcome = engine.activate(itemID: itemID)
        if outcome.countsAsPressed {
            record("已代点 \(itemID)（\(outcome.userReadable)）")
        } else {
            record("代点失败 \(itemID)：\(outcome.userReadable)")
        }
        publish()
        return outcome
    }

    /// CLI/简易装配的 AX 右键路径；不允许回退为左键。
    @discardableResult
    public func showMenu(itemID: String, at date: Date = Date()) -> ActivationOutcome {
        guard !isPhysicalLayoutBusy else { return .busy }
        if engine.layout.zone(of: itemID) == .alwaysHidden {
            reveal.reveal(by: .hotkey, at: date)
        }
        let outcome = engine.showMenu(itemID: itemID)
        if outcome.countsAsPressed {
            record("已发送菜单请求 \(itemID)（\(outcome.userReadable)）")
        } else {
            record("弹菜单失败 \(itemID)：\(outcome.userReadable)")
        }
        publish()
        return outcome
    }

    public func reportActivation(itemID: String, outcome: ActivationOutcome) {
        record("菜单栏点击 \(itemID)：\(outcome.userReadable)")
    }

    // MARK: - 私有

    /// 诊断日志快照（报告 B6）。设置面板里的"上次为什么没动"就读这里。
    public var logs: [String] { diagnostics }

    private var diagnostics: [String] = []

    private func record(_ message: String) {
        diagnostics.append("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
        fprint(message)
    }

    private func publish() {
        onSnapshot?(snapshot)
    }
}

/// 日志出口。骨架阶段仅打印；接入 os.log 时替换实现即可。
@inline(__always) internal func fprint(_ message: String) {
    FileHandle.standardError.write(("TidyBar: " + message + "\n").data(using: .utf8) ?? Data())
}
