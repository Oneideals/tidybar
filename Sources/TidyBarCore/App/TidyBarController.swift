import Foundation
import CoreGraphics

/// 组合根：把布局引擎、事件状态机、规则求值、设置与持久化粘在一起。
/// 不直接触碰 AppKit 视图，因此可在命令行环境下完整测试。
public final class TidyBarController {
    public struct Snapshot: Equatable, Sendable {
        public let layout: MenuBarLayout
        public let isRevealed: Bool
        public let capability: LayoutEngine.Capability
        public let items: [ManagedItem]
        public init(layout: MenuBarLayout, isRevealed: Bool, capability: LayoutEngine.Capability, items: [ManagedItem]) {
            self.layout = layout
            self.isRevealed = isRevealed
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
            layout: engine.layout,
            isRevealed: reveal.isRevealed,
            capability: engine.capability,
            items: items
        )
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
        let recovery = engine.recoverOnLaunch()
        if case .interrupted(let intent, _) = recovery {
            if settings.autoRecoverPendingIntent {
                replay(intent)
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
        didSet { installTargetProvider() }
    }
    /// 供设置窗口或菜单触发/查询菜单栏物理分隔符与折叠状态
    public var onToggleDividers: (() -> Void)?
    public var areDividersPlaced: (() -> Bool)?
    public var onToggleMenuBarFold: (() -> Void)?
    public var isMenuBarFoldedQuery: (() -> Bool)?
    public var onToggleDrawer: (() -> Void)?
    public var onExecuteSmartFold: (() -> Void)?

    private var targetProviderInstalled = false
    private func installTargetProviderOnce() {
        guard !targetProviderInstalled else { return }
        targetProviderInstalled = true
        installTargetProvider()
    }

    /// 给引擎装上"合法落点"的来源。
    ///
    /// 这是"接管模式下从菜单改分区静默不生效"的正面修法：引擎要的从来不是一个像素数，
    /// 而是一个**踩在邻居槽位上**的坐标（findings/02：拖进空隙系统不报错也不动）。
    /// 有分隔符时按分区边界找邻居；没有就按现有分区里的同伴找——两种都不许猜坐标。
    private func installTargetProvider() {
        engine.targetProvider = { [weak self] itemID, zone in
            guard let self else { return nil }
            let ordered = MenuBarEnumeration.sortedLeftToRight(self.items)
            let edges = self.dividerCenters.left != nil && self.dividerCenters.right != nil
                ? self.dividerCenters
                : self.inferredEdges(ordered: ordered, zone: zone)
            if let x = DividerGeometry.landingX(
                for: itemID, to: zone, ordered: ordered,
                leftEdge: edges.left, rightEdge: edges.right
            ) { return x }
            // 分隔符还没摆出来时，退到"按当前分区归属找邻居"
            let peers = self.items.filter { $0.id != itemID && self.engine.layout.zone(of: $0.id) == zone }
            guard !peers.isEmpty else { return nil }
            return DividerGeometry.landingX(
                for: itemID, to: zone, ordered: ordered,
                leftEdge: peers.map { $0.frame.midX }.min(), rightEdge: peers.map { $0.frame.midX }.max()
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

    /// 把"分区归属"整体按分隔符重算（用户拖完分隔符后调用）。
    public func realignToDividers() {
        guard let rightEdge = dividerCenters.right else { return }
        for item in items where !item.isSystemOwned && !dividerIDs.contains(item.id) {
            let zone = DividerGeometry.zone(forX: item.frame.midX, leftEdge: dividerCenters.left, rightEdge: rightEdge)
            if engine.layout.zone(of: item.id) != zone {
                engine.recordZoneOnly(itemID: item.id, zone: zone)
            }
        }
        publish()
    }

    /// 把上次没做完的变更真的再做一次。
    ///
    /// 降级模式下故意什么都不做：那时布局只决定自有面板里显示谁，不动系统菜单栏，
    /// `recoverOnLaunch` 折叠完就已经是最终状态了——此时去拖图标等于凭猜测制造副作用。
    private func replay(_ intent: LayoutJournal.LayoutIntent) {
        let label = "\(intent.itemID) → \(intent.targetZone.displayLabel)"
        guard engine.capability == .fullDrag else {
            record("收纳面板模式，无需重放上次变更：\(label)")
            return
        }
        do {
            try engine.replay(intent)
            record("已重放上次未完成的变更：\(label)")
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

    /// 退出前收尾（正常退出与 SIGTERM/SIGHUP 共用）：抬起半空拖拽 + 布局落盘
    public func flushForTermination() {
        engine.prepareForTermination()
    }

    public func refreshItems() {
        items = engine.synchronize(newItemZone: settings.newItemZone)
        publish()
    }

    /// 落地一次后台扫描的结果（调用方负责在主线程回调）
    public func applyScan(_ scanned: [ManagedItem]) {
        let known = Set(items.map(\.id))
        items = scanned
        installTargetProviderOnce()
        engine.fold(items: scanned, newItemZone: settings.newItemZone)
        // A7「先问我」：默认策略照样先落一个确定的分区（不能让新图标悬着，
        // 否则它到底显不显示取决于 UI 有没有画那条问题），但把选择权挂出来等用户回答。
        if settings.askAboutNewItems {
            for fresh in scanned where !known.contains(fresh.id) && !fresh.isSystemOwned {
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
        guard move(itemID, to: zone) else { return false }
        pendingNewItems.removeAll { $0.id == itemID }
        record("新图标 " + itemID + " 已按你的选择归入" + TidyBarController.zoneLabel(zone))
        publish()
        return true
    }

    // MARK: - 显隐

    /// 事件层入口：只响应用户开启的呼出方式
    public func handle(event: EventEngine.Event, at date: Date = Date()) {
        guard settings.revealTriggers.contains(event.trigger) || event.trigger == .emptyBarClick else { return }
        if event.trigger == .emptyBarClick {
            let hitItem = items.first {
                $0.frame.contains(event.location)
                && !dividerIDs.contains($0.id)
                && !($0.ownerBundleID?.contains("tidybar") == true)
                && !($0.title == "▶" || $0.title == "◀" || $0.title == "☰" || $0.title == "│")
            }
            if hitItem != nil {
                if reveal.isRevealed {
                    reveal.conceal()
                    publish()
                }
                return
            }
            if reveal.isRevealed {
                reveal.conceal()
                publish()
            } else {
                if reveal.reveal(by: .emptyBarClick, at: date) { publish() }
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
        reveal.setDemoMode(!reveal.isDemoMode)
        if reveal.isDemoMode {
            // 进入演示模式：把隐藏区整体收起，仅保留系统项
            for item in items where !item.isSystemOwned {
                move(item.id, to: .hidden, at: date)
            }
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

    public func move(
        _ itemID: String,
        to zone: MenuBarZone,
        targetX: CGFloat? = nil,
        position: Int? = nil,
        origin: ChangeOrigin = .user,
        at date: Date = Date()
    ) -> Bool {
        do {
            try engine.apply(itemID: itemID, to: zone, targetX: targetX, targetPosition: position)
        } catch let error as LayoutEngine.EngineError {
            // "没有合法落点"要和别的失败分开说：前者是接管模式下还缺分隔符/坐标（A2 没做），
            // 混进一句"布局变更未生效"就等于让用户自己猜为什么没动。
            if case .noMovementCapability = error {
                record("改分区未生效：接管模式下需要一个合法落点（分隔符尚未实现）")
            } else {
                record("布局变更未生效：\(error)")
            }
            publish()
            return false
        } catch {
            record("布局变更未生效：\(error)")
            publish()
            return false
        }
        // 只有用户亲手决定的才钉住。规则改动也会走这个 move——早先注释写的是
        // "规则不走这条路"，那是错的：真走。若不区分来源，规则就会把用户的图标
        // 一个个钉成"用户决定"，免修剪保护于是变成一堆误钉。
        if origin == .user {
            engine.pinAsUser(itemID: itemID)
            record("图标已归入\(TidyBarController.zoneLabel(zone))")
        }
        publish()
        return true
    }

    /// 重新设定图标分区（优先尝试物理 ⌘ 拖拽；若未摆放物理分隔符或目标区无邻居，则保全逻辑分区与持久化，并在收纳面板中生效）
    @discardableResult
    public func reassignZone(_ itemID: String, to zone: MenuBarZone, origin: ChangeOrigin = .user) -> Bool {
        if move(itemID, to: zone, origin: origin) {
            return true
        }
        // 若物理拖拽因缺少落点未能执行，绝不能让用户的设置操作静默失败并丢失！
        engine.recordZoneOnly(itemID: itemID, zone: zone)
        if origin == .user {
            engine.pinAsUser(itemID: itemID)
            record("图标已归入\(TidyBarController.zoneLabel(zone))（未摆放物理分隔符，已在收纳面板中生效）")
        }
        publish()
        return true
    }

    /// 规则批次落地
    @discardableResult
    public func evaluateRules(context: SystemContext, isScreenShareActive: Bool = false, at date: Date = Date()) -> RuleEngine.Batch {
        guard settings.rulesEnabled else { return .init(changes: []) }
        let batch = ruleEngine.evaluate(
            rules: settings.rules,
            context: context,
            currentLayout: engine.layout,
            isScreenShareActive: isScreenShareActive
        )
        for change in batch.changes {
            move(change.itemID, to: change.to, origin: .rule, at: date)
        }
        return batch
    }

    /// 使用当前真实环境上下文自动求值并落地规则
    @discardableResult
    public func evaluateRulesWithCurrentContext(isScreenShareActive: Bool = false, at date: Date = Date()) -> RuleEngine.Batch {
        evaluateRules(context: contextProvider.currentContext(), isScreenShareActive: isScreenShareActive, at: date)
    }

    // MARK: - 设置

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings = settings.sanitized()
        store.save(settings)
        publish()
    }

    /// 所有已保存的布局档案名称
    public func listProfiles() -> [String] {
        Array(settings.profiles.keys).sorted()
    }

    /// 应用某个布局档案（报告 C2）
    public func applyProfile(named name: String) {
        guard let profile = settings.profiles[name] else { return }
        settings.activeProfileName = name
        store.save(settings)
        for zone in MenuBarZone.allCases {
            for itemID in profile.items(in: zone) {
                move(itemID, to: zone)
            }
        }
    }

    /// 当前菜单栏状态存为档案
    public func saveProfile(named name: String) {
        update {
            $0.profiles[name] = engine.layout
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

    /// 面板/搜索里右键弹菜单：先呼出隐藏区，再在真实图标上触发 AXShowMenu。
    @discardableResult
    public func showMenu(itemID: String, at date: Date = Date()) -> ActivationOutcome {
        if engine.layout.zone(of: itemID) == .alwaysHidden {
            reveal.reveal(by: .hotkey, at: date)
        }
        let outcome = engine.showMenu(itemID: itemID)
        if outcome.countsAsPressed {
            record("已弹菜单 \(itemID)（\(outcome.userReadable)）")
        } else {
            record("弹菜单失败 \(itemID)：\(outcome.userReadable)")
        }
        publish()
        return outcome
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
