import Foundation
import CoreGraphics

/// 事件哨兵：全品类翻车点（Bartender 5/6 在 Tahoe 上的幽灵点击、光标劫持）的防线。
///
/// 原则：任何一次合成事件前后，都必须确认「真实光标仍在我们放置的位置」且
/// 「用户没有按下实体鼠标/触控板」。一旦不成立立即中止并回滚，绝不让图标管理失控。
/// 对应报告 §4.2-2 与功能 F3。
public struct EventSentinel: Sendable {
    /// 允许的光标漂移容差（点）；超过即判定被系统/用户接管
    public let driftTolerance: CGFloat
    /// 两次布局操作之间的最小间隔，避免与真实用户手势打架
    public let minIntervalBetweenOperations: TimeInterval

    public enum Verdict: Equatable, Sendable {
        /// 安全，可以继续
        case clear
        /// 检测到光标漂移（携带漂移距离与当前光标位置）
        case cursorDrift(CGFloat, CGPoint)
        /// 用户正在操作输入设备，必须让位
        case userInteracting
        /// 操作过于频繁，需排队
        case throttled
    }

    public init(driftTolerance: CGFloat = 4.0, minIntervalBetweenOperations: TimeInterval = 0.05) {
        self.driftTolerance = driftTolerance
        self.minIntervalBetweenOperations = minIntervalBetweenOperations
    }

    /// 执行一次合成事件前的预检。
    /// - Parameters:
    ///   - expectedCursor: 我们期望光标所在处（通常是拖拽起点）
    ///   - actualCursor: 系统报告的真实光标位置
    ///   - isMouseDown: 用户是否正按住鼠标/触控板
    ///   - elapsedSinceLastOperation: 距上次布局操作的间隔
    public func preflight(
        expectedCursor: CGPoint,
        actualCursor: CGPoint,
        isMouseDown: Bool,
        elapsedSinceLastOperation: TimeInterval
    ) -> Verdict {
        if isMouseDown { return .userInteracting }
        let drift = EventSentinel.distance(from: expectedCursor, to: actualCursor)
        if drift > driftTolerance { return .cursorDrift(drift, actualCursor) }
        if elapsedSinceLastOperation < minIntervalBetweenOperations { return .throttled }
        return .clear
    }

    /// 合成事件后的复核：事件若被系统改写（例如被重定向到别的 App），会表现为落点异常
    public func postflight(cursorAfterEvent: CGPoint, expectedLanding: CGPoint) -> Verdict {
        let drift = EventSentinel.distance(from: expectedLanding, to: cursorAfterEvent)
        return drift > driftTolerance ? .cursorDrift(drift, cursorAfterEvent) : .clear
    }

    public static func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
