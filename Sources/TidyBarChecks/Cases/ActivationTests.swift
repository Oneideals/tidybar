import Foundation
import CoreGraphics
import TidyBarCore

// MARK: - 点击转发（报告 A3/A8：面板与搜索结果里的一次点击必须打到真实图标上）

final class SpyActivator: MenuBarActivating {
    var outcome: ActivationOutcome = .pressed
    private(set) var requested: [String] = []

    func activate(itemID: String) -> ActivationOutcome {
        requested.append(itemID)
        return outcome
    }
}

struct ActivationTests {
    func secondaryClickNeverFallsBackToPrimaryClick() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        let outcome = controller.showMenu(itemID: "com.test.a")
        expectEqual(outcome, .actionUnsupported, "不支持右键时必须明确失败，不能改发左键")
        expect(spy.requested.isEmpty, "右键请求不能调用 activate")
    }

    private func makeController(
        activator: MenuBarActivating?,
        mover: MenuBarMoving? = FakeMenuBarMover(),
        ids: [String] = ["com.test.a", "com.test.b"]
    ) -> (TidyBarController, FakeMenuBarReader) {
        let reader = FakeMenuBarReader(ids: ids)
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: SystemServices(
                reader: reader, mover: mover, cursor: FakeCursor(),
                accessibility: FakeTrust(), screens: FakeScreens(), activator: activator
            ),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("activation"))
        )
        var seeded = MenuBarLayout()
        for id in ids { seeded.append(id, to: .visible) }
        seeded.move(itemID: "com.test.b", to: .alwaysHidden, position: nil)
        engine.adoptLayoutForChecks(seeded)
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(),
            store: FakeSettingsStore()
        )
        return (controller, reader)
    }

    /// 代点必须把 id 原样交下去（不是下标、不是标题：88% 图标没有可读标题）
    func forwardsTheItemID() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        let outcome = controller.activate(itemID: "com.test.a")

        expectEqual(outcome, .pressed)
        expectEqual(spy.requested, ["com.test.a"])
        expect(controller.logs.last?.contains("已代点 com.test.a") ?? false, "\(controller.logs)")
    }

    /// 装配没接通点击转发时**绝不能静默成功**：UI 需要一句能显示给用户的原因
    func missingActivatorIsReportedNotSwallowed() throws {
        let (controller, _) = makeController(activator: nil)
        let outcome = controller.activate(itemID: "com.test.a")
        expectEqual(outcome, .actionUnsupported)
        expect(controller.logs.last?.contains("不允许工具代点") ?? false,
               "失败原因必须进诊断日志，否则用户只会看到「点了没反应」：\(controller.logs)")
    }

    /// 占位实现同样不得报成成功
    func placeholderActivatorNeverClaimsSuccess() throws {
        expectEqual(UnverifiedMenuBarActivator().activate(itemID: "x"), .actionUnsupported)
    }

    /// 真机实测：带菜单的状态项在 AXPress 后进入模态跟踪，系统常回 kAXErrorCannotComplete，
    /// 但菜单确实打开了。把它算成"被拒绝"会让用户重复点击，所以单独归类。
    func unconfirmedPressCountsAsPressed() throws {
        expect(UnverifiedMenuBarActivator().activate(itemID: "x").countsAsPressed == false)
        expect(ActivationOutcome.pressedUnconfirmed(code: -25204).countsAsPressed)
        expect(ActivationOutcome.pressed.countsAsPressed)
        expect(ActivationOutcome.failed(code: -25204).countsAsPressed == false)
        expect(ActivationOutcome.itemNotFound.countsAsPressed == false)
        expect(ActivationOutcome.elementNotFound.countsAsPressed == false)

        let spy = SpyActivator()
        spy.outcome = .pressedUnconfirmed(code: -25204)
        let (controller, _) = makeController(activator: spy)
        _ = controller.activate(itemID: "com.test.a")
        expect(controller.logs.last?.contains("已代点") ?? false,
               "生效但无回执要按成功记账：\(controller.logs)")
    }

    /// 隐藏区里的图标被代点前先呼出隐藏区，否则用户点完看不到反应
    func activatingAlwaysHiddenItemRevealsFirst() throws {
        let spy = SpyActivator()
        let (controller, _) = makeController(activator: spy)
        _ = controller.activate(itemID: "com.test.b")
        expect(controller.snapshot.isRevealed, "始终隐藏区的项应先呼出")
        expectEqual(spy.requested, ["com.test.b"], "呼出之后仍要把点击转给同一个 id")
    }

    /// 代点不产生状态变更：不该写 journal、不该留下 pending
    func activationDoesNotTouchJournal() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("activation-journal"))
        let reader = FakeMenuBarReader(ids: ["com.test.a"])
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: SystemServices(
                reader: reader, mover: FakeMenuBarMover(), cursor: FakeCursor(),
                accessibility: FakeTrust(), screens: FakeScreens(), activator: SpyActivator()
            ),
            journal: journal
        )
        _ = engine.activate(itemID: "com.test.a")
        expect(!journal.hasPendingIntent, "代点不是布局变更，不得写 pending")
        expectNil(journal.readCommittedLayout(), "代点不得改写已提交布局")
    }
}

extension ActivationTests {
    static var testCases: [TestCase] {
        let suite = ActivationTests()
        return [
            TestCase("secondaryClickNeverFallsBackToPrimaryClick", suite.secondaryClickNeverFallsBackToPrimaryClick),
            TestCase("forwardsTheItemID", suite.forwardsTheItemID),
            TestCase("missingActivatorIsReportedNotSwallowed", suite.missingActivatorIsReportedNotSwallowed),
            TestCase("placeholderActivatorNeverClaimsSuccess", suite.placeholderActivatorNeverClaimsSuccess),
            TestCase("unconfirmedPressCountsAsPressed", suite.unconfirmedPressCountsAsPressed),
            TestCase("activatingAlwaysHiddenItemRevealsFirst", suite.activatingAlwaysHiddenItemRevealsFirst),
            TestCase("activationDoesNotTouchJournal", suite.activationDoesNotTouchJournal),
        ]
    }
}
