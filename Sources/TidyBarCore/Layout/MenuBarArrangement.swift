import Foundation

/// 物理整理不修改用户布局；所有输入在一个工作队列上串行执行，主线程保持处理 AppKit 事件。
@MainActor
public final class MenuBarArrangement {
    public enum Failure: Error {
        case cancelled
        case sessionUnavailable
        case controlsUnavailable
        case unsupportedDisplayLayout
        case itemsChanged
        case stalled(String)
        case protectedItem(String)
        case moveFailed(String, MenuBarMoveError)
        case unexpected(String)

        public var message: String {
            switch self {
            case .cancelled: return "布局整理已取消"
            case .sessionUnavailable: return "屏幕未解锁，已暂停菜单栏整理"
            case .controlsUnavailable: return "尚未读到分隔符，请刷新后重试"
            case .unsupportedDisplayLayout: return "图标与分隔符不在同一屏幕的菜单栏内，已停止整理"
            case .itemsChanged: return "菜单栏图标正在变化，请刷新后重试"
            case .stalled(let title): return "系统未能移动「\(title)」，已停止后续整理"
            case .protectedItem(let title): return "无法安全调整系统项「\(title)」，已停止整理"
            case .moveFailed(_, .sessionUnavailable): return "屏幕未解锁，已暂停菜单栏整理"
            case .moveFailed(_, .unsupportedOS): return "当前系统不支持这次移动，已停止整理"
            case .moveFailed(let title, .sourceNotInteractable): return "「\(title)」当前被菜单或窗口遮挡，已停止移动"
            case .moveFailed(_, .targetNotInteractable): return "目标位置暂时不可操作，已停止整理"
            case .moveFailed(let title, .itemVanished): return "「\(title)」刚刚消失，请刷新后重试"
            case .moveFailed(let title, _): return "「\(title)」移动被中断，请停止操作鼠标后重试"
            case .unexpected(let message): return "布局整理未完成：\(message)"
            }
        }
    }

    private let reader: MenuBarReading
    private let mover: MenuBarMoving
    private let cursor: CursorReading
    private let queue = DispatchQueue(label: "local.tidybar.arrangement", qos: .userInitiated)
    private var active: Progress?
    public var isRunning: Bool { active != nil }

    /// mover 在任务期间由此串行队列独占；调用方的 busy 门禁与退出 drain 保证交接。
    /// reader 仅作只读访问，与既有后台枚举遵循同一约定。
    private struct WorkerIO: @unchecked Sendable {
        let reader: MenuBarReading
        let mover: MenuBarMoving
        let cursor: CursorReading
    }

    public init(reader: MenuBarReading, mover: MenuBarMoving, cursor: CursorReading) {
        self.reader = reader
        self.mover = mover
        self.cursor = cursor
    }

    @discardableResult
    public func start(layout: MenuBarLayout, controls: DividerGeometry.Controls,
                      expectedItems: Set<String>, defaultZone: MenuBarZone, screens: [ScreenInfo],
                      restoreSavedOrder: Bool = false,
                      completion: @escaping @MainActor (Result<[ManagedItem], Failure>) -> Void) -> Bool {
        guard active == nil else { return false }
        let progress = Progress(totalUnitCount: Int64(max(1, expectedItems.count)))
        active = progress
        let io = WorkerIO(reader: reader, mover: mover, cursor: cursor)
        queue.async {
            let result: Result<[ManagedItem], Failure>
            do {
                result = .success(try Self.arrange(reader: io.reader, mover: io.mover, cursor: io.cursor, layout: layout,
                    controls: controls, expectedItems: expectedItems, defaultZone: defaultZone, screens: screens,
                    restoreSavedOrder: restoreSavedOrder, progress: progress))
            } catch let failure as Failure { result = .failure(failure) }
            catch { result = .failure(.unexpected(error.localizedDescription)) }
            (io.mover as? DragReleasing)?.releaseInFlightDrag()
            DispatchQueue.main.async {
                guard self.active === progress else { return }
                self.active = nil
                completion(progress.isCancelled ? .failure(.cancelled)
                           : !io.cursor.isSessionInteractive ? .failure(.sessionUnavailable) : result)
            }
        }
        return true
    }

    public func cancel() { active?.cancel() }

    /// 退出先取消后续步骤，再等当前投递和收尾离开同一串行队列，不能在主线程抢着抬键。
    public func cancelAndDrain(_ completion: @escaping @MainActor () -> Void) {
        cancel()
        queue.async { DispatchQueue.main.async { completion() } }
    }

    nonisolated private static func arrange(reader: MenuBarReading, mover: MenuBarMoving, cursor: CursorReading,
                                            layout: MenuBarLayout, controls: DividerGeometry.Controls,
                                            expectedItems: Set<String>, defaultZone: MenuBarZone,
                                            screens: [ScreenInfo], restoreSavedOrder: Bool, progress: Progress) throws -> [ManagedItem] {
        func readMenuBar(waitSettled: Bool = false) throws -> (raw: [ManagedItem], current: [ManagedItem]) {
            let deadline = waitSettled ? ProcessInfo.processInfo.systemUptime + 3.0 : ProcessInfo.processInfo.systemUptime + 0.8
            while true {
                let raw = reader.discoverItems()
                let physical = DividerGeometry.physicalItems(raw)
                let physicalIDs = Set(physical.map(\.id))
                let hasToggle = physicalIDs.contains(controls.toggle)
                    || physical.contains(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "☰" || $0.title == "▶" || $0.title == "◀") })
                let hasLeft = physicalIDs.contains(controls.leftDivider)
                    || physical.contains(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "┆" || $0.id.contains("always_hidden")) })
                let hasRight = physicalIDs.contains(controls.rightDivider)
                    || physical.contains(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "│" || $0.id.contains("separator")) })
                guard hasToggle && hasLeft && hasRight else {
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    throw Failure.controlsUnavailable
                }
                let foundLeft = physical.first(where: { $0.id == controls.leftDivider })
                    ?? physical.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "┆" || $0.id.contains("always_hidden")) })
                let foundRight = physical.first(where: { $0.id == controls.rightDivider })
                    ?? physical.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "│" || $0.id.contains("separator")) })
                let currentControlIDs = Set([foundLeft?.id, foundRight?.id, controls.leftDivider, controls.rightDivider, controls.toggle].compactMap { $0 })
                let managed = Set(physical.filter { !$0.isSystemOwned && !currentControlIDs.contains($0.id) && $0.ownerBundleID != "local.tidybar.app" && $0.ownerBundleID != Bundle.main.bundleIdentifier }.map(\.id))
                guard managed == expectedItems else {
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    throw Failure.itemsChanged
                }
                guard let toggle = physical.first(where: { $0.id == controls.toggle })
                    ?? physical.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "☰" || $0.title == "▶" || $0.title == "◀") }),
                      let screen = screens.first(where: { ScreenCoordinateSpace.isWithinMenuBar(toggle.frame, screen: $0) }) else {
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    throw Failure.unsupportedDisplayLayout
                }

                let itemsToCheck = physical.filter({ !$0.isSystemOwned || currentControlIDs.contains($0.id) || $0.id == toggle.id })
                let allOnScreen = itemsToCheck.allSatisfy {
                    ScreenCoordinateSpace.isWithinMenuBar($0.frame, screen: screen)
                }
                if allOnScreen {
                    // 别的显示器上的系统观测不参与此菜单栏的排序或验收。
                    return (raw, physical.filter { ScreenCoordinateSpace.isWithinMenuBar($0.frame, screen: screen) })
                }

                // 如果尚未全部归位且未超时，等待系统移动或动画稳定
                if ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }

                throw Failure.unsupportedDisplayLayout
            }
        }

        func desiredOrder(for items: [ManagedItem], controls: DividerGeometry.Controls) -> [String] {
            return restoreSavedOrder
                ? DividerGeometry.arrangementOrder(items: items, layout: layout, leftDivider: controls.leftDivider,
                    rightDivider: controls.rightDivider, toggle: controls.toggle, defaultZone: defaultZone)
                : DividerGeometry.foldingOrder(items: items, layout: layout, controls: controls, defaultZone: defaultZone)
        }
        func disorder(of items: [ManagedItem], controls: DividerGeometry.Controls) -> Int {
            return restoreSavedOrder ? DividerGeometry.orderDisorder(items: items, desiredOrder: desiredOrder(for: items, controls: controls))
                : DividerGeometry.partitionDisorder(items: items, layout: layout, controls: controls, defaultZone: defaultZone)
        }
        let limit = max(12, (expectedItems.count + controls.ids.count) * 3)
        var lastMoveEnded = -TimeInterval.infinity
        var reachabilityRetries = 0
        for attempt in 0..<limit {
            if progress.isCancelled { throw Failure.cancelled }
            guard cursor.isSessionInteractive else { throw Failure.sessionUnavailable }
            let (raw, current) = try readMenuBar(waitSettled: attempt == 0)
            let toggleID = current.first(where: { $0.id == controls.toggle })?.id
                ?? current.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "☰" || $0.title == "▶" || $0.title == "◀") })?.id
                ?? controls.toggle
            let leftID = current.first(where: { $0.id == controls.leftDivider })?.id
                ?? current.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "┆" || $0.id.contains("always_hidden")) })?.id
                ?? controls.leftDivider
            let rightID = current.first(where: { $0.id == controls.rightDivider })?.id
                ?? current.first(where: { ($0.ownerBundleID == "local.tidybar.app" || $0.ownerBundleID == Bundle.main.bundleIdentifier) && ($0.title == "│" || $0.id.contains("separator")) })?.id
                ?? controls.rightDivider
            let effectiveControls = DividerGeometry.Controls(leftDivider: leftID, rightDivider: rightID, toggle: toggleID)
            let desired = desiredOrder(for: current, controls: effectiveControls)
            if restoreSavedOrder ? current.map(\.id) == desired
                : DividerGeometry.isCorrectlyPartitioned(items: current, layout: layout, controls: effectiveControls, defaultZone: defaultZone) {
                return raw
            }
            guard desired.count == current.count,
                  let destination = desired.indices.first(where: { current[$0].id != desired[$0] }),
                  let source = current.firstIndex(where: { $0.id == desired[destination] }),
                  let x = MenuBarDropTarget.targetX(in: current, moving: source, to: destination) else {
                throw Failure.itemsChanged
            }
            let item = current[source]
            guard !item.isSystemOwned else { throw Failure.protectedItem(item.title) }
            let interval = EventSentinel().minIntervalBetweenOperations
            let remaining = min(interval, max(0, interval - (ProcessInfo.processInfo.systemUptime - lastMoveEnded)))
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            if progress.isCancelled { throw Failure.cancelled }
            guard cursor.isSessionInteractive else { throw Failure.sessionUnavailable }
            fprint("物理整理 \(attempt + 1)｜\(item.title)｜\(source) → \(destination)")
            do {
                _ = try mover.move(itemID: item.id, toX: x,
                    expectedTargets: MenuBarDropTarget.expectedHitTargets(in: current, moving: source, to: destination),
                    isCancelled: { progress.isCancelled })
            }
            catch let error as MenuBarMoveError {
                fprint("物理移动中止｜\(item.id)｜\(error)")
                switch error {
                case .sourceNotInteractable, .targetNotInteractable:
                    if reachabilityRetries < 2, !progress.isCancelled, cursor.isSessionInteractive,
                       !cursor.isPrimaryButtonPressed {
                        reachabilityRetries += 1
                        Thread.sleep(forTimeInterval: 0.1)
                        continue // 激活或展开后的布局尚未稳定，先重读；不重复投递旧坐标。
                    }
                default: break
                }
                throw Failure.moveFailed(item.title, error)
            }
            reachabilityRetries = 0
            lastMoveEnded = ProcessInfo.processInfo.systemUptime
            if progress.isCancelled { throw Failure.cancelled }

            // 系统可能只完成一部分移动；必须改善全局分区，不能靠同区图标互换反复运行。
            let previousDisorder = disorder(of: current, controls: effectiveControls)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            var advanced = false
            repeat {
                if progress.isCancelled { throw Failure.cancelled }
                guard cursor.isSessionInteractive else { throw Failure.sessionUnavailable }
                let after = try readMenuBar().current
                let afterLeftID = after.first(where: { $0.id == effectiveControls.leftDivider })?.id ?? leftID
                let afterRightID = after.first(where: { $0.id == effectiveControls.rightDivider })?.id ?? rightID
                let afterToggleID = after.first(where: { $0.id == effectiveControls.toggle })?.id ?? toggleID
                let afterControls = DividerGeometry.Controls(leftDivider: afterLeftID, rightDivider: afterRightID, toggle: afterToggleID)
                advanced = disorder(of: after, controls: afterControls) < previousDisorder
                if advanced { break }
                Thread.sleep(forTimeInterval: 0.04)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard advanced else { throw Failure.stalled(item.title) }
            progress.completedUnitCount += 1
        }
        throw Failure.unexpected("未能在有限步骤内完成分组")
    }
}
