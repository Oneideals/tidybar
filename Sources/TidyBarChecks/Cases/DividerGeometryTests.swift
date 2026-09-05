import Foundation
import TidyBarCore

// MARK: - 分隔符几何与"合法落点"（菜单改分区在接管模式下能不能真生效）

struct DividerGeometryTests {
    private func item(_ id: String, midX: CGFloat) -> ManagedItem {
        ManagedItem(
            id: id, ownerBundleID: "com.test." + id, title: id,
            frame: CGRect(x: midX - 12, y: 1_188, width: 24, height: 24),
            isSystemOwned: false, identitySource: .axTitle,
            ordinalInOwner: 0, ownerItemCount: 1
        )
    }

    /// 没有分隔符 ⇒ 一律判"常驻"。宁可什么都不藏，也不能凭猜测把用户的图标收起来。
    func withoutDividersNothingIsHidden() throws {
        expectEqual(DividerGeometry.zone(forX: 900, leftEdge: nil, rightEdge: nil), MenuBarZone.visible)
    }

    /// 从右往左：常驻 → 收纳 → 始终隐藏（对齐 Ice 的心智模型）
    func threeRegionsFromRightToLeft() throws {
        let left: CGFloat = 500, right: CGFloat = 900
        expectEqual(DividerGeometry.zone(forX: 950, leftEdge: left, rightEdge: right), MenuBarZone.visible)
        expectEqual(DividerGeometry.zone(forX: 700, leftEdge: left, rightEdge: right), MenuBarZone.hidden)
        expectEqual(DividerGeometry.zone(forX: 400, leftEdge: left, rightEdge: right), MenuBarZone.alwaysHidden)
    }

    /// 落点必须踩在目标区邻居的槽位上（findings/02：拖进空隙会被系统静默忽略）
    func landingPointFallsOnNeighbourSlot() throws {
        let ordered = [
            item("a", midX: 300),                       // 要挪去收纳区的项
            item("d1", midX: 500),                      // 左分隔符
            item("h1", midX: 700), item("h2", midX: 730),   // 收纳区已有邻居
            item("d2", midX: 900),                      // 右分隔符
            item("v1", midX: 1100),
        ]
        guard let x = DividerGeometry.landingX(
            for: "a", to: .hidden, ordered: ordered, leftEdge: 500, rightEdge: 900,
            dividerIDs: ["d1", "d2"]
        ) else {
            try record("给不出落点，菜单改分区就又变成静默不生效")
            return
        }
        // 往后插要越过邻居右缘才稳（findings/02 的真机结论），不是取中心：
        // h1 中心 700、宽 24 ⇒ 右缘 712 + 2 = 714，仍在 h2(730) 之前，确实落在收纳区内。
        expectEqual(x, 714)
    }

    /// 已经在目标区内就别拖：一次没有意义的 ⌘ 拖拽也是风险
    func alreadyInsideRegionNeedsNoDrag() throws {
        let ordered = [item("d1", midX: 500), item("a", midX: 700), item("d2", midX: 900)]
        expectNil(DividerGeometry.landingX(for: "a", to: .hidden, ordered: ordered,
                                           leftEdge: 500, rightEdge: 900, dividerIDs: ["d1", "d2"]))
    }

    /// 目标区一个邻居都没有 ⇒ 明确给不出落点，而不是随便猜一个像素
    func emptyRegionRefusesToGuess() throws {
        let ordered = [item("a", midX: 300), item("d1", midX: 500), item("d2", midX: 900)]
        expectNil(DividerGeometry.landingX(for: "a", to: .hidden, ordered: ordered,
                                           leftEdge: 500, rightEdge: 900, dividerIDs: ["d1", "d2"]),
                  "目标区没有真邻居时不许拿分隔符凑数")
    }

    /// 分隔符自己不能被划进隐藏区——那等于工具把自己藏掉
    func dividersAreNeverAssigned() throws {
        let items = [item("user", midX: 700), item("leftDivider", midX: 500), item("rightDivider", midX: 900)]
        let map = DividerGeometry.assignments(
            of: items, dividers: [items[1], items[2]], defaultZone: .hidden
        )
        expectEqual(map["user"], MenuBarZone.hidden)
        expectNil(map["leftDivider"])
        expectNil(map["rightDivider"])
    }

    /// 忘记排除分隔符会算出 914（把边界当住户），这条把 bug 钉死在测试里。
    func dividerAsNeighbourWouldOvershoot() throws {
        let ordered = [item("a", midX: 300), item("d1", midX: 500), item("d2", midX: 900)]
        let withExclusion = DividerGeometry.landingX(
            for: "a", to: .hidden, ordered: ordered, leftEdge: 500, rightEdge: 900, dividerIDs: ["d1", "d2"]
        )
        expectNil(withExclusion, "排除边界后没有真邻居，就该给不出落点")
    }

    /// 端到端：接管模式 + 没有分隔符时，菜单改分区应当靠"现有分区里的同伴"拿到落点并真的生效
    func assignmentWorksInTakeoverModeViaPeers() throws {
        let reader = FakeMenuBarReader(items: [
            ManagedItem(id: "com.test.a", ownerBundleID: "com.test.a", title: "a",
                        frame: CGRect(x: 588, y: 1_188, width: 24, height: 24),
                        isSystemOwned: false, identitySource: .axTitle, ordinalInOwner: 0, ownerItemCount: 1),
            ManagedItem(id: "com.test.b", ownerBundleID: "com.test.b", title: "b",
                        frame: CGRect(x: 618, y: 1_188, width: 24, height: 24),
                        isSystemOwned: false, identitySource: .axTitle, ordinalInOwner: 0, ownerItemCount: 1),
        ])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        var layout = MenuBarLayout()
        layout.append("com.test.a", to: .visible)
        layout.append("com.test.b", to: .hidden)
        let engine = LayoutEngine(
            layout: layout,
            services: makeServices(reader: reader, mover: mover),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("divider-assign"))
        )
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(),
            store: FakeSettingsStore()
        )
        controller.applyScan(reader.discoverItems())

        expect(controller.move("com.test.a", to: .hidden), "把 a 收进隐藏区应给出合法落点并生效")
        expectEqual(engine.layout.zone(of: "com.test.a"), MenuBarZone.hidden)
        expectEqual(mover.moved.count, 1, "没有落点就不该发起拖拽；反过来它必须真的被调用一次")
    }
}

extension DividerGeometryTests {
    static var testCases: [TestCase] {
        let suite = DividerGeometryTests()
        return [
            TestCase("withoutDividersNothingIsHidden", suite.withoutDividersNothingIsHidden),
            TestCase("threeRegionsFromRightToLeft", suite.threeRegionsFromRightToLeft),
            TestCase("landingPointFallsOnNeighbourSlot", suite.landingPointFallsOnNeighbourSlot),
            TestCase("alreadyInsideRegionNeedsNoDrag", suite.alreadyInsideRegionNeedsNoDrag),
            TestCase("emptyRegionRefusesToGuess", suite.emptyRegionRefusesToGuess),
            TestCase("dividersAreNeverAssigned", suite.dividersAreNeverAssigned),
            TestCase("dividerAsNeighbourWouldOvershoot", suite.dividerAsNeighbourWouldOvershoot),
            TestCase("assignmentWorksInTakeoverModeViaPeers", suite.assignmentWorksInTakeoverModeViaPeers),
        ]
    }
}
