import Foundation

/// 布局变更日志：把「意图」先落盘再执行，进程被强杀/崩溃后启动时自动恢复。
///
/// 教训来源：同类工具在录制/系统抢占时若被 SIGKILL，会把中间状态留在内存里，
/// 下次启动误判成「用户自己隐藏的」，导致状态永久粘住。因此约定：
///   1. 执行任何移动前，先写 pending 意图；
///   2. 执行成功后写 committed 并清空 pending；
///   3. 启动时若存在 pending，则以其为准重建（而非从系统当前状态反推用户意图）。
public struct LayoutJournal: Sendable {
    public enum Recovery: Equatable, Sendable {
        /// 无中间态，可安全按已提交布局启动
        case clean(MenuBarLayout)
        /// 上次变更未完成，需按意图重放
        case interrupted(intent: LayoutIntent, committed: MenuBarLayout?)
    }

    /// 一次待执行的布局变更
    public struct LayoutIntent: Codable, Equatable, Sendable {
        public let id: String
        public let itemID: String
        public let targetZone: MenuBarZone
        public let targetPosition: Int?
        public let previousZone: MenuBarZone?
        public let previousPosition: Int?
        public let startedAt: Date
        /// 重放失败次数（跨启动累计）。旧版本写下的 pending 文件里没有这个字段，
        /// 解码时按 0 处理——绝不能因为升级就让孤儿意图"读不出来"而被静默丢掉。
        public var replayFailures: Int

        public init(
            itemID: String,
            targetZone: MenuBarZone,
            targetPosition: Int?,
            previousZone: MenuBarZone?,
            previousPosition: Int?,
            startedAt: Date = .init(),
            replayFailures: Int = 0,
            id: String = UUID().uuidString
        ) {
            self.id = id
            self.itemID = itemID
            self.targetZone = targetZone
            self.targetPosition = targetPosition
            self.previousZone = previousZone
            self.previousPosition = previousPosition
            self.startedAt = startedAt
            self.replayFailures = replayFailures
        }

        enum CodingKeys: String, CodingKey {
            case id, itemID, targetZone, targetPosition, previousZone, previousPosition, startedAt, replayFailures
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try container.decode(String.self, forKey: .itemID)
            targetZone = try container.decode(MenuBarZone.self, forKey: .targetZone)
            targetPosition = try container.decodeIfPresent(Int.self, forKey: .targetPosition)
            previousZone = try container.decodeIfPresent(MenuBarZone.self, forKey: .previousZone)
            previousPosition = try container.decodeIfPresent(Int.self, forKey: .previousPosition)
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
            replayFailures = try container.decodeIfPresent(Int.self, forKey: .replayFailures) ?? 0
            if let storedID = try container.decodeIfPresent(String.self, forKey: .id) {
                id = storedID
            } else {
                let fields = [itemID, targetZone.rawValue, String(targetPosition ?? -1),
                              previousZone?.rawValue ?? "", String(previousPosition ?? -1),
                              String(startedAt.timeIntervalSince1970)]
                id = "legacy:" + fields.map { "\($0.utf8.count):\($0)" }.joined()
            }
        }

        func renamed(to itemID: String) -> LayoutIntent {
            LayoutIntent(itemID: itemID, targetZone: targetZone, targetPosition: targetPosition,
                         previousZone: previousZone, previousPosition: previousPosition,
                         startedAt: startedAt, replayFailures: replayFailures, id: id)
        }
    }

    public let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - 路径

    private var committedURL: URL { directory.appendingPathComponent("layout.committed.json") }
    private var pendingURL: URL { directory.appendingPathComponent("layout.pending.json") }

    /// 供 Safety 层判断是否存在孤儿状态
    public var hasPendingIntent: Bool {
        FileManager.default.fileExists(atPath: pendingURL.path)
    }

    // MARK: - 落盘

    private struct CommittedLayout: Codable {
        let zones: [String: [String]]
        let completedIntentID: String?
    }

    public func writeCommitted(_ layout: MenuBarLayout, completing intent: LayoutIntent? = nil) throws {
        var cleanLayout = layout
        for id in cleanLayout.items(in: .hidden) where ManagedItem.isSystemOwned(itemID: id) {
            cleanLayout.move(itemID: id, to: .visible)
        }
        for id in cleanLayout.items(in: .alwaysHidden) where ManagedItem.isSystemOwned(itemID: id) {
            cleanLayout.move(itemID: id, to: .visible)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(CommittedLayout(zones: cleanLayout.zones, completedIntentID: intent?.id))
            .write(to: committedURL, options: .atomic)
    }

    public func hasCommitted(_ intent: LayoutIntent) -> Bool {
        guard let data = try? Data(contentsOf: committedURL),
              let committed = try? decoder.decode(CommittedLayout.self, from: data) else { return false }
        return committed.completedIntentID == intent.id
    }

    public func writeIntent(_ intent: LayoutIntent) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(intent).write(to: pendingURL, options: .atomic)
    }

    /// 变更成功落地后才清除意图
    public func clearPendingIntent() throws {
        guard hasPendingIntent else { return }
        try FileManager.default.removeItem(at: pendingURL)
    }

    public func readCommittedLayout() -> MenuBarLayout? {
        guard let data = try? Data(contentsOf: committedURL) else { return nil }
        guard var layout = try? decoder.decode(MenuBarLayout.self, from: data) else { return nil }
        for id in layout.items(in: .hidden) where ManagedItem.isSystemOwned(itemID: id) {
            layout.move(itemID: id, to: .visible)
        }
        for id in layout.items(in: .alwaysHidden) where ManagedItem.isSystemOwned(itemID: id) {
            layout.move(itemID: id, to: .visible)
        }
        return layout
    }

    public func readPendingIntent() -> LayoutIntent? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? decoder.decode(LayoutIntent.self, from: data)
    }

    // MARK: - 重放记账

    /// 一个孤儿意图最多重试几次。真机理由：意图可能永久做不成（图标所属 App 已卸载、
    /// 系统改版后落点规则变了），每次都重试等于每次启动都撞同一堵墙，还可能反复推用户的菜单栏。
    public static let defaultMaxReplayAttempts = 2

    /// 记一次重放失败。
    /// - Returns: 累加后的意图（pending 仍在，下次启动继续重试）；`nil` 表示已达上限、
    ///   pending 等待调用方提交放弃结果，或本来就没有 pending。
    public func noteReplayFailure(maxAttempts: Int = LayoutJournal.defaultMaxReplayAttempts) throws -> LayoutIntent? {
        guard var intent = readPendingIntent() else { return nil }
        intent.replayFailures += 1
        try writeIntent(intent)
        if intent.replayFailures >= max(1, maxAttempts) {
            return nil
        }
        return intent
    }

    // MARK: - 启动决策

    /// 纯函数：给定已提交布局与孤儿意图，得出启动时应采取的状态。
    public static func recover(committed: MenuBarLayout?, pending: LayoutIntent?) -> Recovery {
        if let pending {
            return .interrupted(intent: pending, committed: committed)
        }
        return .clean(committed ?? MenuBarLayout())
    }

    /// 把一次成功执行的布局重放到目标布局上（意图重放路径复用）
    public static func applying(_ intent: LayoutIntent, to layout: MenuBarLayout) -> MenuBarLayout {
        var next = layout
        next.move(itemID: intent.itemID, to: intent.targetZone, position: intent.targetPosition)
        return next
    }
}
