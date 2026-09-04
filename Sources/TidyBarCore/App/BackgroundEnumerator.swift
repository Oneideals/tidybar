import Foundation

/// 后台枚举调度器。
///
/// 存在理由（M0 实测）：全量枚举冷启动 ≈2.6s、稳态 p50 ≈110ms。若在主线程直接扫，
/// 不仅击穿"启动到接管 2s"的预算，还会让工具在启动瞬间卡住整个菜单栏交互——
/// 这正是用户最反感的"常驻工具反而添堵"。因此：扫描一律离开主线程，且按事件去抖。
public final class BackgroundEnumerator {
    public struct Stats: Equatable, Sendable {
        public var runs: Int
        public var coalesced: Int
        public init(runs: Int, coalesced: Int) {
            self.runs = runs
            self.coalesced = coalesced
        }
    }

    public private(set) var stats = Stats(runs: 0, coalesced: 0)

    private let queue: DispatchQueue
    private let clock: () -> Date
    private var lastStartedAt: Date?
    private var pendingReasons: [EnumerationCadence.Trigger] = []

    /// qos 用 utility：枚举是后台整理工作，不该抢用户交互的优先级
    public init(qos: DispatchQoS = .utility, clock: @escaping () -> Date = Date.init) {
        self.queue = DispatchQueue(label: "local.tidybar.enumeration", qos: qos)
        self.clock = clock
    }

    /// 请求一次刷新。同一去抖窗口内的多次请求会被合并（记进 stats）。
    /// - Parameters:
    ///   - scan: 真正耗时的枚举，在后台线程执行
    ///   - apply: 结果回主线程落地
    public func request(
        reason: EnumerationCadence.Trigger,
        scan: @escaping @Sendable () -> [ManagedItem],
        apply: @escaping @Sendable ([ManagedItem]) -> Void
    ) {
        let now = clock()
        guard EnumerationCadence.shouldRefresh(lastRefreshAt: lastStartedAt, now: now) else {
            if !pendingReasons.contains(reason) { pendingReasons.append(reason) }
            stats.coalesced += 1
            scheduleDeferred(scan: scan, apply: apply)
            return
        }
        run(scan: scan, apply: apply)
    }

    private func run(scan: @escaping @Sendable () -> [ManagedItem], apply: @escaping @Sendable ([ManagedItem]) -> Void) {
        lastStartedAt = clock()
        stats.runs += 1
        queue.async {
            let items = scan()
            DispatchQueue.main.async {
                apply(items)
                if !self.pendingReasons.isEmpty {
                    self.pendingReasons.removeAll()
                    // 期间攒下来的请求说明状态确实变了，补扫一次，避免停留在旧快照
                    self.run(scan: scan, apply: apply)
                }
            }
        }
    }

    /// 去抖窗口内被合并的请求，等窗口过后补扫
    private func scheduleDeferred(scan: @escaping @Sendable () -> [ManagedItem], apply: @escaping @Sendable ([ManagedItem]) -> Void) {
        let remaining = EnumerationCadence.debounceInterval - (clock().timeIntervalSince(lastStartedAt ?? clock()))
        queue.asyncAfter(deadline: .now() + max(0.05, remaining)) { [weak self] in
            guard let self, !self.pendingReasons.isEmpty else { return }
            DispatchQueue.main.async {
                guard !self.pendingReasons.isEmpty else { return }
                self.pendingReasons.removeAll()
                self.run(scan: scan, apply: apply)
            }
        }
    }
}
