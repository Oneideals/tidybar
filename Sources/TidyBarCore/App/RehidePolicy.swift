import Foundation
import CoreGraphics

/// 浮现回收判定纯函数策略（离线 100% 可测）。
public enum RehidePolicy {
    /// 判定是否应当将浮现的图标收回隐藏区。
    ///
    /// 规则：
    /// 1. rehideDelay <= 0：用户设置为「从不自动收起」，返回 false；
    /// 2. isMenuPresented 为 true 或 nil（无法观测，按打开处理，防止误关自定义面板）：返回 false；
    /// 3. isMouseDown 为 true（用户正按着鼠标）：返回 false；
    /// 4. 光标落在图标帧内（用户正悬停在图标上）：返回 false；
    /// 5. 距最近一次交互时间未超过 rehideDelay：返回 false；
    /// 6. 满足以上全部条件后，返回 true。
    public static func shouldRehide(
        now: Date,
        lastInteractionAt: Date,
        rehideDelay: TimeInterval,
        isMenuPresented: Bool?,
        isMouseDown: Bool,
        cursorLocation: CGPoint,
        itemFrame: CGRect
    ) -> Bool {
        guard rehideDelay > 0 else { return false }
        guard isMenuPresented == false else { return false }
        guard !isMouseDown else { return false }
        guard !itemFrame.contains(cursorLocation) else { return false }
        guard now.timeIntervalSince(lastInteractionAt) >= rehideDelay else { return false }
        return true
    }
}
