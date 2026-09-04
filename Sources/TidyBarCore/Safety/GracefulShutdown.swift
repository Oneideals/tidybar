import Foundation

/// 信号收尾：把「进程被要求结束」变成一次可解释、可清理的退出。
///
/// 来源是验证项 3 的真机结论：SIGTERM 与 kill -9 一样会留下孤儿意图 —— Swift 的 `defer`
/// 不响应信号，而 `applicationWillTerminate` 只在走 NSApp 正常终止流程时才保证被调用，
/// 注销/launchd 回收发来的 SIGTERM 未必会经过它。所以显式挂 DispatchSource 信号源。
///
/// 分工要说清楚（避免把功劳记错）：
///   - 真机已证明 macOS 会在进程死亡时回收其事件源状态，所以「卡键」不是这里防出来的；
///   - 这里真正买到的是三件事：半空的拖拽被确定性地抬起（不等内核回收）、
///     布局与设置落盘不丢最后一次变更、退出原因留下可读记录。
public final class GracefulShutdown {
    public struct Config: Sendable {
        /// 三类"礼貌结束"：注销/关机走 TERM，终端关闭或 launchd 回收走 HUP，Ctrl-C 走 INT。
        /// SIGKILL 不在列——它不可捕获，正是 LayoutJournal 存在的理由。
        public var signals: [Int32]
        public var queueLabel: String

        public init(
            signals: [Int32] = [SIGTERM, SIGHUP, SIGINT],
            queueLabel: String = "local.tidybar.shutdown"
        ) {
            self.signals = signals
            self.queueLabel = queueLabel
        }
    }

    /// 收尾回调运行在哪个队列。默认是专用串行队列，因此测试不依赖主 runloop 被排空；
    /// 需要碰 AppKit 的调用方自己在回调里 DispatchQueue.main.async 过去。
    public enum Delivery: Sendable {
        case dedicatedQueue
        case main
    }

    public private(set) var isArmed = false
    /// 触发收尾的信号；同一次运行里只记第一个
    public private(set) var receivedSignal: Int32?

    private let config: Config
    private let delivery: Delivery
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var handled = false

    public init(config: Config = Config(), delivery: Delivery = .dedicatedQueue) {
        self.config = config
        self.delivery = delivery
    }

    deinit {
        disarm()
    }

    // MARK: - 挂载 / 卸载

    /// 挂上信号源。handler 在每次运行中最多被调用一次，参数是触发它的那个信号。
    /// 注意：arm 会把对应信号的默认处置改成 SIG_IGN（DispatchSource 的前置要求），
    /// disarm 会还原成 SIG_DFL，避免"卸载后连 kill 都杀不死"这种更糟的状态。
    ///
    /// 排查时踩过的坑，写给下一个改这块的人：**只有进程级投递才会走到这里**。
    /// `raise()` 是线程级投递，处置为 SIG_IGN 时信号当场被丢弃，信号源永不触发——
    /// 用它写出来的"没触发"看起来像实现有 bug，其实是测试发错地方了。
    /// 测试一律用 `kill(getpid(), sig)`（参数顺序也别写反，反了等于给别的进程发信号）。
    public func arm(handler: @escaping (Int32) -> Void) {
        let queue: DispatchQueue
        switch delivery {
        case .main: queue = DispatchQueue.main
        case .dedicatedQueue: queue = DispatchQueue(label: config.queueLabel)
        }

        lock.lock()
        guard !isArmed else { lock.unlock(); return }
        isArmed = true
        let made = config.signals.map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.fire(signal: sig, handler: handler) }
            source.resume()
            return source
        }
        sources = made
        lock.unlock()
    }

    public func disarm() {
        lock.lock()
        guard isArmed else { lock.unlock(); return }
        let old = sources
        sources = []
        isArmed = false
        let restored = config.signals
        lock.unlock()

        old.forEach { $0.cancel() }
        restored.forEach { signal($0, SIG_DFL) }
    }

    // MARK: - 私有

    private func fire(signal sig: Int32, handler: (Int32) -> Void) {
        lock.lock()
        if handled {
            lock.unlock()
            return
        }
        handled = true
        receivedSignal = sig
        lock.unlock()
        handler(sig)
    }
}
