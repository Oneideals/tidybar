import Foundation
import Foundation
import TidyBarCore

/// 构造 SystemContext 的测试助手：默认取一个工作日下午
private func makeContext(
    battery: Double?,
    charging: Bool = false,
    wifi: String? = "Office",
    focus: String? = nil,
    frontmost: String? = nil,
    at moment: Date? = nil
) -> SystemContext {
    SystemContext(
        batteryLevel: battery,
        isCharging: charging,
        connectedWiFiSSID: wifi,
        activeFocusMode: focus,
        frontmostAppBundleID: frontmost,
        now: moment ?? TestDates.onWeekday(hour: 14, minute: 30),
        calendar: fixedCalendar()
    )
}

private func evaluated(_ condition: RuleCondition, _ context: SystemContext, wifiKnown: Bool = true, sharing: Bool = false) -> Bool {
    condition.evaluate(context, hasKnownWiFiState: wifiKnown, isScreenShareActive: sharing)
}

struct RuleConditionTests {
    func batteryThresholds() throws {
        let low = makeContext(battery: 0.15)
        expect(evaluated(.batteryLow, low))
        expect(!evaluated(.batteryCritical, low))

        let critical = makeContext(battery: 0.08)
        expect(evaluated(.batteryCritical, critical))
    }

    func desktopWithoutBatteryNeverMatchesBatteryRules() throws {
        let desktop = makeContext(battery: nil)
        expect(!evaluated(.batteryLow, desktop))
        expect(!evaluated(.onBatteryPower, desktop), "台式机读不到电量时不得触发电池规则")
    }

    func wifiUnknownStateDoesNotTriggerDisconnectRule() throws {
        let unknown = makeContext(battery: 0.9, wifi: nil)
        expect(
            !evaluated(.wifiDisconnected, unknown, wifiKnown: false),
            "读不到 Wi-Fi 状态时不得误判为已断开，否则会错误隐藏/显示图标"
        )
        expect(evaluated(.wifiDisconnected, unknown, wifiKnown: true))
    }

    func nightRangeWrapsMidnight() throws {
        expect(RuleCondition.inHourRange(23, start: 22, end: 7))
        expect(RuleCondition.inHourRange(3, start: 22, end: 7))
        expect(!RuleCondition.inHourRange(12, start: 22, end: 7))
        expect(RuleCondition.inHourRange(9, start: 9, end: 18))
        expect(!RuleCondition.inHourRange(18, start: 9, end: 18), "右端为开区间")
    }

    func workingHoursIgnoreWeekends() throws {
        let weekend = makeContext(battery: 0.9, at: TestDates.onWeekend(hour: 11))
        expect(!evaluated(.workingHours, weekend), "周末不算工作时段")

        let weekday = makeContext(battery: 0.9, at: TestDates.onWeekday(hour: 11))
        expect(evaluated(.workingHours, weekday))

        let lateNight = makeContext(battery: 0.9, at: TestDates.onWeekday(hour: 21))
        expect(!evaluated(.workingHours, lateNight))
    }

    func focusAndScreenShare() throws {
        expect(evaluated(.focusModeActive, makeContext(battery: 0.9, focus: "勿扰模式")))
        expect(!evaluated(.focusModeActive, makeContext(battery: 0.9)))

        let plain = makeContext(battery: 0.9)
        expect(evaluated(.screenSharingLikely, plain, sharing: true))
        expect(!evaluated(.screenSharingLikely, plain, sharing: false))
    }
}

struct RuleEngineTests {
    private let engine = RuleEngine()
    private let icon = "com.test.dropbox"

    private var layoutWithVisibleIcon: MenuBarLayout {
        var layout = MenuBarLayout()
        layout.append(icon, to: .visible)
        return layout
    }

    func singleConditionRuleHidesIcon() throws {
        let rule = DisplayRule(name: "低电量收电池", conditions: [.batteryLow], actions: [.hide(icon)])
        let batch = engine.evaluate(rules: [rule], context: makeContext(battery: 0.12), currentLayout: layoutWithVisibleIcon)
        expect(batch.changes.count == 1)
        expect(batch.changes.first?.to == .hidden)
        expect(batch.changes.first?.from == .visible)
    }

    func conditionsAreAndSemantics() throws {
        let rule = DisplayRule(name: "低电量且未充电", conditions: [.batteryLow, .notCharging], actions: [.hide(icon)])
        expect(!engine.evaluate(rules: [rule], context: makeContext(battery: 0.12), currentLayout: layoutWithVisibleIcon).isEmpty)

        let charging = engine.evaluate(
            rules: [rule],
            context: makeContext(battery: 0.12, charging: true),
            currentLayout: layoutWithVisibleIcon
        )
        expect(charging.isEmpty, "条件之一不满足时不得触发动作")
    }

    func higherPriorityRuleWinsPerItem() throws {
        let weak = DisplayRule(name: "泛用", conditions: [.batteryLow], actions: [.alwaysHide(icon)], priority: 200)
        let strong = DisplayRule(name: "投屏", conditions: [.batteryLow], actions: [.hide(icon)], priority: 1)

        let batch = engine.evaluate(rules: [weak, strong], context: makeContext(battery: 0.1), currentLayout: layoutWithVisibleIcon)
        expect(batch.changes.count == 1, "同一图标只能有一条结论，否则图标会来回抖")
        expect(batch.changes.first?.to == .hidden)
        expect(batch.changes.first?.sourceRule == "投屏")
    }

    func disabledRuleIgnored() throws {
        var rule = DisplayRule(name: "禁用", conditions: [.batteryLow], actions: [.hide(icon)])
        rule.isEnabled = false
        expect(engine.evaluate(rules: [rule], context: makeContext(battery: 0.1), currentLayout: layoutWithVisibleIcon).isEmpty)
    }

    func unevaluableRuleSkipped() throws {
        let noActions = DisplayRule(name: "空动作", conditions: [.batteryLow], actions: [])
        expect(engine.evaluate(rules: [noActions], context: makeContext(battery: 0.1), currentLayout: layoutWithVisibleIcon).isEmpty)
    }

    func idempotencyPreventsIconJitter() throws {
        // 图标已在目标分区，不应再产出变更（否则规则每轮都会重排一遍）
        var layout = MenuBarLayout()
        layout.append(icon, to: .hidden)
        let rule = DisplayRule(name: "低电量", conditions: [.batteryLow], actions: [.hide(icon)])
        expect(engine.evaluate(rules: [rule], context: makeContext(battery: 0.1), currentLayout: layout).isEmpty)
    }

    func profileActionCollectedWithoutDuplicates() throws {
        let a = DisplayRule(name: "A", conditions: [.batteryLow], actions: [.applyProfile("演示")])
        let b = DisplayRule(name: "B", conditions: [.batteryCritical], actions: [.applyProfile("演示")])
        let batch = engine.evaluate(rules: [a, b], context: makeContext(battery: 0.05), currentLayout: MenuBarLayout())
        expect(batch.appliedProfiles == ["演示"])
    }

    func batchAppliesToLayout() throws {
        let rule = DisplayRule(name: "勿扰", conditions: [.focusModeActive], actions: [.hide(icon)])
        let batch = engine.evaluate(rules: [rule], context: makeContext(battery: 0.9, focus: "勿扰"), currentLayout: layoutWithVisibleIcon)
        expect(engine.applying(batch, to: layoutWithVisibleIcon).zone(of: icon) == .hidden)
    }

    func ruleCodableRoundTrip() throws {
        let rule = DisplayRule(name: "低电量", conditions: [.batteryLow, .notCharging], actions: [.hide(icon), .alwaysHide("x")])
        let data = try JSONEncoder().encode([rule])
        expect(try JSONDecoder().decode([DisplayRule].self, from: data) == [rule])
    }
}

extension RuleConditionTests {
    static var testCases: [TestCase] {
        let suite = RuleConditionTests()
        return [
            TestCase("batteryThresholds", suite.batteryThresholds),
            TestCase("desktopWithoutBatteryNeverMatchesBatteryRules", suite.desktopWithoutBatteryNeverMatchesBatteryRules),
            TestCase("wifiUnknownStateDoesNotTriggerDisconnectRule", suite.wifiUnknownStateDoesNotTriggerDisconnectRule),
            TestCase("nightRangeWrapsMidnight", suite.nightRangeWrapsMidnight),
            TestCase("workingHoursIgnoreWeekends", suite.workingHoursIgnoreWeekends),
            TestCase("focusAndScreenShare", suite.focusAndScreenShare),
        ]
    }
}

extension RuleEngineTests {
    static var testCases: [TestCase] {
        let suite = RuleEngineTests()
        return [
            TestCase("singleConditionRuleHidesIcon", suite.singleConditionRuleHidesIcon),
            TestCase("conditionsAreAndSemantics", suite.conditionsAreAndSemantics),
            TestCase("higherPriorityRuleWinsPerItem", suite.higherPriorityRuleWinsPerItem),
            TestCase("disabledRuleIgnored", suite.disabledRuleIgnored),
            TestCase("unevaluableRuleSkipped", suite.unevaluableRuleSkipped),
            TestCase("idempotencyPreventsIconJitter", suite.idempotencyPreventsIconJitter),
            TestCase("profileActionCollectedWithoutDuplicates", suite.profileActionCollectedWithoutDuplicates),
            TestCase("batchAppliesToLayout", suite.batchAppliesToLayout),
            TestCase("ruleCodableRoundTrip", suite.ruleCodableRoundTrip),
        ]
    }
}
