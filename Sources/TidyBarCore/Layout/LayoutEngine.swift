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
    private var lastOperationAt: Date = .distantPast

    public init(
        layout: MenuBarLayout,
        services: SystemServices,
        journal: LayoutJournal,
        sentinel: EventSentinel = EventSentinel()
    ) {
        self.layout = layout
        self.services = services
        self.journal = journal
        self.sentinel = sentinel
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

    // MARK: - 同步

    /// 从系统重新读取图标并折叠进布局；新出现的图标按策略归位（报告 A7）。
    @discardableResult
    public func synchronize(newItemZone: MenuBarZone) -> [ManagedItem] {
        let discovered = services.reader.discoverItems()
        fold(ids: discovered.map(\.id), newItemZone: newItemZone)
        return discovered
    }

    /// 折叠「已在别处扫好」的图标集合。枚举真机耗时 2.6s，必须允许在后台线程做完再喂回来，
    /// 而不是强迫调用方在主线程里重扫一遍。
    public func fold(ids itemIDs: [String], newItemZone: MenuBarZone) {
        layout = MenuBarLayout.folding(discovered: itemIDs, into: layout, defaultZone: newItemZone)
    }

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

        guard let x = targetX ?? targetProvider?(itemID, zone) else {
            rollback(intent)
            throw EngineError.noMovementCapability
        }

        // 引擎层只保留两项自己该管的判定，光标的放置与飞行复核交给 mover（它才知道事件时序）：
        //   1. 用户正按住鼠标 → 现在绝不能动手；
        //   2. 操作节奏 → 防止规则引擎连环重排。
        // 注意：这里**不能**再拿"当前光标位置"与图标中心比较。验证项 2 已证伪这种写法：
        // 光标是我们稍后 warp 过去的，动手前它本来就不在图标上，比较的结果是永远中止。
        let cursor = services.cursor
        if cursor.isPrimaryButtonPressed {
            rollback(intent)
            throw EngineError.sentinelAborted(.userInteracting)
        }
        let elapsed = Date().timeIntervalSince(lastOperationAt)
        if elapsed < sentinel.minIntervalBetweenOperations {
            rollback(intent)
            throw EngineError.sentinelAborted(.throttled)
        }

        let beforeItem = services.reader.discoverItems().first { $0.id == itemID }
        do {
            _ = try mover.move(itemID: itemID, toX: x)

            // 复核的是**结果**（图标真的挪到位了吗），不是光标。
            // macOS 对落在空隙里的拖拽是静默忽略的，只有查结果能发现"没成"。
            // after 只做定向读取：验证一次变更只需要归属进程那一小撮图标，
            // 为此再付 110~195ms 的全量扫描既拖慢操作也白白耗电
            let candidates: [ManagedItem]
            if let owner = beforeItem?.ownerBundleID {
                candidates = services.reader.items(ownedBy: owner)
            } else {
                candidates = services.reader.discoverItems()
            }
            let afterFrame = candidates.first { $0.id == itemID }?.frame
            if let beforeFrame = beforeItem?.frame, let afterFrame,
               MenuBarDropTarget.didMove(before: beforeFrame, after: afterFrame, towardX: x) == false {
                rollback(intent)
                throw EngineError.noVisibleEffect(itemID: itemID)
            }

            lastOperationAt = Date()
            hasConfirmedDragSupport = true
            try journal.clearPendingIntent()
            try journal.writeCommitted(layout)
        } catch let error as MenuBarMoveError {
            if case .unsupportedOS = error {
                capability = .panelOnlyFallback
                capabilityReason = "系统返回不支持拖拽，已降级为收纳面板模式"
            }
            rollback(intent)
            throw EngineError.moveFailed(error)
        }
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
}
