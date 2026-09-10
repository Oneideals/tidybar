import Foundation
import CoreGraphics

public enum MenuBarHitOutcome: Equatable, Sendable { case verified, occluded, unavailable }

/// 系统能力边界。全部以协议形式暴露，好处有二：
/// 1. 上层布局/规则/安全逻辑可在无权限、无 GUI 的环境下 100% 单测；
/// 2. M0 技术验证阶段可以逐替换实现（辅助功能 / 合成事件 / 屏幕采样），而不牵动业务层。

/// 只读：枚举当前菜单栏图标及其位置
public protocol MenuBarReading: AnyObject {
    /// 当前系统菜单栏上的第三方 + 系统图标快照（屏幕坐标）
    func discoverItems() -> [ManagedItem]

    /// 定向读取某个进程的图标（真机实测全量枚举 110~195ms、首次 2.6s；
    /// 单进程只要几毫秒）。验证一次拖拽是否生效只需要归属进程那一小撮图标，
    /// 没理由再付一次全量成本。
    func items(ownedBy bundleID: String) -> [ManagedItem]
    func item(withID id: String) -> ManagedItem?
    func currentFrame(of item: ManagedItem) -> CGRect?

    /// 验证真实投递坐标命中状态项。nil 只允许本次已识别的状态项，不能是应用主菜单。
    func hitTest(expected item: ManagedItem?, at point: CGPoint) -> MenuBarHitOutcome
    /// 只读验证目标的原生菜单是否仍在屏幕上。nil 表示当前无法确认。
    func isMenuPresented(for item: ManagedItem) -> Bool?
}

public extension MenuBarReading {
    func item(withID id: String) -> ManagedItem? { discoverItems().first { $0.id == id } }
    func currentFrame(of item: ManagedItem) -> CGRect? { self.item(withID: item.id)?.frame }
    /// 替身/简易实现默认回退到全量扫描，真实 reader 会覆盖为定向读取
    func items(ownedBy bundleID: String) -> [ManagedItem] {
        discoverItems().filter { $0.ownerBundleID == bundleID }
    }

    // 离线替身没有 AX 树；真实读取器必须用具体元素验证命中。
    func hitTest(expected item: ManagedItem?, at point: CGPoint) -> MenuBarHitOutcome { .verified }
    func isMenuPresented(for item: ManagedItem) -> Bool? { nil }
}

/// 写：把某个图标从起点 ⌘ 拖拽到目标 X。
/// 实现方必须在内部使用 `CursorReading` 做前后对照，异常时抛 `.aborted`。
public protocol MenuBarMoving: AnyObject {
    /// 把 itemID 移动到目标 x 坐标；返回真实落点供复核
    @discardableResult
    func move(itemID: String, toX targetX: CGFloat) throws -> CGPoint

    /// 后台整理可在当前拖拽中取消；真实输入实现须逐步检查。
    @discardableResult
    func move(itemID: String, toX targetX: CGFloat, expectedTargets: [ManagedItem]?, isCancelled: () -> Bool) throws -> CGPoint
}

public extension MenuBarMoving {
    @discardableResult
    func move(itemID: String, toX targetX: CGFloat, isCancelled: () -> Bool) throws -> CGPoint {
        try move(itemID: itemID, toX: targetX, expectedTargets: nil, isCancelled: isCancelled)
    }

    @discardableResult
    func move(itemID: String, toX targetX: CGFloat, expectedTargets: [ManagedItem]?, isCancelled: () -> Bool) throws -> CGPoint {
        guard !isCancelled() else { throw MenuBarMoveError.dragInterrupted }
        return try move(itemID: itemID, toX: targetX)
    }
}

/// 点击转发的结果。面板里点一个图标，必须等效于在菜单栏点它（报告 A3）；
/// 等效不了就要说清是哪一类"等效不了"，不能只回一句"失败"。
public enum ActivationOutcome: Equatable, Sendable {
    case busy
    case queued
    case menuPresented
    case menuObservationUnavailable
    case notInteractable
    case interrupted
    /// 已发送点击；只有 menuPresented 才代表已观察到原生菜单。
    case pressed
    /// 当前扫描里没有这个图标（App 大概已退出）
    case itemNotFound
    /// 逻辑 id 认得，但按归属进程 + 序号找不到对应元素（顺序刚变过）
    case elementNotFound
    /// 该元素不接受 AXPress——确实有自绘状态项不支持
    case actionUnsupported
    /// 动作已生效但目标没回回执：带菜单的状态项在 AXPress 后会进入模态跟踪循环，
    /// 系统常返回 kAXErrorCannotComplete(-25204)。真机实测**菜单确实开了**，
    /// 所以这一类不能报成"点击被拒绝"，否则用户会以为没点上而重复操作。
    case pressedUnconfirmed(code: Int)
    /// 系统返回了明确的错误码
    case failed(code: Int)

    public var userReadable: String {
        switch self {
        case .busy: return "菜单栏正在整理，请稍后再试"
        case .queued: return "正在打开菜单栏图标"
        case .menuPresented: return "已打开原生菜单"
        case .menuObservationUnavailable: return "暂时无法确认菜单状态，已保持展开；点击 TidyBar 按钮可收起"
        case .notInteractable: return "图标当前被遮挡，请展开菜单栏后直接点击图标"
        case .interrupted: return "点击已暂停，请停止操作鼠标后重试"
        case .pressed: return "已点击"
        case .itemNotFound: return "图标已不在菜单栏上"
        case .elementNotFound: return "图标位置刚发生变化，请再点一次"
        case .actionUnsupported: return "这个 App 不允许工具代点，请直接在菜单栏点击"
        case .pressedUnconfirmed: return "已发送点击，目标未返回结果"
        case .failed(let code): return "系统拒绝了这次点击（错误码 " + String(code) + "）"
        }
    }
}

/// 点击转发：把收纳面板/搜索面板里的一次点击打到真实菜单栏图标上。
/// 与读取、移动分列协议，是因为"能读到"不等于"能点到"（实测就有不支持 AXPress 的自绘项）。
public protocol MenuBarActivating: AnyObject {
    @discardableResult
    func activate(itemID: String) -> ActivationOutcome
    @discardableResult
    func showMenu(itemID: String) -> ActivationOutcome
}

extension MenuBarActivating {
    /// 右键语义不能用左键代替；没有实现就明确返回不支持。
    @discardableResult
    public func showMenu(itemID: String) -> ActivationOutcome { .actionUnsupported }
}

extension ActivationOutcome {
    /// 是否应当按"点到了"处理：UI 反馈与诊断都以此为准，而不是只看 .pressed
    public var countsAsPressed: Bool {
        switch self {
        case .queued, .pressed, .pressedUnconfirmed, .menuPresented, .menuObservationUnavailable: return true
        case .busy, .notInteractable, .interrupted, .itemNotFound, .elementNotFound, .actionUnsupported, .failed: return false
        }
    }
}

/// 可被打断收尾的移动器：进程被要求退出时，把悬在半空的按下就地抬起。
/// 单独成协议是为了让装配层只写 `(mover as? DragReleasing)?.releaseInFlightDrag()`，
/// 占位实现与假拖拽器不必为了「根本不发输入事件」而假装能收尾。
public protocol DragReleasing: AnyObject {
    var isDragInFlight: Bool { get }
    func releaseInFlightDrag()
}

/// 移动失败原因
public enum MenuBarMoveError: Error, Equatable {
    case sessionUnavailable
    case sourceNotInteractable(String)
    case targetNotInteractable
    /// 哨兵预检未通过（光标漂移 / 用户在操作 / 节流）
    case abortedBySentinel(EventSentinel.Verdict)
    /// 目标图标已消失（App 退出）
    case itemVanished(String)
    /// 当前系统版本下机制不可用 → 上层应降级为「仅收纳面板」模式（报告 §4.4 风险表）
    case unsupportedOS
    /// 拖拽进行中被外部收尾（优雅退出抢先抬起了按下）。
    /// 必须立刻收手：继续走完会再抬一次鼠标键，并把一次没做完的变更报成成功。
    case dragInterrupted
}

/// 光标与输入设备状态读取（EventSentinel 的输入源）
public protocol CursorReading: AnyObject {
    var currentLocation: CGPoint { get }
    var isPrimaryButtonPressed: Bool { get }
    var isSecondaryButtonPressed: Bool { get }
    var isSessionInteractive: Bool { get }
    /// CG 全局坐标中的显示器边界；nil 表示替身未提供，空字典表示读取失败。
    var displayConfiguration: [CGDirectDisplayID: CGRect]? { get }
    var userIdleTime: TimeInterval { get }
}

public extension CursorReading {
    var isSecondaryButtonPressed: Bool { false }
    var isSessionInteractive: Bool { true }
    var displayConfiguration: [CGDirectDisplayID: CGRect]? { nil }
    var userIdleTime: TimeInterval { .infinity }
}

/// 辅助功能权限
public protocol AccessibilityTrustReading: AnyObject {
    var isTrusted: Bool { get }
    /// 触发系统授权弹窗（首启向导 B1 使用）
    func requestTrust()
}

/// 屏幕信息（刘海、菜单栏高度、多显示器），面板定位与刘海避让依赖它
public struct ScreenInfo: Equatable, Sendable {
    public let identifier: CGDirectDisplayID
    public let frame: CGRect
    /// 菜单栏占据的高度（Tahoe 下随壁纸/透明度变化，需运行时读取）
    public let menuBarHeight: CGFloat
    /// 内建屏幕刘海宽度；非刘海屏为 nil
    public let notchWidth: CGFloat?
    /// 背板缩放（Retina 为 2）。抓图必须按像素算，用点算会让缓存字节数低估一半。
    public let scaleFactor: Double
    public let isBuiltin: Bool

    public init(
        identifier: CGDirectDisplayID,
        frame: CGRect,
        menuBarHeight: CGFloat,
        notchWidth: CGFloat?,
        isBuiltin: Bool,
        scaleFactor: Double = 2
    ) {
        self.identifier = identifier
        self.frame = frame
        self.menuBarHeight = menuBarHeight
        self.notchWidth = notchWidth
        self.isBuiltin = isBuiltin
        self.scaleFactor = scaleFactor
    }

    public var hasNotch: Bool { notchWidth != nil }

    /// 图标可安全停留的最大右边界：刘海屏需从屏幕右侧扣除刘海遮挡区（报告 B3）
    public var safeMenuBarRightEdge: CGFloat {
        guard let notchWidth, notchWidth > 0 else { return frame.maxX }
        // 刘海居中，左右各占一半；可见区右界收缩到刘海左缘
        return frame.midX - (notchWidth / 2)
    }
}

public protocol ScreenObserving: AnyObject {
    var screens: [ScreenInfo] { get }
    var primaryScreen: ScreenInfo? { get }
    func addObserver(_ observer: @escaping @Sendable () -> Void)
}

/// 真实实现的装配入口。
/// M0 之前，`Placeholder` 实现保证应用可跑通「面板 + 手动分区」链路，
/// 而 ⌘ 拖拽相关能力默认关闭，避免在未验证的系统版本上制造幽灵点击。
public struct SystemServices {
    public let reader: MenuBarReading
    public let mover: MenuBarMoving?
    /// nil 表示这套装配尚未接通点击转发。此时面板点击必须明确报"未接通"，不得假装成功。
    public let activator: MenuBarActivating?
    public let cursor: CursorReading
    public let accessibility: AccessibilityTrustReading
    public let screens: ScreenObserving

    public init(
        reader: MenuBarReading,
        mover: MenuBarMoving?,
        cursor: CursorReading,
        accessibility: AccessibilityTrustReading,
        screens: ScreenObserving,
        activator: MenuBarActivating? = nil
    ) {
        self.reader = reader
        self.mover = mover
        self.activator = activator
        self.cursor = cursor
        self.accessibility = accessibility
        self.screens = screens
    }
}
