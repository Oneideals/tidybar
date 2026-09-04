import Foundation
import CoreGraphics

/// 一次 ⌘ 拖拽所需的最小事件词汇表。
///
/// 为什么不直接调 CGEvent：那是个不可测的黑洞——一旦哨兵判定要中止，"有没有真的发出事件"
/// 必须能被断言钉死（Bartender 的翻车正是"该停手时没停"）。所以这里把语义与投递分开：
/// mover 只负责决定"该发哪个事件、按什么顺序"，投递交给可替换的实现。
public enum DragEvent: Equatable, Sendable {
    /// 先把光标放到起点（不产生按压）
    case warp(CGPoint)
    case commandDown
    case mouseDown(CGPoint)
    case mouseDragged(CGPoint)
    case mouseUp(CGPoint)
    case commandUp
    /// 让系统消化上一步（菜单栏重排是异步的）
    case settle(TimeInterval)
}

public protocol DragEventPosting: AnyObject {
    /// 投递一个事件；失败必须可闻（返回 false 表示系统拒绝投递）
    @discardableResult
    func post(_ event: DragEvent) -> Bool
}

/// 真实投递：走 HID 层的 cghidEventTap。
///
/// 两个必须记住的细节：
///   1. CGEvent 用的是**左上原点、y 向下**的屏幕坐标，而项目内部统一用 AppKit 坐标，
///      这里必须显式换算，否则事件会飞到屏幕另一头（多屏/负原点机器上尤其致命）。
///   2. ⌘ 必须成对，异常路径下也要抬起，否则系统进入"⌘ 一直按着"的状态，
///      用户接下来每次点击都在触发快捷键——这是比拖错更严重的伤害。
public final class CGDragEventPoster: DragEventPosting {
    /// 鼠标事件是否自带 maskCommand。
    /// true = 双份信号（真实 ⌘ 键 + 每个鼠标事件的 flags）；
    /// false = 只靠真实 ⌘ 键事件。用于判别"⌘ 读数残留"究竟是卡键还是 flagsState 污染。
    public var carriesCommandFlagsOnMouseEvents: Bool
    private let primaryScreenHeight: CGFloat
    private let eventSource: CGEventSource?
    /// 记录最后一次由我们放下的位置，供哨兵复核
    public private(set) var lastEmittedPoint: CGPoint?

    public init(
        primaryScreenHeight: CGFloat,
        eventSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState),
        carriesCommandFlagsOnMouseEvents: Bool = true
    ) {
        self.primaryScreenHeight = primaryScreenHeight
        self.eventSource = eventSource
        self.carriesCommandFlagsOnMouseEvents = carriesCommandFlagsOnMouseEvents
    }

    @discardableResult
    public func post(_ event: DragEvent) -> Bool {
        switch event {
        case .warp(let point):
            // 不让系统顺手把事件重定向到新位置，先 warp 再按下更稳
            CGWarpMouseCursorPosition(appKitToCG(point))
            CGSFlushLocalCursorData?()
            lastEmittedPoint = point
            return true

        case .commandDown:
            return postKey(down: true)

        case .commandUp:
            return postKey(down: false)

        case .mouseDown(let point):
            lastEmittedPoint = point
            return postMouse(.leftMouseDown, at: point)

        case .mouseDragged(let point):
            lastEmittedPoint = point
            return postMouse(.leftMouseDragged, at: point)

        case .mouseUp(let point):
            lastEmittedPoint = point
            return postMouse(.leftMouseUp, at: point)

        case .settle(let seconds):
            // 用 nanosleep 而不是 Thread.sleep：更轻，且在后台队列上不会打乱主 runloop
            let microseconds = UInt32(max(0, seconds) * 1_000_000)
            if microseconds > 0 { usleep(microseconds) }
            return true
        }
    }

    private func appKitToCG(_ point: CGPoint) -> CGPoint {
        CGDragEventPoster.cgPoint(for: point, primaryScreenHeight: primaryScreenHeight)
    }

    /// AppKit(左下原点) → CG(左上原点) 的单点换算。
    /// 公开成静态函数，是为了让"符号写反"这种错误在离线用例里就变红——
    /// 真机上它的表现是事件飞到屏幕另一头，多屏/负原点时尤其难查。
    public static func cgPoint(for point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    private func postKey(down: Bool) -> Bool {
        // 0x38 = 左 Command（kVK_Command）
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 0x38,
            keyDown: down
        ) else { return false }
        event.flags = down ? [.maskCommand] : []
        event.post(tap: .cghidEventTap)
        return true
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) -> Bool {
        let cgPoint = appKitToCG(point)
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        ) else { return false }
        // 抬起必须不带 flags：实测带 maskCommand 的鼠标事件会改写**全局 session 修饰键状态**
        // （连没发过任何按键的新进程都读到 ⌘ 按下），若以 ⌘ 结尾，
        // 用户之后的普通点击就会变成 ⌘ 点击——这是必须收掉的尾巴。
        event.flags = (type == .leftMouseUp || !carriesCommandFlagsOnMouseEvents) ? [] : [.maskCommand]
        event.post(tap: .cghidEventTap)
        return true
    }
}

/// 可选的系统调用：warp 后立刻让光标数据生效，避免第一帧拖拽落在旧位置。
/// 该符号并非公开 API，取不到就退化为多一次 settle。
private let CGSFlushLocalCursorData: (() -> Void)? = {
    guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
    guard let symbol = dlsym(handle, "CGSFlushLocalCursorData") else { return nil }
    typealias Fn = @convention(c) () -> Void
    return unsafeBitCast(symbol, to: Fn.self)
}()

/// 测试用：只记录，不投递。用它才能断言"哨兵判定中止后一个事件都没发出去"。
public final class RecordingDragEventPoster: DragEventPosting {
    public private(set) var posted: [DragEvent] = []
    /// 让第 n 次投递失败，模拟系统拒绝或异常路径
    public var failAt: Int?

    /// 最后一次 mouseUp 的位置（断言"抬在目标点"用）
    public var lastUp: CGPoint? {
        posted.reversed().compactMap { event in
            if case .mouseUp(let point) = event { return point }
            return nil
        }.first
    }

    public init() {}

    @discardableResult
    public func post(_ event: DragEvent) -> Bool {
        posted.append(event)
        if let failAt, posted.count - 1 == failAt { return false }
        return true
    }

    public var dragPoints: [CGPoint] {
        posted.compactMap {
            switch $0 {
            case .mouseDown(let p), .mouseDragged(let p), .mouseUp(let p): return p
            default: return nil
            }
        }
    }

    public func contains(_ kind: String) -> Bool {
        posted.contains { event in
            switch (kind, event) {
            case ("warp", .warp), ("commandDown", .commandDown), ("commandUp", .commandUp),
                 ("mouseDown", .mouseDown), ("mouseDragged", .mouseDragged),
                 ("mouseUp", .mouseUp), ("settle", .settle):
                return true
            default:
                return false
            }
        }
    }
}
