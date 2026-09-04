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
        public let itemID: String
        public let targetZone: MenuBarZone
        public let targetPosition: Int?
        public let previousZone: MenuBarZone?
        public let previousPosition: Int?
        public let startedAt: Date

        public init(
            itemID: String,
            targetZone: MenuBarZone,
            targetPosition: Int?,
            previousZone: MenuBarZone?,
            previousPosition: Int?,
            startedAt: Date = .init()
        ) {
            self.itemID = itemID
            self.targetZone = targetZone
            self.targetPosition = targetPosition
            self.previousZone = previousZone
            self.previousPosition = previousPosition
            self.startedAt = startedAt
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

    public func writeCommitted(_ layout: MenuBarLayout) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(layout).write(to: committedURL, options: .atomic)
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
        return try? decoder.decode(MenuBarLayout.self, from: data)
    }

    public func readPendingIntent() -> LayoutIntent? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? decoder.decode(LayoutIntent.self, from: data)
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
