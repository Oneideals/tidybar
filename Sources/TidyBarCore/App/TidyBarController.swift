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
    private var items: [ManagedItem] = []

    public init(
        engine: LayoutEngine,
        reveal: RevealStateMachine,
        settings: AppSettings,
        store: SettingsStoring,
        ruleEngine: RuleEngine = RuleEngine()
    ) {
        self.engine = engine
        self.reveal = reveal
        self.settings = settings.sanitized()
        self.store = store
        self.ruleEngine = ruleEngine
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
    public var capabilityReason: String? { engine.capabilityReason }

    // MARK: - 启动

    /// 启动即恢复上次状态；孤儿意图按设置决定重放还是丢弃（报告 B4）
    @discardableResult
    public func start(now: Date = Date(), scansSynchronously: Bool = true) -> LayoutJournal.Recovery {
        let recovery = engine.recoverOnLaunch()
        if case .interrupted(let intent, _) = recovery, !settings.autoRecoverPendingIntent {
            engine.discardPendingIntent()
            record("放弃上次未完成的布局变更：\(intent.itemID) → \(intent.targetZone.displayLabel)")
        }
        // 真机枚举耗时 2.6s，装配层应传 false 并把扫描交给 BackgroundEnumerator
        if scansSynchronously { refreshItems() }
        return recovery
    }

    public func refreshItems() {
        items = engine.synchronize(newItemZone: settings.newItemZone)
        publish()
    }

    /// 落地一次后台扫描的结果（调用方负责在主线程回调）
    public func applyScan(_ scanned: [ManagedItem]) {
        items = scanned
        engine.fold(ids: scanned.map(\.id), newItemZone: settings.newItemZone)
        publish()
    }

    // MARK: - 显隐

    /// 事件层入口：只响应用户开启的呼出方式
    public func handle(event: EventEngine.Event, at date: Date = Date()) {
        guard settings.revealTriggers.contains(event.trigger) else { return }
        if reveal.reveal(by: event.trigger, at: date) { publish() }
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
    public func move(_ itemID: String, to zone: MenuBarZone, targetX: CGFloat? = nil, position: Int? = nil, at date: Date = Date()) {
        do {
            try engine.apply(itemID: itemID, to: zone, targetX: targetX, targetPosition: position)
        } catch {
            record("布局变更未生效：\(error)")
        }
        publish()
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
            move(change.itemID, to: change.to, at: date)
        }
        return batch
    }

    // MARK: - 设置

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings = settings.sanitized()
        store.save(settings)
        publish()
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

    // MARK: - 搜索

    public func search(_ query: String, limit: Int = 12) -> [ManagedItem] {
        ItemSearch.rank(items, query: query, title: \.title, usageCount: { $0.lastActivatedAt == nil ? 0 : 1 })
            .prefix(limit)
            .map { $0 }
    }

    /// 搜索面板里激活某项：若处于隐藏区则先呼出，再由面板转发真实点击
    public func activate(itemID: String, at date: Date = Date()) {
        if engine.layout.zone(of: itemID) == .alwaysHidden {
            reveal.reveal(by: .hotkey, at: date)
        }
        publish()
    }

    // MARK: - 私有

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
