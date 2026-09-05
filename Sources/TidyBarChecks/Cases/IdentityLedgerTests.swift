import Foundation
import TidyBarCore

// MARK: - 跨启动身份台账（宁丢不错接，但重启后仍要有线索）

/// 真实 reader 对同名图标会去重出不同 id（`#itemN` / `.1`），所以夹具也要能给出
/// "标题相同但 id 不同"这一形态——上一版让两个同名图标共用一个 id，
/// 旧 id 被当成还在现场，规则整条被跳过，测的是一段不存在的代码。
private func icon(_ bundle: String, _ title: String, ordinal: Int, of count: Int, x: CGFloat? = nil, id: String? = nil) -> ManagedItem {
    ManagedItem(
        id: id ?? ManagedItem.stableID(ownerBundleID: bundle, title: title),
        ownerBundleID: bundle,
        title: title,
        frame: CGRect(x: x ?? (600 + CGFloat(ordinal) * 30), y: 1_188, width: 24, height: 24),
        isSystemOwned: false,
        identitySource: .axTitle,
        ordinalInOwner: ordinal,
        ownerItemCount: count
    )
}

private func record(
    key: String,
    bundle: String,
    title: String,
    aliases: [String],
    ordinal: Int = 0,
    count: Int = 1,
    pinned: IdentityRecord.Pin = .inferred,
    at: Date = Date(timeIntervalSince1970: 1_000)
) -> IdentityRecord {
    IdentityRecord(
        assignmentKey: key, ownerBundleID: bundle, observedTitle: title,
        observedOrdinal: ordinal, ownerItemCount: count, aliases: aliases,
        zoneRaw: "hidden", pinnedBy: pinned, lastSeenAt: at
    )
}

struct IdentityLedgerTests {
    private let wechat = "com.tencent.xinwechat"

    /// 别名精确命中：以前叫过的名字再次出现，直接对上，不需要位置或标题猜。
    func aliasExactHit() throws {
        let wxOld = icon(wechat, "微信", ordinal: 0, of: 1)
        let wxNew = icon(wechat, "微信 (3)", ordinal: 0, of: 1)
        let records = [record(key: "a-1", bundle: wechat, title: "微信",
                              aliases: [wxNew.id, wxOld.id])]     // 最近一次是旧名
        let r = IdentityLedger.resolve(records: records, observed: [wxNew], staleIDs: [wxOld.id])
        expectEqual(r.renames.count, 1)
        expectEqual(r.renames.first?.from, wxOld.id)
        expectEqual(r.renames.first?.to, wxNew.id)
        expectEqual(r.aliasHits, 1)
    }

    /// 序号命中要求"进程图标总数未变"：总数一变，序号就换了主人。
    func ordinalHitRequiresUnchangedCount() throws {
        let old = icon(wechat, "微信", ordinal: 1, of: 3, x: 660)
        let sameSlot = icon(wechat, "微信 (7)", ordinal: 1, of: 3, x: 660)
        let grew = icon(wechat, "微信 (7)", ordinal: 1, of: 4, x: 660)
        let base = [record(key: "a-1", bundle: wechat, title: "微信", aliases: [old.id], ordinal: 1, count: 3)]

        let ok = IdentityLedger.resolve(records: base, observed: [sameSlot], staleIDs: [old.id])
        expectEqual(ok.ordinalHits, 1, "总数未变时应按序号对上")

        // 总数变了 ⇒ 序号证据作废；此时只有"标题包含且候选唯一"这一条更弱的规则可以接手。
        let changed = IdentityLedger.resolve(records: base, observed: [grew], staleIDs: [old.id])
        expectEqual(changed.ordinalHits, 0, "总数变了还按序号迁移，就是把设置安到别人头上")
        expectEqual(changed.renames.count, 1)
        expectEqual(changed.titleHits, 1, "`微信 (7)` 含 `微信`，唯一候选时可迁")
    }

    /// 两个图标同时改名，但各自的序号与进程总数都没变 ⇒ 映射是**唯一**的，
    /// 这是可靠证据而不是猜：此时该迁。把它错写成"多对多一律拒绝"会白丢可用信息。
    func simultaneousRenamesWithStableOrdinalsMigrate() throws {
        let bundle = "com.x"
        let a = icon(bundle, "A", ordinal: 0, of: 2)
        let b = icon(bundle, "B", ordinal: 1, of: 2)
        let a2 = icon(bundle, "A2", ordinal: 0, of: 2)
        let b2 = icon(bundle, "B2", ordinal: 1, of: 2)
        let records = [
            record(key: "a-1", bundle: bundle, title: "A", aliases: [a.id], ordinal: 0, count: 2),
            record(key: "a-2", bundle: bundle, title: "B", aliases: [b.id], ordinal: 1, count: 2),
        ]
        let r = IdentityLedger.resolve(records: records, observed: [a2, b2], staleIDs: [a.id, b.id])
        // 序号与进程总数都没变 ⇒ 两条映射各自唯一，这是可靠证据不是猜。
        // 上一版把它写成"多对多一律拒绝"，会把可用信息白白丢掉。
        expectEqual(Set(r.renames.map(\.from)), [a.id, b.id])
        expectEqual(r.ambiguousOwners, [])
    }

    /// 真歧义：进程图标总数变了（序号证据作废），而现场两个图标同名 ⇒ 候选不唯一，
    /// 一条都不迁，并把歧义如实报出来。
    func trulyAmbiguousTitlesMigrateNothing() throws {
        let bundle = "com.z"
        let old1 = icon(bundle, "工具", ordinal: 0, of: 1)
        let twinA = icon(bundle, "工具", ordinal: 0, of: 2, x: 700, id: bundle + ".工具#0")
        let twinB = icon(bundle, "工具", ordinal: 1, of: 2, x: 730, id: bundle + ".工具#1")
        let records = [
            record(key: "a-1", bundle: bundle, title: "工具", aliases: [old1.id], ordinal: 0, count: 1)
        ]
        let r = IdentityLedger.resolve(records: records, observed: [twinA, twinB], staleIDs: [old1.id])
        expect(r.renames.isEmpty, "同名两候选时不许挑：\(r.renames.map { "\($0.from)>\($0.to)" })")
        expectEqual(r.ambiguousOwners, [bundle])
    }

    /// 反过来说：只要每条旧记录都有唯一可辨认的新对应（别名各不同），
    /// 两个同时改名也能各自对上——这正是台账相对"现场 1↔1"多出来的能力。
    func simultaneousRenamesResolveWhenAliasesAreDistinct() throws {
        let bundle = "com.x"
        let a1 = icon(bundle, "A", ordinal: 0, of: 2)
        let b1 = icon(bundle, "B", ordinal: 1, of: 2)
        let a2 = icon(bundle, "A (2)", ordinal: 0, of: 2)
        let b2 = icon(bundle, "B (2)", ordinal: 1, of: 2)
        let records = [
            record(key: "a-1", bundle: bundle, title: "A", aliases: [a2.id, a1.id], ordinal: 0, count: 2),
            record(key: "a-2", bundle: bundle, title: "B", aliases: [b2.id, b1.id], ordinal: 1, count: 2),
        ]
        let r = IdentityLedger.resolve(records: records, observed: [a2, b2], staleIDs: [a1.id, b1.id])
        expectEqual(Set(r.renames.map(\.from)), [a1.id, b1.id])
        expectEqual(r.ambiguousOwners, [])
    }

    /// 一个新 id 不能被两条旧记录同时认领
    func singleTargetCannotBeClaimedTwice() throws {
        let bundle = "com.y"
        let old1 = icon(bundle, "P", ordinal: 0, of: 1)
        let fresh = icon(bundle, "P2", ordinal: 0, of: 1)
        let records = [
            record(key: "a-1", bundle: bundle, title: "P", aliases: [old1.id]),
            record(key: "a-2", bundle: bundle, title: "P", aliases: [old1.id]),   // 两条记录都指向同一个旧 id
        ]
        let r = IdentityLedger.resolve(records: records, observed: [fresh], staleIDs: [old1.id])
        expectEqual(r.renames.count, 1, "只允许第一条命中，第二条必须因已被占用而放弃")
    }

    /// 别名有上限：只记最近几个名字，不让文件无限膨胀
    func aliasListIsBounded() throws {
        var rec = record(key: "a-1", bundle: wechat, title: "t0", aliases: ["x0"])
        for index in 1...(IdentityLedger.maxAliases + 4) {
            let item = icon(wechat, "t\(index)", ordinal: 0, of: 1)
            IdentityLedger.applyUpdate(to: &rec, now: Date(timeIntervalSince1970: Double(index)),
                                       observedItem: item, drifted: true)
        }
        expectEqual(rec.aliases.count, IdentityLedger.maxAliases)
        expectEqual(rec.driftCount, IdentityLedger.maxAliases + 4, "漂移次数要如实累计，供 UI 提示'按位置认领'")
    }

    /// 清理：用户亲手钉的永不删；推定的超期才删
    func pruneKeepsUserPinned() throws {
        let seen = Date(timeIntervalSince1970: 100_000)
        let old = seen.addingTimeInterval(-(IdentityLedger.retentionInterval + 10))
        let records = [
            record(key: "a-u", bundle: wechat, title: "微信", aliases: ["live"], pinned: .user, at: old),
            record(key: "a-i", bundle: wechat, title: "旧", aliases: ["gone"], pinned: .inferred, at: old),
        ]
        let kept = IdentityLedger.prune(records: records, now: seen, seenIDs: ["live"])
        expectEqual(kept.map(\.assignmentKey), ["a-u"],
                    "用户的选择不能因为 App 那天没运行就消失")
    }

    /// 读不懂的台账文件按"没有台账"处理——激进的回退会把设置接错人
    func unreadableStoreDegradesToEmpty() throws {
        let dir = TestPaths.journalDirectory("ledger-store")
        let url = dir.appendingPathComponent("identity-ledger.json")
        let store = IdentityLedgerStore(url: url)
        expect(store.load().isEmpty, "缺文件时是空台账，不是崩溃")

        var records = [record(key: "a-1", bundle: wechat, title: "微信", aliases: ["wx.1"])]
        records[0].observedTitle = "微信"
        try store.save(records)
        expectEqual(store.load().count, 1, "存进去要能原样读回")

        try "半截的 json".write(to: url, atomically: true, encoding: .utf8)
        expect(store.load().isEmpty, "坏文件必须退回空台账")
    }
}

/// 引擎侧：整条跨重启路径
struct LedgerAcrossLaunchTests {
    /// 起一个引擎。`seeded` 表示"重启后从磁盘恢复的布局"——必须连分区一起带回来；
    /// 只塞 id 不带分区是在模拟一个根本不存在的启动状态（上一版因此得出过假失败）。
    private func makeEngine(store: IdentityLedgerStore, seeded: MenuBarLayout? = nil) -> LayoutEngine {
        LayoutEngine(
            layout: seeded ?? MenuBarLayout(),
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("ledger-\(UUID().uuidString.prefix(6))")),
            ledger: store
        )
    }

    /// 真正的跨启动场景：第一次运行把微信收进隐藏区并落盘；重启后布局里还是旧 id，
    /// 而现场只剩改名后的新 id ⇒ 台账必须把它接回来。
    func assignmentSurvivesRestartAfterRename() throws {
        let wxOld = icon("com.tencent.xinwechat", "微信", ordinal: 0, of: 1)
        let wxNew = icon("com.tencent.xinwechat", "微信 (3)", ordinal: 0, of: 1)
        let url = TestPaths.journalDirectory("ledger-e2e").appendingPathComponent("identity-ledger.json")
        let store = IdentityLedgerStore(url: url)

        // 第一次运行：登记现场 → 用户把微信收进隐藏区
        let first = makeEngine(store: store)
        first.fold(items: [wxOld], newItemZone: .visible)
        first.assignForChecks(wxOld.id, to: .hidden)
        first.fold(items: [wxOld], newItemZone: .visible)     // 让台账记下"这条配置属于隐藏区"
        expectEqual(first.layout.zone(of: wxOld.id), .hidden)

        // 重启：布局从磁盘回来（仍是旧 id），现场已经是新名字
        // 重启：布局要按上一程落盘的样子回来（这里直接用 first.layout，
        // 上一版只把 id 塞回去、丢了分区，等于模拟了一个不存在的启动状态）
        let second = makeEngine(store: store, seeded: first.layout)
        second.fold(items: [wxNew], newItemZone: .visible)

        expectEqual(second.layout.zone(of: wxNew.id), .hidden, "改名后配置没跟过来")
        expectNil(second.layout.zone(of: wxOld.id), "旧 id 要迁净，不能同占两坑")
        expect(second.lastLedgerResolution.ambiguousOwners.isEmpty)
    }
}

extension IdentityLedgerTests {
    static var testCases: [TestCase] {
        let suite = IdentityLedgerTests()
        return [
            TestCase("aliasExactHit", suite.aliasExactHit),
            TestCase("ordinalHitRequiresUnchangedCount", suite.ordinalHitRequiresUnchangedCount),
            TestCase("simultaneousRenamesWithStableOrdinalsMigrate", suite.simultaneousRenamesWithStableOrdinalsMigrate),
            TestCase("trulyAmbiguousTitlesMigrateNothing", suite.trulyAmbiguousTitlesMigrateNothing),
            TestCase("simultaneousRenamesResolveWhenAliasesAreDistinct", suite.simultaneousRenamesResolveWhenAliasesAreDistinct),
            TestCase("singleTargetCannotBeClaimedTwice", suite.singleTargetCannotBeClaimedTwice),
            TestCase("aliasListIsBounded", suite.aliasListIsBounded),
            TestCase("pruneKeepsUserPinned", suite.pruneKeepsUserPinned),
            TestCase("unreadableStoreDegradesToEmpty", suite.unreadableStoreDegradesToEmpty),
        ]
    }
}

extension LedgerAcrossLaunchTests {
    static var testCases: [TestCase] {
        let suite = LedgerAcrossLaunchTests()
        return [TestCase("assignmentSurvivesRestartAfterRename", suite.assignmentSurvivesRestartAfterRename)]
    }
}

// MARK: - 旧版本升级迁移（设计文档 §4）

struct LedgerMigrationTests {
    /// 旧布局的每个 id 各得一条记录；首个别名就是老 id，分区与老布局一致。
    /// 全部标 `inferred`：老数据分不清"用户分配"与"默认落位"，冒充用户会囤误钉。
    func legacyLayoutGrowsOneRecordPerItem() throws {
        var layout = MenuBarLayout()
        layout.append("com.a.x", to: .hidden)
        layout.append("com.b.y", to: .visible)
        let live = icon("com.a", "x", ordinal: 0, of: 1, x: 600)
        let (records, outcome) = IdentityLedgerMigration.migrate(
            layout: layout, observed: [live], now: Date(timeIntervalSince1970: 5_000)
        )
        expectEqual(records.count, 2)
        expectEqual(outcome.migrated, 2)
        expectEqual(outcome.matched, 1, "现场在场的只有 com.a.x")
        let hidden = records.first { $0.aliases == ["com.a.x"] }
        expectEqual(hidden?.zoneRaw, MenuBarZone.hidden.rawValue)
        expectEqual(hidden?.pinnedBy, IdentityRecord.Pin.inferred, "迁移不得冒充用户决定")
        // 现场对上的记录要有 lastSeenAt；否则将来会被 prune 当陈旧清掉
        expect(records.first { $0.aliases == ["com.a.x"] }?.lastSeenAt != .distantPast)
        expect(records.first { $0.aliases == ["com.b.y"] }?.lastSeenAt == .distantPast,
               "不在场的条目不能伪装成刚见过——它该在 30 天后被清理（除非用户钉住）")
    }

    /// id 里拆不出归属时整串当归属：宁可名字难看，不许因为迁移丢条目。
    func oddLegacyIDStillMigrates() throws {
        var layout = MenuBarLayout()
        layout.append("无点号的老id", to: .visible)
        let (records, _) = IdentityLedgerMigration.migrate(layout: layout, observed: [], now: Date())
        expectEqual(records.count, 1)
        expectEqual(records.first?.ownerBundleID, "无点号的老id")
    }

    /// 迁移前旧布局必须有只读备份——迁移 bug 发生时这是唯一的回退路径。
    func backupIsWrittenBeforeMigration() throws {
        let dir = TestPaths.journalDirectory("ledger-migrate")
        let journal = LayoutJournal(directory: dir)
        var layout = MenuBarLayout()
        layout.append("com.a.x", to: .hidden)
        try journal.writeCommitted(layout)
        let backup = dir.appendingPathComponent("layout.committed.pre-ledger.json")
        try IdentityLedgerMigration.backupLegacyLayout(journal: journal, to: backup)
        let restored = try JSONDecoder().decode(MenuBarLayout.self, from: Data(contentsOf: backup))
        expectEqual(restored.zone(of: "com.a.x"), MenuBarZone.hidden)
    }

    /// 引擎侧：有台账/空布局都不迁移；真迁移后 lastMigration 有值且记录已落盘。
    func engineMigratesOnlyWhenNeeded() throws {
        let url = TestPaths.journalDirectory("ledger-engine-mig").appendingPathComponent("identity-ledger.json")
        let store = IdentityLedgerStore(url: url)

        // 空布局 ⇒ 不迁移
        var layout = MenuBarLayout()
        let empty = LayoutEngine(layout: layout,
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("m0")), ledger: store)
        empty.migrateLegacyLayoutIfNeeded(observed: [])
        expectNil(empty.lastMigration)

        // 有布局无台账 ⇒ 迁移一次；再来一次不再重复
        layout.append("com.a.x", to: .hidden)
        let engine = LayoutEngine(layout: layout,
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("m1")), ledger: store)
        let live = icon("com.a", "x", ordinal: 0, of: 1, x: 600)
        engine.migrateLegacyLayoutIfNeeded(observed: [live])
        expectEqual(engine.lastMigration?.migrated, 1)
        expectEqual(store.load().count, 1)

        engine.migrateLegacyLayoutIfNeeded(observed: [live])
        expectEqual(store.load().count, 1, "重复迁移会造出双份记录，把别名表搅乱")
    }
}

extension LedgerMigrationTests {
    static var testCases: [TestCase] {
        let suite = LedgerMigrationTests()
        return [
            TestCase("legacyLayoutGrowsOneRecordPerItem", suite.legacyLayoutGrowsOneRecordPerItem),
            TestCase("oddLegacyIDStillMigrates", suite.oddLegacyIDStillMigrates),
            TestCase("backupIsWrittenBeforeMigration", suite.backupIsWrittenBeforeMigration),
            TestCase("engineMigratesOnlyWhenNeeded", suite.engineMigratesOnlyWhenNeeded),
        ]
    }
}
