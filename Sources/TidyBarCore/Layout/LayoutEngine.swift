import Foundation
import CoreGraphics

/// 布局引擎：把「用户意图」翻译成一次可回滚、可恢复的系统级操作。
///
/// 一次变更的完整生命周期（对应报告 B4 崩溃安全 + §4.2-2 事件哨兵）：
///   读快照 → 计算目标位 → 写 pending 意图 → 哨兵预检 → 执行 ⌘ 拖拽 → 哨兵复核
///   → 重读系统状态验证 → 写 committed / 清 pending；任一步失败即回滚。
public final class LayoutEngine {
    public enum EngineError: Error, Equatable {
        case noMovementCapability
        case sentinelAborted(EventSentinel.Verdict)
        case moveFailed(MenuBarMoveError)
        /// 执行后系统状态与期望不符：可能图标被别的 App 收回，或拖拽被系统改写
        case verificationFailed(expected: String, actualZone: MenuBarZone?)
        /// 事件都按预期投出去了，图标却纹丝不动：macOS 对落在空隙里的拖拽是静默忽略的，
        /// 只有复核结果才能发现"没成"，绝不能当成成功写进已提交布局
        case noVisibleEffect(itemID: String)
    }

    public enum Capability: String, Equatable, Sendable {
        /// 完整模式：真实移动菜单栏图标
        case fullDrag
        /// 降级模式（报告 F3）：不动图标，只靠收纳面板隐藏，功能受限但绝不制造失控
        case panelOnlyFallback

        public var displayName: String {
            switch self {
            case .fullDrag: return "完整接管"
            case .panelOnlyFallback: return "收纳面板（降级）"
            }
        }
    }

    public private(set) var layout: MenuBarLayout
    public private(set) var capability: Capability
    /// 降级原因，供设置界面与日志提示用户
    public private(set) var capabilityReason: String?
    /// 是否至少成功执行过一次「拖拽 + 哨兵复核」全绿的操作。
    /// M0 验收看这个：未确认前不应把完整接管开放给用户。
    public private(set) var hasConfirmedDragSupport = false
    /// 目标 X 坐标解析器。分隔符/占位符的真实位置只有 UI 层知道，
    /// 因此由装配层注册一次；apply 未显式传 targetX 时回落到这里。
    /// 返回 nil 即视为「当前无法定位」，本次变更只在内存布局生效。
    public var targetProvider: ((String, MenuBarZone) -> CGFloat?)?

    private let services: SystemServices
    private let journal: LayoutJournal
    private let sentinel: EventSentinel
    /// 孤儿意图最多重放几次，超过即丢弃。测试里可以调成 1 观察"放弃"分支。
    private let maxReplayAttempts: Int
    /// 结果复核的等待窗口：抬起鼠标键后允许菜单栏用这么久把新位置落定。
    /// 真机依据：35 图标在栏时同步读一次帧经常还是旧位置；600ms 上限 + 60ms 步进，
    /// 落位一到就返回，所以正常操作不会因此变慢。
    /// 台账可为 nil：离线测试与骨架装配不需要它，缺了也只是"跨重启的线索少一层"。
    private let ledgerStore: IdentityLedgerStore?
    private var ledgerRecords: [IdentityRecord]
    private let clock: () -> Date
    /// 最近一次台账匹配结论，供诊断与自检读取（歧义必须能被看见，不能默默吞掉）
    public private(set) var lastLedgerResolution = LedgerResolution()
    private let verificationWindow: TimeInterval
    private let verificationInterval: TimeInterval
    private var lastOperationAt: Date = .distantPast

    public init(
        layout: MenuBarLayout,
        services: SystemServices,
        journal: LayoutJournal,
        sentinel: EventSentinel = EventSentinel(),
        maxReplayAttempts: Int = LayoutJournal.defaultMaxReplayAttempts,
        verificationWindow: TimeInterval = 0.6,
        verificationInterval: TimeInterval = 0.06,
        ledger: IdentityLedgerStore? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.layout = layout
        self.services = services
        self.journal = journal
        self.sentinel = sentinel
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.ledgerStore = ledger
        self.ledgerRecords = ledger?.load() ?? []
        self.clock = clock
        self.verificationWindow = max(0, verificationWindow)
        self.verificationInterval = max(0.005, verificationInterval)
        let dragCapable: Bool
        if let mover = services.mover {
            dragCapable = !(mover is UnverifiedMenuBarMover)
        } else {
            dragCapable = false
        }
        self.capability = dragCapable ? .fullDrag : .panelOnlyFallback
        self.capabilityReason = dragCapable
            ? nil
            : "当前系统版本下 ⌘ 拖拽机制尚未验证，已自动切换为收纳面板模式"
    }

    /// 升级迁移结果（一次性），供装配层打日志。nil = 不需要迁移。
    public private(set) var lastMigration: IdentityLedgerMigration.Outcome?

    /// 启动时发现"有已提交布局、但台账是空的"⇒ 旧版本升上来，为每个老 id 建记录。
    ///
    /// 刻意不在 `init` 里做：迁移要写盘，init 失败会把构造器变 throwing，
    /// 而这里失败的正确处置是"当作没迁移过、下次启动再试"，不是让工具打不开。
    /// 备份先行：迁移 bug 一旦发生，没备份就只能让用户手工重排（设计文档 §4）。
    public func migrateLegacyLayoutIfNeeded(observed: [ManagedItem]) {
        guard let ledgerStore else { return }
        let records = ledgerStore.load()
        guard records.isEmpty, !layout.allItemIDs.isEmpty else { return }

        if let backup = legacyBackupURL {
            try? IdentityLedgerMigration.backupLegacyLayout(journal: journal, to: backup)
        }
        let (migrated, outcome) = IdentityLedgerMigration.migrate(
            layout: layout, observed: observed, now: clock()
        )
        ledgerRecords = migrated
        try? ledgerStore.save(migrated)
        lastMigration = outcome
    }

    /// 备份落点由装配层指定（Application Support 下），引擎只管写。
    public var legacyBackupURL: URL?

    // MARK: - 同步

    /// 从系统重新读取图标并折叠进布局；新出现的图标按策略归位（报告 A7）。
    @discardableResult
    public func synchronize(newItemZone: MenuBarZone) -> [ManagedItem] {
        let discovered = services.reader.discoverItems()
        fold(items: discovered, newItemZone: newItemZone)
        return discovered
    }

    /// 折叠「已在别处扫好」的图标集合。枚举真机耗时 2.6s，必须允许在后台线程做完再喂回来，
    /// 而不是强迫调用方在主线程里重扫一遍。
    public func fold(ids itemIDs: [String], newItemZone: MenuBarZone) {
        layout = MenuBarLayout.folding(discovered: itemIDs, into: layout, defaultZone: newItemZone)
    }

    /// 带归属信息的折叠：新出现的 id 若在本工具里查不到，先尝试**认领**它应继承的配置，
    /// 并把配置**改名**到新 id 上——只认领不改名，配置会一直挂在死 id 上；
    /// 不认领只等新 id，就是用户看到的"我明明收起来了，它又冒出来"。
    ///
    /// 认领条件（一条，且刻意保守）：同一归属进程内
    /// 「还留在配置里但现场已不见的旧 id」**恰好一个**，且「现场新出现但配置里没有的新 id」
    /// **也恰好一个** ⇒ 只能是同一个图标改了标题，迁过去。
    /// 数量对不上（1↔2、2↔2、0↔N）时不猜：把一个图标的设置安到另一个头上，
    /// 比丢一次配置更难查，也更伤信任。
    public func fold(items discovered: [ManagedItem], newItemZone: MenuBarZone) {
        var adopted = layout
        let known = layout.allItemIDs
        let freshIDs = Set(discovered.map(\.id))

        // 第一层：台账。它记得"这个分配上次、上上次叫什么"，所以重启之后仍有线索；
        // 只看现场两帧是不够的——重启后旧 id 早就不在布局里了。
        let ledgerFound = IdentityLedger.resolve(
            records: ledgerRecords,
            observed: discovered,
            staleIDs: known.subtracting(freshIDs)
        )
        var ledgerResolution = LedgerResolution()
        ledgerResolution.renames = ledgerFound.renames.filter { adopted.zone(of: $0.from) != nil }
        ledgerResolution.ambiguousOwners = ledgerFound.ambiguousOwners
        ledgerResolution.aliasHits = ledgerFound.aliasHits
        ledgerResolution.ordinalHits = ledgerFound.ordinalHits
        ledgerResolution.titleHits = ledgerFound.titleHits
        for move in ledgerResolution.renames {
            adopted.rename(id: move.from, to: move.to)
        }
        lastLedgerResolution = ledgerResolution

        for owner in Set(discovered.compactMap(\.ownerBundleID)) {
            let stale = adopted.configuredIDs(ofOwner: owner).filter { !freshIDs.contains($0) }
            let fresh = discovered.filter { $0.ownerBundleID == owner && !known.contains($0.id) }
            guard stale.count == 1, fresh.count == 1, let from = stale.first, let to = fresh.first?.id else {
                if stale.count > 1 && fresh.count > 1 {
                    // 多对多只在真发生时留一行痕，方便事后回答"为什么我的设置没了"
                    lastAmbiguousOwners.insert(owner)
                }
                continue
            }
            adopted.rename(id: from, to: to)
        }
        layout = MenuBarLayout.folding(discovered: discovered.map(\.id), into: adopted, defaultZone: newItemZone)
        syncLedger(observed: discovered)
        try? ledgerStore?.save(ledgerRecords)
    }

    /// 把这一帧观测并回台账：已认识的刷新观测值（并把旧名留在别名里），
    /// 不认识的先建一条 `inferred` 记录——只有用户在界面上明确分配过才算 `user`，
    /// 现在还没有那个入口，所以不预先声称自己钉住了用户的意图。
    private func syncLedger(observed: [ManagedItem]) {
        let seen = Set(ledgerRecords.map(\.currentID))
        for item in observed {
            if let index = ledgerRecords.firstIndex(where: { $0.aliases.contains(item.id) }) {
                IdentityLedger.applyUpdate(
                    to: &ledgerRecords[index], now: clock(), observedItem: item,
                    drifted: !seen.contains(item.id)
                )
                ledgerRecords[index].zoneRaw = layout.zone(of: item.id)?.rawValue ?? ""
            } else {
                ledgerRecords.append(IdentityRecord(
                    assignmentKey: "a-" + UUID().uuidString,
                    ownerBundleID: item.ownerBundleID ?? "nil",
                    observedTitle: item.title,
                    observedOrdinal: item.ordinalInOwner,
                    ownerItemCount: item.ownerItemCount,
                    aliases: [item.id],
                    zoneRaw: layout.zone(of: item.id)?.rawValue ?? "",
                    pinnedBy: .inferred,
                    lastSeenAt: clock()
                ))
            }
        }
        ledgerRecords = IdentityLedger.prune(records: ledgerRecords, now: clock(), seenIDs: Set(observed.map(\.id)))
    }

    /// 出现过"多对多、不敢猜"的进程，供诊断与设置界面提示（不是判错，是如实声明无能为力）。
    public private(set) var lastAmbiguousOwners: Set<String> = []

    // MARK: - 变更

    /// 把图标移入目标分区。targetX 由调用方（UI/策略层）给出；nil 表示当前环境不允许真实移动。
    public func apply(itemID: String, to zone: MenuBarZone, targetX: CGFloat?, targetPosition: Int? = nil) throws {
        let prev = layout.zone(of: itemID).flatMap { z -> (MenuBarZone, Int)? in
            layout.items(in: z).firstIndex(of: itemID).map { (z, $0) }
        }

        let intent = LayoutJournal.LayoutIntent(
            itemID: itemID,
            targetZone: zone,
            targetPosition: targetPosition,
            previousZone: prev?.0,
            previousPosition: prev?.1
        )
        try journal.writeIntent(intent)

        // 先在内存布局上落地意图：即便随后执行失败，重启后的 pending 重放也基于同一份真相
        layout.move(itemID: itemID, to: zone, position: targetPosition)

        guard let mover = services.mover, !(mover is UnverifiedMenuBarMover) else {
            capability = .panelOnlyFallback
            capabilityReason = "⌘ 拖拽不可用，布局仅在收纳面板内生效"
            try journal.clearPendingIntent()
            try journal.writeCommitted(layout)
            return
        }

        // 引擎层只保留两项自己该管的判定，光标的放置与飞行复核交给 mover（它才知道事件时序）
        let x: CGFloat
        if let targetX {
            x = targetX
        } else if let provided = targetProvider?(itemID, zone) {
            x = provided
        } else {
            rollback(intent)
            throw EngineError.noMovementCapability
        }

        do {
            try performDrag(mover: mover, itemID: itemID, x: x)
            try journal.clearPendingIntent()
            try journal.writeCommitted(layout)
        } catch let error as MenuBarMoveError {
            if case .unsupportedOS = error {
                capability = .panelOnlyFallback
                capabilityReason = "系统返回不支持拖拽，已降级为收纳面板模式"
            }
            rollback(intent)
            throw EngineError.moveFailed(error)
        } catch let error as EngineError {
            // 哨兵中止 / 结果复核判定"没真动"：同样必须回滚并清 pending，
            // 否则一次失败的变更会变成下次启动的孤儿意图
            rollback(intent)
            throw error
        }
    }

    /// 一次真实移动的公共流程：光标纪律 → mover → 结果复核。**不碰 journal**，
    /// pending 的生死由调用方决定（apply 失败即回滚清除；replay 失败保留意图等下次重试）。
    /// 抽出来的目的不是省代码，是保证"重放走的就是产品主路径上那条执行链"，
    /// 免得两条路径各测各的绿（验证项 3 就是这么被骗过一次）。
    private func performDrag(mover: MenuBarMoving, itemID: String, x: CGFloat) throws {
        // 注意：这里**不能**再拿"当前光标位置"与图标中心比较。验证项 2 已证伪这种写法：
        // 光标是我们稍后 warp 过去的，动手前它本来就不在图标上，比较的结果是永远中止。
        let cursor = services.cursor
        if cursor.isPrimaryButtonPressed {
            throw EngineError.sentinelAborted(.userInteracting)
        }
        let elapsed = Date().timeIntervalSince(lastOperationAt)
        if elapsed < sentinel.minIntervalBetweenOperations {
            throw EngineError.sentinelAborted(.throttled)
        }

        let beforeItem = services.reader.discoverItems().first { $0.id == itemID }
        _ = try mover.move(itemID: itemID, toX: x)

        if awaitMovementLanded(itemID: itemID, beforeItem: beforeItem, towardX: x) == false {
            throw EngineError.noVisibleEffect(itemID: itemID)
        }

        lastOperationAt = Date()
        hasConfirmedDragSupport = true
    }

    /// 复核的是**结果**（图标真的挪到位了吗），不是光标。
    /// macOS 对落在空隙里的拖拽是静默忽略的，只有查结果能发现"没成"。
    ///
    /// 必须轮询而不是读一次：真机 35 图标在栏时，抬起后那一瞬间读到的常常还是旧位置
    /// （菜单栏重排是异步的），单次读帧会把"还没落位"误判成"系统没接受"。
    /// 一旦读到真的动了就立刻返回，所以**成功路径不付额外延迟**，只有失败/慢的情况才会用尽窗口。
    /// 返回 nil 表示"无法判定"（前后帧读不到），按不误判失败处理。
    private func awaitMovementLanded(
        itemID: String,
        beforeItem: ManagedItem?,
        towardX x: CGFloat
    ) -> Bool? {
        let deadline = verificationWindow
        let interval = verificationInterval
        guard let beforeItem else { return nil }
        let beforeFrame = beforeItem.frame
        let limit = Date().addingTimeInterval(max(0, deadline))
        while true {
            let candidates: [ManagedItem]
            if let owner = beforeItem.ownerBundleID {
                candidates = services.reader.items(ownedBy: owner)
            } else {
                candidates = services.reader.discoverItems()
            }
            if let afterFrame = candidates.first(where: { $0.id == itemID })?.frame {
                if MenuBarDropTarget.didMove(before: beforeFrame, after: afterFrame, towardX: x) {
                    return true
                }
            }
            if Date() >= limit {
                // 读不到帧（图标已消失）时不武断判失败：交给上层的结果复核去处理
                return candidates.contains { $0.id == itemID } ? false : nil
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 仅供回归测试装载初始分区状态；产品路径一律走 `recoverOnLaunch`/`apply`。
    public func adoptLayoutForChecks(_ layout: MenuBarLayout) {
        self.layout = layout
    }

    /// 仅供自检：只改归属，不发起任何拖拽。
    /// 自检需要"先登记现场、再把某项归到隐藏区"这种中间状态，而产品路径一律经 `apply`。
    public func assignForChecks(_ itemID: String, to zone: MenuBarZone) {
        layout.move(itemID: itemID, to: zone, position: nil)
    }

    /// 标记某项目前这条分配是**用户亲手做的**，不是规则推的。
    ///
    /// 为什么必须单独有一步：台账的清理规则是"用户钉住的永不删"，
    /// 而实现里所有记录都以 `.inferred` 落盘 ⇒ 那条保护形同虚设，
    /// 一个月没打开的 App 就能把用户的收纳设置清掉。
    public func pinAsUser(itemID: String) {
        guard ledgerStore != nil,
              let index = ledgerRecords.firstIndex(where: { $0.aliases.contains(itemID) }) else { return }
        ledgerRecords[index].pinnedBy = .user
        try? ledgerStore?.save(ledgerRecords)
    }

    /// 台账快照（诊断与设置界面读）。
    public var ledgerRecordsSnapshot: [IdentityRecord] { ledgerRecords }

    /// 只记归属、不产生任何输入事件：分隔符被拖动后重算分区用它。
    /// 拖拽是"改分区"的一种实现手段，不是唯一一种——把边界挪了，归属自然跟着变，
    /// 这种时候不该再去搬别人的图标。
    public func recordZoneOnly(itemID: String, zone: MenuBarZone) {
        layout.move(itemID: itemID, to: zone, position: nil)
        try? journal.writeCommitted(layout)
    }

    // MARK: - 点击转发（报告 A3/A8：面板与搜索结果里的点击）

    /// 代点一个图标。不改布局、不写 journal：它不产生状态变更，失败也不该留下任何"半成品"。
    @discardableResult
    public func activate(itemID: String) -> ActivationOutcome {
        guard let activator = services.activator else {
            return .actionUnsupported
        }
        return activator.activate(itemID: itemID)
    }

    /// 代弹右键菜单。与 activate 同理，不改布局。
    @discardableResult
    public func showMenu(itemID: String) -> ActivationOutcome {
        guard let activator = services.activator else {
            return .actionUnsupported
        }
        return activator.showMenu(itemID: itemID)
    }

    /// 回滚：把内存布局恢复到意图执行前，并清除 pending
    public func rollback(_ intent: LayoutJournal.LayoutIntent) {
        if let previousZone = intent.previousZone {
            layout.move(itemID: intent.itemID, to: previousZone, position: intent.previousPosition)
        } else {
            layout.remove(itemID: intent.itemID)
        }
        try? journal.clearPendingIntent()
    }

    // MARK: - 启动恢复

    /// 应用启动时调用：存在孤儿 pending 说明上次变更未完成，按其意图重放而非反推系统状态。
    public func recoverOnLaunch() -> LayoutJournal.Recovery {
        let committed = journal.readCommittedLayout()
        let pending = journal.readPendingIntent()
        let recovery = LayoutJournal.recover(committed: committed, pending: pending)
        switch recovery {
        case .clean(let layout):
            self.layout = layout
        case .interrupted(let intent, let committed):
            self.layout = LayoutJournal.applying(intent, to: committed ?? MenuBarLayout())
        }
        return recovery
    }

    /// 用户显式放弃未完成变更时调用
    public func discardPendingIntent() {
        if let committed = journal.readCommittedLayout() {
            layout = committed
        }
        try? journal.clearPendingIntent()
    }

    /// 把上次未完成的意图沿**产品主路径**重做一遍。
    ///
    /// 与 apply 的区别只在 pending 的生死：replay 成功前不清除意图，失败时原样留在盘上，
    /// 让下一次启动还能重试；是否还要重试由 `noteReplayFailure()` 决定。
    /// 走 performDrag 而不是自己拼一遍流程，是为了让"重放成功"和"用户手动整理成功"
    /// 是同一条链路的同一个结论。
    public func replay(_ intent: LayoutJournal.LayoutIntent) throws {
        guard let mover = services.mover, !(mover is UnverifiedMenuBarMover) else {
            throw EngineError.noMovementCapability
        }
        guard let x = targetProvider?(intent.itemID, intent.targetZone) else {
            throw EngineError.noMovementCapability
        }
        try performDrag(mover: mover, itemID: intent.itemID, x: x)
        layout.move(itemID: intent.itemID, to: intent.targetZone, position: intent.targetPosition)
        try journal.clearPendingIntent()
        try journal.writeCommitted(layout)
    }

    /// 重放失败的记账结果
    public enum ReplayOutcome: Equatable, Sendable {
        /// 盘上已无 pending（本轮没什么可重试的）
        case nothingPending
        /// 意图保留，累计失败 N 次，下次启动继续试
        case retryScheduled(failures: Int)
        /// 达到上限：意图已丢弃，布局回落到上次已提交状态
        case abandoned
    }

    /// 一次重放失败后调用。上限存在的理由：意图可能永远做不成（App 已卸载、
    /// 系统改版后落点规则变了），每次都重试等于每次启动都撞同一堵墙，还会反复推用户的菜单栏。
    @discardableResult
    public func noteReplayFailure() -> ReplayOutcome {
        guard journal.hasPendingIntent else { return .nothingPending }
        // Swift 5 起 try? 会把 Optional 返回值压平，所以这里 nil 有两种含义：
        // 达到上限（journal 已自行清除 pending）或写盘异常。两种都不该继续重试。
        guard let updated = try? journal.noteReplayFailure(maxAttempts: maxReplayAttempts) else {
            discardPendingIntent()
            return .abandoned
        }
        return .retryScheduled(failures: updated.replayFailures)
    }

    /// 优雅退出前的收尾：抬起悬在半空的拖拽、把当前布局落盘。
    /// 不承诺"清掉 pending"：若此刻真有变更在飞，它和崩溃留下的状态同样含糊，
    /// 正确处理是交给下次启动的重放 + 上限，而不是假装成功。
    public func prepareForTermination() {
        (services.mover as? DragReleasing)?.releaseInFlightDrag()
        try? journal.writeCommitted(layout)
    }
}
