import Foundation

/// 跨启动身份台账（设计见 docs/design/跨启动身份台账.md）。
///
/// 要解决的问题一句话：用户的分区归属原本挂在 `归属进程 + 标题` 上，而标题是**别人可变的可读状态**
/// （微信把未读数写进标题）。一改名，用户"我收起来过"这件事就查无此人。
/// 台账存的是**我们自己的不变键** `assignmentKey`，AX 派生 id 降级成它的"历史别名"。
public struct IdentityRecord: Codable, Equatable, Sendable {
    /// 谁的决定。工具自发、永不复用；布局最终应当只认它。
    public let assignmentKey: String
    public let ownerBundleID: String
    /// 登记时读到的标题。不从别名字符串里拆——标题带点是常态，拆错就把规则带偏。
    public var observedTitle: String
    public var observedOrdinal: Int
    /// 登记时该进程一共几个图标。序号只有在这个数没变时才代表同一个位置。
    public var ownerItemCount: Int
    /// 观测到的 AX id，最新一条在末尾；超出上限丢弃最旧的。
    public var aliases: [String]
    public var zoneRaw: String
    /// `user` = 用户亲手分配；`inferred` = 按规则推定，UI 要如实标出来
    public var pinnedBy: IdentityRecord.Pin
    /// 这条记录经历过多少次"改名但还能对上"
    public var driftCount: Int
    public var lastSeenAt: Date

    public enum Pin: String, Codable, Sendable {
        case user
        case inferred
    }

    public init(
        assignmentKey: String,
        ownerBundleID: String,
        observedTitle: String,
        observedOrdinal: Int,
        ownerItemCount: Int,
        aliases: [String],
        zoneRaw: String,
        pinnedBy: Pin,
        driftCount: Int = 0,
        lastSeenAt: Date
    ) {
        self.assignmentKey = assignmentKey
        self.ownerBundleID = ownerBundleID
        self.observedTitle = observedTitle
        self.observedOrdinal = observedOrdinal
        self.ownerItemCount = ownerItemCount
        self.aliases = aliases
        self.zoneRaw = zoneRaw
        self.pinnedBy = pinnedBy
        self.driftCount = driftCount
        self.lastSeenAt = lastSeenAt
    }

    /// 台账认为"它现在叫什么"。
    public var currentID: String { aliases.last ?? "" }
}

/// 一次匹配的结论。`renames` 是唯一可安全迁移的部分，其余都要被上层如实报出来。
public struct LedgerResolution: Equatable, Sendable {
    public var renames: [(from: String, to: String)] = []
    /// 有旧记录但匹配不唯一（多对多）⇒ 按设计**什么都不做**
    public var ambiguousOwners: Set<String> = []
    public var aliasHits = 0
    public var ordinalHits = 0
    public var titleHits = 0

    public init() {}

    public static func == (lhs: LedgerResolution, rhs: LedgerResolution) -> Bool {
        lhs.renames.map { "\($0.from)>\($0.to)" } == rhs.renames.map { "\($0.from)>\($0.to)" }
            && lhs.ambiguousOwners == rhs.ambiguousOwners
            && lhs.aliasHits == rhs.aliasHits
            && lhs.ordinalHits == rhs.ordinalHits
            && lhs.titleHits == rhs.titleHits
    }
}

/// 纯匹配器：无 IO、无 AppKit，可以把每条规则的边界钉死在表驱动用例里。
public enum IdentityLedger {
    /// 别名上限：再多也没意义，它只用来记住"这个图标最近叫什么"。
    public static let maxAliases = 8
    /// 记录多久没再出现就可以清理。取 30 天而不是更短：用户可能整月不打开某个工具。
    public static let retentionInterval: TimeInterval = 30 * 24 * 3600

    /// 现场 vs 台账，算出"哪些旧 id 该迁到哪个新 id"。
    ///
    /// 匹配按优先级取**唯一命中**，任何一步出现多解就整对放弃（宁丢不错接）。
    /// `staleIDs` 是**当前布局里还挂着、但现场已不见**的 id。只比现场两帧不够——
    /// 重启之后旧 id 早就不在布局里了，线索只能来自台账本身。
    public static func resolve(
        records: [IdentityRecord],
        observed: [ManagedItem],
        staleIDs: Set<String>
    ) -> LedgerResolution {
        var result = LedgerResolution()
        let liveIDs = Set(observed.map(\.id))
        var claimed: Set<String> = []

        for record in records {
            let currentID = record.currentID
            // 台账指向的 id 现场还在 ⇒ 没漂移；旧 id 也不在布局里 ⇒ 没东西可迁
            guard !currentID.isEmpty, !liveIDs.contains(currentID), staleIDs.contains(currentID) else { continue }

            var matches: [String] = []
            var kind = 0

            // ① 别名精确命中：这个新 id 以前就叫过这个名字
            for item in observed where record.aliases.contains(item.id) && item.id != currentID {
                matches.append(item.id)
            }
            kind = matches.isEmpty ? kind : 1

            // ② 同进程 + 同序号 + 图标总数未变。总数一变，序号就换了主人。
            if matches.isEmpty {
                for item in observed
                where item.ownerBundleID == record.ownerBundleID
                    && item.id != currentID
                    && item.ordinalInOwner == record.observedOrdinal
                    && item.ownerItemCount == record.ownerItemCount {
                    matches.append(item.id)
                }
                kind = matches.isEmpty ? kind : 2
            }

            // ③ 标题包含（`微信 (3)` 包含 `微信`）：比序号更弱，只在候选唯一时才用
            if matches.isEmpty, !record.observedTitle.isEmpty {
                let needle = ManagedItem.normalized(record.observedTitle)
                if !needle.isEmpty {
                    for item in observed
                    where item.ownerBundleID == record.ownerBundleID
                        && item.id != currentID
                        && ManagedItem.normalized(item.title).contains(needle) {
                        matches.append(item.id)
                    }
                    kind = matches.isEmpty ? kind : 3
                }
            }

            let unique = Set(matches)
            guard unique.count == 1, let candidate = unique.first else {
                if !unique.isEmpty || matches.count > 1 { result.ambiguousOwners.insert(record.ownerBundleID) }
                continue
            }
            // 一个新 id 不能被两条旧记录同时认领
            guard !claimed.contains(candidate) else {
                result.ambiguousOwners.insert(record.ownerBundleID)
                continue
            }

            claimed.insert(candidate)
            result.renames.append((currentID, candidate))
            switch kind {
            case 1: result.aliasHits += 1
            case 2: result.ordinalHits += 1
            default: result.titleHits += 1
            }
        }
        return result
    }

    /// 匹配成功后更新台账：别名追加、观测值刷新、漂移计数。
    public static func applyUpdate(
        to record: inout IdentityRecord,
        now: Date,
        observedItem: ManagedItem,
        drifted: Bool
    ) {
        if !record.aliases.contains(observedItem.id) {
            record.aliases.append(observedItem.id)
            if record.aliases.count > maxAliases {
                record.aliases.removeFirst(record.aliases.count - maxAliases)
            }
        }
        record.observedTitle = observedItem.title
        record.observedOrdinal = observedItem.ordinalInOwner
        record.ownerItemCount = observedItem.ownerItemCount
        record.lastSeenAt = now
        if drifted { record.driftCount += 1 }
    }

    /// 清理：现场已不见、超期未再出现、且不是用户亲手钉的记录。
    /// 用户亲手分配过的一律保留——App 暂时没运行不等于用户改了主意，
    /// 清掉就等于"你上月的收纳凭空没了"。
    public static func prune(
        records: [IdentityRecord],
        now: Date,
        seenIDs: Set<String>
    ) -> [IdentityRecord] {
        records.filter { record in
            if record.pinnedBy == .user { return true }
            if record.aliases.contains(where: { seenIDs.contains($0) }) { return true }
            return now.timeIntervalSince(record.lastSeenAt) < retentionInterval
        }
    }
}
