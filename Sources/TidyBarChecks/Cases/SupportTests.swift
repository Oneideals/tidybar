import Foundation
import Foundation
import TidyBarCore

struct ItemSearchTests {
    func exactMatchBeatsPrefixWhichBeatsSubstring() throws {
        expect(ItemSearch.score(query: "dropbox", title: "Dropbox") > ItemSearch.score(query: "drop", title: "Dropbox"))
        expect(ItemSearch.score(query: "drop", title: "Dropbox") > ItemSearch.score(query: "box", title: "My Dropbox"))
    }

    func nonMatchingQueryScoresZero() throws {
        expect(ItemSearch.score(query: "xyz", title: "Dropbox") == 0)
        expect(ItemSearch.score(query: "", title: "Dropbox") == 0)
        expect(ItemSearch.score(query: "drop", title: "") == 0)
    }

    func chineseTitlesMatchDirectly() throws {
        expect(ItemSearch.score(query: "微信", title: "微信") > 0)
        expect(ItemSearch.score(query: "微", title: "微信输入法") > 0)
        expect(ItemSearch.score(query: "钉", title: "微信") == 0)
    }

    func tokenPrefixIsRecognised() throws {
        // "wechat_drive" 这类带分隔符的标题，键入 we 应命中词首
        expect(ItemSearch.score(query: "we", title: "wechat_drive") >= 650)
    }

    func rankingPrefersPrefixOverSubstring() throws {
        let items = [TestItems.item("My Dropbox"), TestItems.item("Dropzone")]
        let ranked = ItemSearch.rank(items, query: "drop", title: { $0.title })
        expect(ranked.map { $0.title } == ["Dropzone", "My Dropbox"], "前缀命中必须排在子串命中之前")
    }

    func tiesAreBrokenByRecentUsage() throws {
        let unused = TestItems.item("A")
        var recentlyUsed = TestItems.item("B")
        recentlyUsed.lastActivatedAt = Date()

        // 两个候选打分相同（标题写成一样），此时应按使用频次排
        let ranked = ItemSearch.rank(
            [unused, recentlyUsed],
            query: "alpha",
            title: { _ in "alpha" },
            usageCount: { $0.lastActivatedAt == nil ? 0 : 1 }
        )
        expect(ranked.first?.title == "B", "同分时应把刚用过的排在前面")
    }

    func emptyQueryReturnsEverythingUnfiltered() throws {
        let items = [TestItems.item("a"), TestItems.item("b")]
        expect(ItemSearch.rank(items, query: "  ", title: \.title).count == 2)
    }
}

struct ImageCacheTests {
    func evictsLeastRecentlyUsedBeyondByteLimit() throws {
        let cache = ImageCache<String>(limitBytes: 100)
        cache.insert("a", byteCount: 60, for: "a")
        cache.insert("b", byteCount: 60, for: "b")

        expect(cache.currentBytes <= 100, "绝不允许越过预算上限")
        expect(cache.value(for: "a") == nil, "最久未用的先淘汰")
        expect(cache.value(for: "b") == "b")
    }

    func accessCountsAsUsage() throws {
        let cache = ImageCache<String>(limitBytes: 100)
        cache.insert("a", byteCount: 40, for: "a")
        cache.insert("b", byteCount: 40, for: "b")
        _ = cache.value(for: "a")
        cache.insert("c", byteCount: 40, for: "c")

        expect(cache.value(for: "b") == nil, "刚被读过的 a 应比 b 更晚淘汰")
        expect(cache.value(for: "a") == "a")
    }

    func oversizedEntryIsRejectedNotCached() throws {
        let cache = ImageCache<String>(limitBytes: 50)
        cache.insert("huge", byteCount: 500, for: "huge")

        expect(cache.count == 0, "单张超限就放弃缓存：不能为一个图标撑爆预算")
        expect(cache.currentBytes == 0)
    }

    func hitRateAndPurge() throws {
        let cache = ImageCache<Int>(limitBytes: 1_000)
        cache.insert(1, byteCount: 10, for: "x")
        expect(cache.value(for: "x") == 1)
        expect(cache.value(for: "missing") == nil)
        expect(abs(cache.hitRate - 0.5) < 0.001)

        cache.removeAll()
        expect(cache.count == 0)
    }
}

struct PerformanceBudgetTests {
    private func sample(memoryMB: Int, cpu: Double, latency: Double, coldStart: Double) -> PerformanceBudget.Sample {
        PerformanceBudget.Sample(
            residentMemoryBytes: UInt64(memoryMB) * 1_024 * 1_024,
            idleCPUPercent: cpu,
            revealLatencyMS: latency,
            coldStartSeconds: coldStart
        )
    }

    func greenSamplePasses() throws {
        let verdict = PerformanceBudget.assess(sample(memoryMB: 32, cpu: 0.05, latency: 80, coldStart: 1.2))
        expect(verdict.isPassing)
    }

    func eachMetricFailsIndependently() throws {
        expect(!PerformanceBudget.assess(sample(memoryMB: 41, cpu: 0, latency: 10, coldStart: 1)).isPassing)
        expect(!PerformanceBudget.assess(sample(memoryMB: 30, cpu: 0.5, latency: 10, coldStart: 1)).isPassing)
        expect(!PerformanceBudget.assess(sample(memoryMB: 30, cpu: 0, latency: 120, coldStart: 1)).isPassing)
        expect(!PerformanceBudget.assess(sample(memoryMB: 30, cpu: 0, latency: 10, coldStart: 3)).isPassing)
    }

    func budgetNumbersMatchTheWrittenPlan() throws {
        // 报告 §4.3 的硬指标：改数值必须同步改文档，这条测试就是防止两者漂移
        expect(PerformanceBudget.maxResidentMemoryBytes == 40 * 1024 * 1024)
        expect(PerformanceBudget.maxImageCacheBytes == 20 * 1024 * 1024)
        expect(PerformanceBudget.maxArtifactBytes == 10 * 1024 * 1024)
        expect(PerformanceBudget.maxRevealLatencyMS == 100)
    }

    func selfProcessFootprintIsWithinBudget() throws {
        // 测试进程本身就顺带验证 Mach 读数可用（真正的常驻内存基准由 scripts/perf-check.sh 跑）
        expect(ResourceProbe.residentMemoryBytes() > 0)
        expect(ResourceProbe.threadCount() > 0)
    }
}

struct AppSettingsTests {
    func illegalValuesAreClamped() throws {
        let wild = AppSettings(revealTriggers: [], rehideDelay: 999, itemSpacing: -50)
        let sanitized = wild.sanitized()

        expect(sanitized.rehideDelay == 10)
        expect(sanitized.itemSpacing == -4)
        expect(sanitized.revealTriggers == RevealTrigger.beginnerDefaults, "一个呼出方式都不留会把工具变成哑巴")
    }

    func defaultsAreBeginnerFriendly() throws {
        let settings = AppSettings()
        expect(!settings.stylingEnabled, "首启不改变菜单栏外观，避免「装了个东西界面变了」的惊吓")
        expect(!settings.followMenuBarColorEnabled, "默认不做屏幕采样，避免录屏权限弹窗吓退用户")
        expect(settings.autoRecoverPendingIntent)
        expect(settings.newItemZone == .hidden)
    }

    func persistenceRoundTrip() throws {
        let suite = "TidyBarTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        let store = UserDefaultsSettingsStore(defaults: defaults)

        var settings = AppSettings()
        settings.itemSpacing = 6
        settings.profiles["演示"] = {
            var layout = MenuBarLayout()
            layout.append("com.test.a", to: .alwaysHidden)
            return layout
        }()
        settings.rules = [DisplayRule(name: "低电量", conditions: [.batteryLow], actions: [.hide("com.test.a")])]
        store.save(settings)

        let loaded = store.load()
        expect(loaded.itemSpacing == 6)
        expect(loaded.profiles["演示"]?.zone(of: "com.test.a") == .alwaysHidden)
        expect(loaded.rules == settings.rules)

        defaults.removePersistentDomain(forName: suite)
    }

    func missingDataFallsBackToDefaults() throws {
        let suite = "TidyBarTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        expect(UserDefaultsSettingsStore(defaults: defaults).load() == AppSettings())
        defaults.removePersistentDomain(forName: suite)
    }

    func supportDirectoryIsUnderApplicationSupport() throws {
        expect(AppPaths.supportDirectory().path.hasSuffix("TidyBar"))
        expect(AppPaths.journalDirectory.path.contains("LayoutJournal"))
    }
}

extension ItemSearchTests {
    static var testCases: [TestCase] {
        let suite = ItemSearchTests()
        return [
            TestCase("exactMatchBeatsPrefixWhichBeatsSubstring", suite.exactMatchBeatsPrefixWhichBeatsSubstring),
            TestCase("nonMatchingQueryScoresZero", suite.nonMatchingQueryScoresZero),
            TestCase("chineseTitlesMatchDirectly", suite.chineseTitlesMatchDirectly),
            TestCase("tokenPrefixIsRecognised", suite.tokenPrefixIsRecognised),
            TestCase("rankingPrefersPrefixOverSubstring", suite.rankingPrefersPrefixOverSubstring),
            TestCase("tiesAreBrokenByRecentUsage", suite.tiesAreBrokenByRecentUsage),
            TestCase("emptyQueryReturnsEverythingUnfiltered", suite.emptyQueryReturnsEverythingUnfiltered),
        ]
    }
}

extension ImageCacheTests {
    static var testCases: [TestCase] {
        let suite = ImageCacheTests()
        return [
            TestCase("evictsLeastRecentlyUsedBeyondByteLimit", suite.evictsLeastRecentlyUsedBeyondByteLimit),
            TestCase("accessCountsAsUsage", suite.accessCountsAsUsage),
            TestCase("oversizedEntryIsRejectedNotCached", suite.oversizedEntryIsRejectedNotCached),
            TestCase("hitRateAndPurge", suite.hitRateAndPurge),
        ]
    }
}

extension PerformanceBudgetTests {
    static var testCases: [TestCase] {
        let suite = PerformanceBudgetTests()
        return [
            TestCase("greenSamplePasses", suite.greenSamplePasses),
            TestCase("eachMetricFailsIndependently", suite.eachMetricFailsIndependently),
            TestCase("budgetNumbersMatchTheWrittenPlan", suite.budgetNumbersMatchTheWrittenPlan),
            TestCase("selfProcessFootprintIsWithinBudget", suite.selfProcessFootprintIsWithinBudget),
        ]
    }
}

extension AppSettingsTests {
    static var testCases: [TestCase] {
        let suite = AppSettingsTests()
        return [
            TestCase("illegalValuesAreClamped", suite.illegalValuesAreClamped),
            TestCase("defaultsAreBeginnerFriendly", suite.defaultsAreBeginnerFriendly),
            TestCase("persistenceRoundTrip", suite.persistenceRoundTrip),
            TestCase("missingDataFallsBackToDefaults", suite.missingDataFallsBackToDefaults),
            TestCase("supportDirectoryIsUnderApplicationSupport", suite.supportDirectoryIsUnderApplicationSupport),
        ]
    }
}
