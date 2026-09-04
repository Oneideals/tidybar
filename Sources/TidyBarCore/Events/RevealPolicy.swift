import Foundation

/// 呼出方式（报告 A4）。四种均可选，可组合。
public enum RevealTrigger: String, Codable, CaseIterable, Sendable {
    /// 点击分隔符
    case dividerClick
    /// 悬停在分隔符/空白区
    case hover
    /// 点击菜单栏空白区域
    case emptyBarClick
    /// 在菜单栏上滚动/横 Swipe
    case scrollOrSwipe
    /// 全局快捷键
    case hotkey

    /// 泛用户默认：只开点击与快捷键，避免悬停误触发造成的「图标乱跳」观感
    public static var beginnerDefaults: Set<RevealTrigger> { [.dividerClick, .hotkey] }
}

/// 面板可见状态机。时间由外部注入，便于单测与「自动重隐藏」精度验证。
public final class RevealStateMachine {
    public enum Visibility: Equatable {
        case hidden
        case revealed(by: RevealTrigger)
    }

    public private(set) var visibility: Visibility = .hidden
    /// 自动重新隐藏延迟（报告 A6：默认 2s，可调 0-10s；0 表示不自动收起）
    public let rehideDelay: TimeInterval

    /// 演示模式（P1-C3）：进入后强制隐藏一切非系统图标，且忽略自动重显示
    public private(set) var isDemoMode: Bool = false

    private var revealedAt: Date?

    public init(rehideDelay: TimeInterval = 2.0) {
        self.rehideDelay = rehideDelay
    }

    public var isRevealed: Bool {
        if case .revealed = visibility { return true }
        return false
    }

    /// 是否应忽略悬停类触发（光标尚在面板内时不该反复重绘）
    public func shouldAccept(trigger: RevealTrigger) -> Bool {
        if isDemoMode { return trigger == .hotkey }
        switch trigger {
        case .hover:
            // 已展开时不重复响应悬停，避免计时被无限续期
            return !isRevealed
        default:
            return true
        }
    }

    @discardableResult
    public func reveal(by trigger: RevealTrigger, at date: Date = Date()) -> Bool {
        guard shouldAccept(trigger: trigger) else { return false }
        visibility = .revealed(by: trigger)
        revealedAt = date
        return true
    }

    public func conceal() {
        visibility = .hidden
        revealedAt = nil
    }

    /// 到点即应收起的判定（真正的定时器由 App 层驱动，这里只做决策）
    public func shouldAutoConceal(at date: Date) -> Bool {
        guard isRevealed, rehideDelay > 0, !isDemoMode else { return false }
        guard let revealedAt else { return false }
        return date.timeIntervalSince(revealedAt) >= rehideDelay
    }

    /// 剩余可见时间，用于进度指示与性能测试
    public func remainingRevealTime(at date: Date) -> TimeInterval? {
        guard isRevealed, rehideDelay > 0, let revealedAt else { return nil }
        return max(0, rehideDelay - date.timeIntervalSince(revealedAt))
    }

    public func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        if enabled { conceal() }
    }
}
