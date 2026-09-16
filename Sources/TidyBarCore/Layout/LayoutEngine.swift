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
        /// 图标消失或读取失败，不能将未知结果当成确认成功。
        case verificationUnavailable(itemID: String)
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
    private var dragRejectedBySystem = false
    /// 目标 X 坐标解析器。分隔符/占位符的真实位置只有 UI 层知道，
    /// 因此由装配层注册一次；apply 未显式传 targetX 时回落到这里。
    /// 返回 nil 即视为「当前无法定位」，本次变更只在内存布局生效。
    public var targetProvider: ((String, MenuBarZone) -> CGFloat?)?

    public func markDraggingUnsupported() {
        dragRejectedBySystem = true
        capability = .panelOnlyFallback
        capabilityReason = "系统返回不支持拖拽，已降级为收纳面板模式"
    }

    @discardableResult
    public func refreshAccessibilityCapability() -> Bool {
        guard !dragRejectedBySystem else { return false }
        let previous = capability
        let validated = services.mover.map { !($0 is UnverifiedMenuBarMover) } ?? false
        let permitted = services.accessibility.isTrusted
        capability = validated && permitted ? .fullDrag : .panelOnlyFallback
        capabilityReason = !permitted ? "尚未授予辅助功能权限，授权后会自动更新可用能力"
            : validated ? nil : "当前系统版本下 ⌘ 拖拽机制尚未验证，已自动切换为收纳面板模式"
        return previous != capability
    }

    public var canReplayNow: Bool {
        capability != .fullDrag || (services.cursor.isSessionInteractive && !services.cursor.isPrimaryButtonPressed)
    }

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
        var initialLayout = layout
        for id in initialLayout.items(in: .hidden) where ManagedItem.isSystemOwned(itemID: id) {
            initialLayout.move(itemID: id, to: .visible)
        }
        for id in initialLayout.items(in: .alwaysHidden) where ManagedItem.isSystemOwned(itemID: id) {
            initialLayout.move(itemID: id, to: .visible)
        }
        self.layout = initialLayout
        self.services = services
        self.journal = journal
        self.sentinel = sentinel
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.ledgerStore = ledger
        self.ledgerRecords = ledger?.load() ?? []
        self.clock = clock
        self.verificationWindow = max(0, verificationWindow)
        self.verificationInterval = max(0.005, verificationInterval)
        self.capability = .panelOnlyFallback
        refreshAccessibilityCapability()
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
        let discovered = discoverItems()
        fold(items: discovered, newItemZone: newItemZone)
        return discovered
    }

    public func discoverItems() -> [ManagedItem] { services.reader.discoverItems() }

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
        for id in adopted.items(in: .hidden) where ManagedItem.isSystemOwned(itemID: id) {
            adopted.move(itemID: id, to: .visible)
        }
        for id in adopted.items(in: .alwaysHidden) where ManagedItem.isSystemOwned(itemID: id) {
            adopted.move(itemID: id, to: .visible)
        }
        let pending = pendingIntent
        let committed = journal.readCommittedLayout()
        var restoration = committed
        if let pending {
            var reference = committed ?? MenuBarLayout()
            if reference.zone(of: pending.itemID) == nil {
                let matches = ledgerRecords.filter { $0.aliases.contains(pending.itemID) }
                if matches.count == 1, let record = matches.first {
                    let previousIDs = record.aliases.filter { reference.zone(of: $0) != nil }
                    if previousIDs.count == 1, let previousID = previousIDs.first {
                        reference.rename(id: previousID, to: pending.itemID)
                    }
                }
            }
            // pending 可能已经改名，提交仍用旧别名；同一项只保留一个顺序锚点。
            restoration = LayoutJournal.applying(pending, to: reference)
        }
        repairFragmentedSingletons(in: &adopted, observed: discovered, committed: pending == nil ? committed : nil)
        let known = adopted.allItemIDs
        let freshIDs = Set(discovered.map(\.id))

        // 第一层：台账。它记得"这个分配上次、上上次叫什么"，所以重启之后仍有线索；
        // 只看现场两帧是不够的——重启后旧 id 早就不在布局里了。
        let ledgerFound = IdentityLedger.resolve(
            records: ledgerRecords,
            observed: discovered,
            staleIDs: known.union(ledgerRecords.map(\.currentID)).subtracting(freshIDs)
        )
        var ledgerResolution = LedgerResolution()
        ledgerResolution.renames = ledgerFound.renames
        ledgerResolution.ambiguousOwners = ledgerFound.ambiguousOwners
        ledgerResolution.aliasHits = ledgerFound.aliasHits
        ledgerResolution.ordinalHits = ledgerFound.ordinalHits
        ledgerResolution.titleHits = ledgerFound.titleHits
        for move in ledgerResolution.renames {
            let recordIndex = ledgerRecords.firstIndex { $0.currentID == move.from }
            if adopted.zone(of: move.from) != nil {
                adopted.rename(id: move.from, to: move.to)
            } else if let recordIndex, let zone = MenuBarZone(rawValue: ledgerRecords[recordIndex].zoneRaw) {
                restoreItem(move.to, to: zone, aliases: ledgerRecords[recordIndex].aliases,
                            from: restoration, into: &adopted)
            }
            if let recordIndex, let item = discovered.first(where: { $0.id == move.to }) {
                IdentityLedger.applyUpdate(to: &ledgerRecords[recordIndex], now: clock(),
                                           observedItem: item, drifted: true)
            }
        }
        // 现场缺席不等于用户删除分配。同一 ID 再次出现时也要从台账恢复，
        // 不能只处理“旧 ID → 新 ID”的改名，否则 App 重开就回到默认区。
        for item in discovered where adopted.zone(of: item.id) == nil {
            let matches = ledgerRecords.filter {
                $0.aliases.contains(item.id) && $0.ownerBundleID == (item.ownerBundleID ?? "nil")
            }
            if matches.count == 1, let record = matches.first,
               let zone = MenuBarZone(rawValue: record.zoneRaw) {
                var predecessors = record.aliases.filter {
                    adopted.zone(of: $0) != nil && !freshIDs.contains($0)
                }
                // 提交仍可使用历史名称：先原位恢复，避免追加操作改变用户次序。
                // 旧名超出别名上限时，只认领整个 owner 唯一且完整的一对一关系。
                if predecessors.isEmpty, let owner = item.ownerBundleID,
                   item.ownerItemCount == 1, !ledgerResolution.ambiguousOwners.contains(owner),
                   ledgerRecords.filter({ $0.ownerBundleID == owner }).count == 1,
                   discovered.filter({ $0.ownerBundleID == owner }).count == 1 {
                    predecessors = adopted.configuredIDs(ofOwner: owner).filter { !freshIDs.contains($0) }
                }
                if predecessors.count == 1, let predecessor = predecessors.first {
                    adopted.rename(id: predecessor, to: item.id)
                } else {
                    restoreItem(item.id, to: zone, aliases: record.aliases, from: restoration, into: &adopted)
                }
            }
        }
        lastLedgerResolution = ledgerResolution

        for owner in Set(discovered.compactMap(\.ownerBundleID)) {
            guard !ledgerResolution.ambiguousOwners.contains(owner) else { continue }
            let stale = adopted.configuredIDs(ofOwner: owner).filter { !freshIDs.contains($0) }
            let fresh = discovered.filter { $0.ownerBundleID == owner && adopted.zone(of: $0.id) == nil }
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
        // 空帧可能移除了待恢复项；它再次出现时仍服从在途意图，而不是旧台账的分区/次序。
        if let pending, let currentID = observedID(for: pending.itemID, in: freshIDs) {
            layout.move(itemID: currentID, to: pending.targetZone, position: pending.targetPosition)
        }
        syncLedger(observed: discovered)
        try? ledgerStore?.save(ledgerRecords)
        synchronizePendingIdentity(observedIDs: freshIDs)
    }

    /// 旧版本可能把单图标的每个未读标题记成独立的 inferred 记录。
    /// 仅当已提交的唯一用户决定可以明确锚定时，收回这些推定碎片。
    private func repairFragmentedSingletons(in adopted: inout MenuBarLayout, observed: [ManagedItem],
                                            committed: MenuBarLayout?) {
        guard let committed else { return }
        for owner in Set(observed.compactMap(\.ownerBundleID)) {
            let items = observed.filter { $0.ownerBundleID == owner }
            let records = ledgerRecords.filter { $0.ownerBundleID == owner }
            let users = records.filter { $0.pinnedBy == .user }
            let configured = committed.configuredIDs(ofOwner: owner)
            guard items.count == 1, let item = items.first,
                  item.ownerItemCount == 1, item.ordinalInOwner == 0,
                  records.count > 1, users.count == 1, var restored = users.first,
                  records.allSatisfy({ $0.ownerItemCount == 1 && $0.observedOrdinal == 0
                      && ($0.maximumObservedItemCount ?? 1) == 1 }),
                  configured.count == 1, let savedID = configured.first,
                  restored.aliases.contains(savedID), let zone = committed.zone(of: savedID) else { continue }

            let changedID = restored.currentID != item.id
            var seen: Set<String> = []
            let aliases = records.sorted { $0.lastSeenAt < $1.lastSeenAt }.flatMap(\.aliases).filter {
                $0 != savedID && $0 != item.id && seen.insert($0).inserted
            }
            // 保留提交的锚点，不能让大量旧未读数把用户决定挤出别名上限。
            restored.aliases = Array(aliases.suffix(IdentityLedger.maxAliases - 2)) + [savedID]
            restored.zoneRaw = zone.rawValue
            IdentityLedger.applyUpdate(to: &restored, now: clock(), observedItem: item, drifted: changedID)
            ledgerRecords.removeAll { $0.ownerBundleID == owner }
            ledgerRecords.append(restored)

            // 当前内存也可能已经误归入隐藏区，单纯 rename 不足以纠正它。
            for id in adopted.configuredIDs(ofOwner: owner) { adopted.remove(itemID: id) }
            restoreItem(item.id, to: zone, aliases: restored.aliases, from: committed, into: &adopted)
        }
    }

    /// 只给重新出现的项恢复位置；仍在布局中的项（包括新用户决定）不随扫描重排。
    private func restoreItem(_ itemID: String, to zone: MenuBarZone, aliases: [String],
                             from committed: MenuBarLayout?, into adopted: inout MenuBarLayout) {
        guard adopted.zone(of: itemID) == nil else { return }
        let savedIDs = aliases.filter { committed?.zone(of: $0) == zone }
        guard let committed, savedIDs.count == 1, let savedID = savedIDs.first,
              let savedPosition = committed.position(of: savedID) else {
            adopted.append(itemID, to: zone)
            return
        }
        let members = adopted.items(in: zone)
        let savedOrder = committed.items(in: zone)
        func currentPosition(of id: String) -> Int? {
            if let index = members.firstIndex(of: id) { return index }
            let matches = ledgerRecords.filter { $0.aliases.contains(id) }
            guard matches.count == 1, let record = matches.first else { return nil }
            let indices = members.indices.filter { record.aliases.contains(members[$0]) }
            return indices.count == 1 ? indices.first : nil
        }
        // 多项按任意枚举顺序返回时，已恢复的项也会成为下一项的前后锚点。
        let next = savedOrder.dropFirst(savedPosition + 1).lazy.compactMap(currentPosition).first
        let previous = savedOrder.prefix(savedPosition).reversed().lazy.compactMap(currentPosition).first
        adopted.move(itemID: itemID, to: zone,
                     position: next ?? previous.map { $0 + 1 } ?? min(savedPosition, members.count))
    }

    var pendingIntent: LayoutJournal.LayoutIntent? {
        guard let intent = journal.readPendingIntent(), !journal.hasCommitted(intent) else { return nil }
        return intent
    }

    /// 待恢复操作使用同一条已确认身份链；事务 ID、时间和重试次数保持不变。
    private func synchronizePendingIdentity(observedIDs: Set<String>) {
        guard let intent = journal.readPendingIntent(),
              let currentID = observedID(for: intent.itemID, in: observedIDs), currentID != intent.itemID else { return }
        do { try journal.writeIntent(intent.renamed(to: currentID)) }
        catch { fprint("待恢复图标身份暂未保存：\(error)") }
    }

    private func observedID(for savedID: String, in observedIDs: Set<String>) -> String? {
        if observedIDs.contains(savedID) { return savedID }
        let matches = ledgerRecords.filter {
            $0.aliases.contains(savedID) && observedIDs.contains($0.currentID)
        }
        return matches.count == 1 ? matches.first?.currentID : nil
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
        guard !ManagedItem.isSystemOwned(itemID: itemID) else { return }
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

        guard capability == .fullDrag, let mover = services.mover else {
            capability = .panelOnlyFallback
            capabilityReason = "⌘ 拖拽不可用，布局仅在收纳面板内生效"
            try commit(intent)
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
            try commit(intent)
        } catch let error as MenuBarMoveError {
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
        let elapsed = clock().timeIntervalSince(lastOperationAt)
        let remaining = min(sentinel.minIntervalBetweenOperations,
                            max(0, sentinel.minIntervalBetweenOperations - elapsed))
        if remaining > 0 {
            Thread.sleep(forTimeInterval: remaining)
            if cursor.isPrimaryButtonPressed { throw EngineError.sentinelAborted(.userInteracting) }
        }

        let beforeItem = services.reader.item(withID: itemID)
        do {
            _ = try mover.move(itemID: itemID, toX: x)
        } catch let error as MenuBarMoveError {
            if error == .unsupportedOS {
                markDraggingUnsupported()
            }
            throw error
        }

        guard let landed = awaitMovementLanded(itemID: itemID, beforeItem: beforeItem, towardX: x) else {
            throw EngineError.verificationUnavailable(itemID: itemID)
        }
        if !landed {
            throw EngineError.noVisibleEffect(itemID: itemID)
        }

        lastOperationAt = clock()
        if let beforeItem, abs(x - beforeItem.centerX) > 3 {
            hasConfirmedDragSupport = true
        }
    }

    /// 复核的是**结果**（图标真的挪到位了吗），不是光标。
    /// macOS 对落在空隙里的拖拽是静默忽略的，只有查结果能发现"没成"。
    ///
    /// 必须轮询而不是读一次：真机 35 图标在栏时，抬起后那一瞬间读到的常常还是旧位置
    /// （菜单栏重排是异步的），单次读帧会把"还没落位"误判成"系统没接受"。
    /// 一旦读到真的动了就立刻返回，所以**成功路径不付额外延迟**，只有失败/慢的情况才会用尽窗口。
    /// 返回 nil 表示"无法判定"，调用方必须与已确认成功区分。
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
    public func recordZoneOnly(itemID: String, zone: MenuBarZone, position: Int? = nil,
                               supersedingPending: Bool = false) throws {
        let previous = layout
        let superseded = supersedingPending ? journal.readPendingIntent() : nil
        if let superseded, !journal.hasCommitted(superseded) { restorePreviousLayout(superseded) }
        layout.move(itemID: itemID, to: zone, position: position)
        do { try persistCommittedLayout(completing: superseded) }
        catch {
            layout = previous
            throw error
        }
        if superseded != nil {
            do { try journal.clearPendingIntent() }
            catch { fprint("分区已保存，旧恢复标记暂未清理：\(error)") }
        }
    }

    /// 用户分配在提交时同步到台账，不能等下一帧扫描才补写。
    /// pending 的清理由调用方在全部持久化成功之后执行。
    private func persistCommittedLayout(completing intent: LayoutJournal.LayoutIntent? = nil) throws {
        let handled = journal.readPendingIntent().flatMap { journal.hasCommitted($0) ? $0 : nil }
        try journal.writeCommitted(layout, completing: intent ?? handled)
        for index in ledgerRecords.indices {
            if let zone = layout.zone(of: ledgerRecords[index].currentID) {
                ledgerRecords[index].zoneRaw = zone.rawValue
            }
        }
        do { try ledgerStore?.save(ledgerRecords) }
        catch { fprint("布局已保存，身份台账暂未写入：\(error)") }
    }

    private func commit(_ intent: LayoutJournal.LayoutIntent) throws {
        do { try persistCommittedLayout(completing: intent) }
        catch {
            restorePreviousLayout(intent)
            throw error // 保留 pending，不能把写失败的分区当作成功发布。
        }
        try journal.clearPendingIntent()
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
        restorePreviousLayout(intent)
        try? journal.clearPendingIntent()
    }

    private func restorePreviousLayout(_ intent: LayoutJournal.LayoutIntent) {
        if let previousZone = intent.previousZone {
            layout.move(itemID: intent.itemID, to: previousZone, position: intent.previousPosition)
        } else {
            layout.remove(itemID: intent.itemID)
        }
    }

    // MARK: - 启动恢复

    /// 应用启动时调用：存在孤儿 pending 说明上次变更未完成，按其意图重放而非反推系统状态。
    public func recoverOnLaunch() -> LayoutJournal.Recovery {
        let committed = journal.readCommittedLayout()
        let pending = journal.readPendingIntent()
        if let pending, journal.hasCommitted(pending), let committed {
            layout = committed
            try? journal.clearPendingIntent()
            return .clean(committed)
        }
        if let pending, pending.replayFailures >= maxReplayAttempts {
            discardPendingIntent()
            return .clean(layout)
        }
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
        let pending = journal.readPendingIntent()
        let committed = journal.readCommittedLayout() ?? MenuBarLayout()
        layout = committed
        // 已确认的改名仍有效，但被放弃的目标分区不能留在台账里。
        for index in ledgerRecords.indices {
            let configured = ledgerRecords[index].aliases.filter { committed.zone(of: $0) != nil }
            guard configured.count == 1, let previousID = configured.first,
                  let zone = committed.zone(of: previousID) else { continue }
            ledgerRecords[index].zoneRaw = zone.rawValue
            layout.rename(id: previousID, to: ledgerRecords[index].currentID)
        }
        do {
            // “放弃”同样是已结束的事务，先保存结果再删除恢复依据。
            try persistCommittedLayout(completing: pending)
            try journal.clearPendingIntent()
        } catch {
            fprint("恢复已停止，放弃结果暂未完全保存：\(error)")
        }
    }

    /// 把上次未完成的意图沿**产品主路径**重做一遍。
    ///
    /// 与 apply 的区别只在 pending 的生死：replay 成功前不清除意图，失败时原样留在盘上，
    /// 让下一次启动还能重试；是否还要重试由 `noteReplayFailure()` 决定。
    /// 走 performDrag 而不是自己拼一遍流程，是为了让"重放成功"和"用户手动整理成功"
    /// 是同一条链路的同一个结论。
    public func replay(_ intent: LayoutJournal.LayoutIntent) throws {
        if capability == .panelOnlyFallback {
            layout.move(itemID: intent.itemID, to: intent.targetZone, position: intent.targetPosition)
            try commit(intent)
            return
        }
        guard let mover = services.mover, !(mover is UnverifiedMenuBarMover) else {
            throw EngineError.noMovementCapability
        }
        guard let x = targetProvider?(intent.itemID, intent.targetZone) else {
            throw EngineError.noMovementCapability
        }
        try journal.writeIntent(intent)
        try performDrag(mover: mover, itemID: intent.itemID, x: x)
        layout.move(itemID: intent.itemID, to: intent.targetZone, position: intent.targetPosition)
        try commit(intent)
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
        // 达到上限或写盘异常。两种都先持久化放弃结果，再清除恢复依据。
        guard let updated = try? journal.noteReplayFailure(maxAttempts: maxReplayAttempts) else {
            discardPendingIntent()
            return .abandoned
        }
        return .retryScheduled(failures: updated.replayFailures)
    }

    /// 优雅退出只释放输入。明确分配、重放和取消已各自持久化；
    /// 当前布局可能来自空扫描或部分扫描，退出不能用它覆盖上次已提交的分配。
    /// 在途 pending 原样保留，交给下次启动恢复。
    public func prepareForTermination() {
        (services.mover as? DragReleasing)?.releaseInFlightDrag()
    }
}
