import Foundation
import CoreGraphics

/// 合成 ⌘ 拖拽来重排菜单栏图标。
///
/// 这是全项目风险最高的一段代码：它操纵的是系统级输入事件，一旦"该停手时没停手"，
/// 用户会得到幽灵点击、被劫持的光标，甚至卡住的 ⌘ 键（Bartender 5/6 在 Tahoe 上的实况）。
/// 因此有三条不可协商的约束，全部写进实现而不是文档：
///   1. 起手前必过 EventSentinel 预检：用户按住鼠标、光标不在期望位、操作过密 → 一个事件都不发；
///   2. 飞行途中每步复核"光标是否还在我们放的位置"，被外力挪走立即中止；
///   3. **任何退出路径都必须抬起 ⌘ 与鼠标键**，宁可拖失败，绝不能留下按住的修饰键。
public final class AccessibilityMenuBarMover: MenuBarMoving, DragReleasing {
    public struct Config: Sendable {
        /// 起点到终点的插值步数。太少系统会识别成点击，太多浪费时间；实测 6~10 步可用。
        public var stepCount: Int
        /// 每步之后让系统消化的时间（菜单栏重排是异步的）
        public var settleInterval: TimeInterval
        /// 按下后先持住多久再开始移动。实测缺这一段时约一半的拖拽被系统当成"点击"
        /// 而不是拖拽——图标纹丝不动，且不报错，是最难查的一种失败。
        public var initialHoldInterval: TimeInterval
        /// 飞行途中允许的光标滞后：我们刚发的事件系统可能还没应用，
        /// 这跟「被外力挪走」是两回事，所以中途容差比预检宽松
        public var maxLagPoints: CGFloat
        /// warp 之后允许的光标偏差：超过它就认为有人在抢光标。
        /// 系统可能有光标加速/平滑，给一点余量但不能太大，否则抢不过外挂
        public var maxPlacementDriftPoints: CGFloat
        /// 是否额外发真实的 ⌘ keyDown/keyUp。
        /// 真机判别结论：让 macOS 认定 ⌘ 拖拽的是**鼠标事件自带的 flags**，
        /// 真实按键事件并非必需；而按键反而带来"⌘ 卡在按下态"的残留读数风险，
        /// 因此默认关闭（只贴 flags）。
        public var postsPhysicalCommandKey: Bool
        /// 本机系统版本是否已确认支持该机制（M0 之前一律 false → 上层保持降级）
        public var isConfirmedSupportedOS: Bool

        public init(
            stepCount: Int = 12,
            settleInterval: TimeInterval = 0.015,
            initialHoldInterval: TimeInterval = 0.07,
            maxLagPoints: CGFloat = 30,
            maxPlacementDriftPoints: CGFloat = 8,
            postsPhysicalCommandKey: Bool = false,
            isConfirmedSupportedOS: Bool = false
        ) {
            self.stepCount = max(2, stepCount)
            self.settleInterval = settleInterval
            self.initialHoldInterval = initialHoldInterval
            self.maxLagPoints = maxLagPoints
            self.maxPlacementDriftPoints = maxPlacementDriftPoints
            self.postsPhysicalCommandKey = postsPhysicalCommandKey
            self.isConfirmedSupportedOS = isConfirmedSupportedOS
        }
    }

    /// 一次尝试的完整足迹，probe 与日志靠它解释成败
    public struct Attempt: Equatable, Sendable {
        public let itemID: String
        public let source: CGPoint
        public let target: CGPoint
        public let eventsPosted: Int
        public let abortedBy: EventSentinel.Verdict?
        public let systemRejectedPost: Bool
        public let landing: CGPoint?
        public var didSucceed: Bool { abortedBy == nil && !systemRejectedPost }
    }

    public private(set) var lastAttempt: Attempt?
    /// 连续成功计数：M0 的闸门要求「同一系统版本连续 100 次全绿」才允许开放完整接管
    public private(set) var consecutiveSuccesses = 0
    public private(set) var totalAttempts = 0
    public private(set) var totalAborts = 0

    private let reader: MenuBarReading
    private let cursor: CursorReading
    private let poster: DragEventPosting
    /// 目前用于漂移判定的容差来源；操作节奏的节流由 LayoutEngine 负责，
    /// 所以这里不再走 preflight 的 throttled 分支
    private let sentinel: EventSentinel
    private let config: Config

    public init(
        reader: MenuBarReading,
        cursor: CursorReading,
        poster: DragEventPosting,
        sentinel: EventSentinel = EventSentinel(),
        config: Config = Config()
    ) {
        self.reader = reader
        self.cursor = cursor
        self.poster = poster
        self.sentinel = sentinel
        self.config = config
    }

    // MARK: - MenuBarMoving

    @discardableResult
    public func move(itemID: String, toX targetX: CGFloat) throws -> CGPoint {
        try move(itemID: itemID, toX: targetX, expectedTargets: nil, isCancelled: { false })
    }

    @discardableResult
    public func move(itemID: String, toX targetX: CGFloat, expectedTargets: [ManagedItem]?, isCancelled: () -> Bool) throws -> CGPoint {
        totalAttempts += 1

        guard config.isConfirmedSupportedOS else { throw MenuBarMoveError.unsupportedOS }
        let displayConfiguration = cursor.displayConfiguration
        func checkInterruption() throws {
            try requireInteractiveSession()
            guard displayConfiguration?.isEmpty != true, !isCancelled(),
                  cursor.displayConfiguration == displayConfiguration else {
                consecutiveSuccesses = 0
                totalAborts += 1
                throw MenuBarMoveError.dragInterrupted
            }
        }
        try checkInterruption()

        guard let item = reader.item(withID: itemID) else {
            throw MenuBarMoveError.itemVanished(itemID)
        }
        let source = CGPoint(x: item.centerX, y: item.frame.midY)
        var refreshedTargetX = targetX
        if let anchor = expectedTargets?.first {
            guard let frame = reader.currentFrame(of: anchor), abs(frame.midY - source.y) < 8,
                  let x = MenuBarDropTarget.refreshedTargetX(targetX, anchor: anchor, currentFrame: frame) else {
                throw MenuBarMoveError.targetNotInteractable
            }
            refreshedTargetX = x
        }
        let target = CGPoint(x: refreshedTargetX, y: source.y)
        func validateEndpoints() throws {
            // AX 锚点可能换到另一屏而显示器拓扑未变；刷新后的两端仍须同屏。
            if let displays = displayConfiguration {
                guard let primary = displays.values.first(where: { $0.origin == .zero }),
                      displays.values.contains(where: {
                          let frame = ScreenCoordinateSpace.cgToAppKit($0, primaryScreenHeight: primary.height)
                          return frame.contains(source) && frame.contains(target)
                      }) else {
                    totalAborts += 1; consecutiveSuccesses = 0
                    throw MenuBarMoveError.targetNotInteractable
                }
            }
            guard reader.hitTest(expected: item, at: source) == .verified else {
                totalAborts += 1; consecutiveSuccesses = 0
                throw MenuBarMoveError.sourceNotInteractable(itemID)
            }
            let targetVerified = expectedTargets.map { candidates in
                candidates.contains { reader.hitTest(expected: $0, at: target) == .verified }
            } ?? (reader.hitTest(expected: nil, at: target) == .verified)
            guard targetVerified else {
                totalAborts += 1; consecutiveSuccesses = 0
                throw MenuBarMoveError.targetNotInteractable
            }
        }
        try checkInterruption()

        // 1) 动手前只看一件事：用户是否正在按着鼠标。
        //    此刻一个事件都不能发——抢在用户之前按下就是"幽灵点击"。
        if cursor.isPrimaryButtonPressed {
            record(itemID: itemID, source: source, target: target, events: 0, aborted: .userInteracting, rejected: false, landing: nil)
            throw MenuBarMoveError.abortedBySentinel(.userInteracting)
        }
        if abs(target.x - source.x) <= 0.5 { return source }
        try validateEndpoints()

        // 2) 先把光标放到图标上，再复核它是否真的到位。
        //    注意顺序：光标"本来在哪"不是放弃的理由（用户可能正在用鼠标做别的事），
        //    真正的安全条件是"我们放过去之后，它还在那儿"。若把预检写成
        //    "当前光标 == 图标中心"，那几乎永远不成立，整个功能等于永远中止。
        try checkInterruption()
        if cursor.isPrimaryButtonPressed {
            record(itemID: itemID, source: source, target: target, events: 0,
                   aborted: .userInteracting, rejected: false, landing: nil)
            throw MenuBarMoveError.abortedBySentinel(.userInteracting)
        }
        poster.post(.warp(source))
        poster.post(.settle(config.settleInterval))

        let placed = cursor.currentLocation
        let placementDrift = EventSentinel.distance(from: source, to: placed)
        if placementDrift > config.maxPlacementDriftPoints {
            // warp 后位置不对 = 有东西在跟我们抢光标，立刻收手（此时还没按下任何键）
            record(itemID: itemID, source: source, target: target, events: 2,
                   aborted: .cursorDrift(placementDrift, placed), rejected: false, landing: placed)
            throw MenuBarMoveError.abortedBySentinel(.cursorDrift(placementDrift, placed))
        }

        // 3) 起手。flight 决定退出时要不要收尾——这是「绝不留下按住的 ⌘」的关键：
        //    只要 ⌘ 按下去了，无论成功、中止还是系统拒绝，defer 都必须把它抬起来。
        //    同一份状态对外暴露 releaseInFlightDrag()，让信号收尾能插手悬在半空的拖拽；
        //    登记放在 commandDown **之前**：真发生竞争时宁可多发一次抬起，也不能留下卡住的键。
        try checkInterruption()
        try validateEndpoints()
        beginFlight(commandHeld: config.postsPhysicalCommandKey)
        defer { releaseInFlightDrag() }
        if config.postsPhysicalCommandKey { poster.post(.commandDown) }

        try checkInterruption()
        if config.postsPhysicalCommandKey { try validateEndpoints() }
        // AX 查询可能阻塞；最后一次查询之后必须重新让位，不能沿用查询前的输入状态。
        try checkInterruption()
        if cursor.isPrimaryButtonPressed {
            record(itemID: itemID, source: source, target: target, events: config.postsPhysicalCommandKey ? 3 : 2,
                   aborted: .userInteracting, rejected: false, landing: nil)
            throw MenuBarMoveError.abortedBySentinel(.userInteracting)
        }
        let latest = cursor.currentLocation
        let latestDrift = EventSentinel.distance(from: source, to: latest)
        if latestDrift > config.maxPlacementDriftPoints {
            record(itemID: itemID, source: source, target: target, events: config.postsPhysicalCommandKey ? 3 : 2,
                   aborted: .cursorDrift(latestDrift, latest), rejected: false, landing: latest)
            throw MenuBarMoveError.abortedBySentinel(.cursorDrift(latestDrift, latest))
        }
        try checkInterruption()
        if !post(.mouseDown(source)) {
            record(itemID: itemID, source: source, target: target, events: 3, aborted: nil, rejected: true, landing: nil)
            throw MenuBarMoveError.abortedBySentinel(.userInteracting)
        }
        markMouseDownPosted()
        // 持住再走：立刻移动会被判定为点击
        poster.post(.settle(config.initialHoldInterval))

        // 4) 插值拖到目标，每步复核
        for step in 1...config.stepCount {
            try checkInterruption()
            let progress = CGFloat(step) / CGFloat(config.stepCount)
            let point = CGPoint(
                x: source.x + (target.x - source.x) * progress,
                y: source.y
            )
            if !post(.mouseDragged(point)) {
                record(itemID: itemID, source: source, target: target, events: 4 + step, aborted: nil, rejected: true, landing: nil)
                throw MenuBarMoveError.abortedBySentinel(.userInteracting)
            }
            poster.post(.settle(config.settleInterval))

            let actual = cursor.currentLocation
            let drift = EventSentinel.distance(from: point, to: actual)
            if drift > config.maxLagPoints {
                // 在架标记保持有效：交给 defer 抬起 ⌘ 与鼠标键
                record(itemID: itemID, source: source, target: target, events: 4 + step,
                       aborted: .cursorDrift(drift, actual), rejected: false, landing: actual)
                throw MenuBarMoveError.abortedBySentinel(.cursorDrift(drift, actual))
            }
            // 有人在半途替我们抬起了按下（优雅退出抢到了收尾）：就此收手。
            // 继续走完会再抬一次鼠标键，并把一次没做完的变更报成成功。
            if !isDragInFlight {
                record(itemID: itemID, source: source, target: target, events: 4 + step,
                       aborted: nil, rejected: false, landing: actual)
                totalAborts += 1
                consecutiveSuccesses = 0
                throw MenuBarMoveError.dragInterrupted
            }
        }

        // 5) 收尾
        try checkInterruption()
        if !post(.mouseUp(target)) {
            record(itemID: itemID, source: source, target: target, events: 4 + config.stepCount, aborted: nil, rejected: true, landing: nil)
            throw MenuBarMoveError.abortedBySentinel(.userInteracting)
        }
        // 抬起动作由下面两行自己完成，这里只清空在架标记，避免 defer 再抬一次
        endFlight()
        if config.postsPhysicalCommandKey { poster.post(.commandUp) }
        poster.post(.settle(config.settleInterval))

        let landing = cursor.currentLocation
        record(itemID: itemID, source: source, target: target, events: 5 + config.stepCount, aborted: nil, rejected: false, landing: landing)
        consecutiveSuccesses += 1
        return landing
    }

    // MARK: - 在架拖拽状态（信号收尾的插手点）

    private func requireInteractiveSession() throws {
        guard cursor.isSessionInteractive else {
            consecutiveSuccesses = 0
            totalAborts += 1
            throw MenuBarMoveError.sessionUnavailable
        }
    }

    /// 一次"已经按下、尚未抬起"的拖拽。拆开记是因为两段的风险不对称：
    /// 只发了 commandDown 就被打断，最需要抬起的是 ⌘；已经 mouseDown 则两个都要抬。
    private struct Flight {
        var mouseDownPosted = false
        var commandHeld = false
    }

    /// 拖拽跑在工作线程，收尾回调来自主线程/信号队列，所以状态必须锁住。
    private let flightLock = NSLock()
    private var flight: Flight?

    /// 是否有一次拖拽正悬在半空。探针与日志用它区分"干净退出"与"被打断的退出"。
    public var isDragInFlight: Bool {
        flightLock.lock()
        defer { flightLock.unlock() }
        return flight != nil
    }

    /// 就地结束半空的拖拽：抬起鼠标键与（若启用）真实 ⌘。幂等——只有第一次调用会发事件，
    /// 所以「信号先到」和「自己收尾」同时发生也不会重复抬起。
    ///
    /// 真机结论要摆正位置：kill -9 时 macOS 也会回收死亡进程的事件源状态，卡键不是这里防的；
    /// 这条 API 的意义在于让退出变得**可解释**（谁抬的、什么时候抬的），并且不依赖内核回收时机。
    public func releaseInFlightDrag() {
        flightLock.lock()
        guard let current = flight else {
            flightLock.unlock()
            return
        }
        flight = nil
        flightLock.unlock()

        if current.mouseDownPosted {
            poster.post(.mouseUp(cursor.currentLocation))
        }
        if current.commandHeld {
            poster.post(.commandUp)
        }
    }

    // MARK: - 私有

    private func beginFlight(commandHeld: Bool) {
        flightLock.lock()
        flight = Flight(commandHeld: commandHeld)
        flightLock.unlock()
    }

    private func markMouseDownPosted() {
        flightLock.lock()
        flight?.mouseDownPosted = true
        flightLock.unlock()
    }

    private func endFlight() {
        flightLock.lock()
        flight = nil
        flightLock.unlock()
    }

    private func post(_ event: DragEvent) -> Bool {
        poster.post(event)
    }

    private func record(
        itemID: String,
        source: CGPoint,
        target: CGPoint,
        events: Int,
        aborted: EventSentinel.Verdict?,
        rejected: Bool,
        landing: CGPoint?
    ) {
        lastAttempt = Attempt(
            itemID: itemID,
            source: source,
            target: target,
            eventsPosted: events,
            abortedBy: aborted,
            systemRejectedPost: rejected,
            landing: landing
        )
        if aborted != nil || rejected {
            totalAborts += 1
            consecutiveSuccesses = 0
        }
    }
}
