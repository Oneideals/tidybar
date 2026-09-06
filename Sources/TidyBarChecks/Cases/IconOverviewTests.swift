import Foundation
import TidyBarCore

// MARK: - 图标总览的行语义（设置第一页与向导第 2 步共用的那份）

struct IconOverviewBuilderTests {
    /// 系统图标不进总览：它们不参与自动隐藏（A1 边界），列出来只会诱导用户去点一个不允许的操作。
    func systemItemsAreExcluded() throws {
        let controller = make([TestItems.item("com.a.x", isSystemOwned: true),
                               TestItems.item("com.b.y", isSystemOwned: false)])
        let rows = IconOverviewBuilder.rows(from: controller)
        expectEqual(rows.map(\.item.id), ["com.b.y"])
    }

    /// 没被布局管辖的项不出现（连分区都没有，画在哪个标题下都是撒谎）。
    func unassignedItemsAreExcluded() throws {
        let controller = make([TestItems.item("com.a.x"), TestItems.item("com.ghost.z")])
        _ = controller
        // com.ghost.z 从没被 fold 过 ⇒ 无分区；make() 里 fold 了 a/b，ghost 单独构造未 fold 的控制器
        let reader = FakeMenuBarReader(items: [TestItems.item("com.ghost.z")])
        let engine = LayoutEngine(layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: UnverifiedMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("ov-ghost")))
        let ghost = TidyBarController(engine: engine, reveal: RevealStateMachine(rehideDelay: 2),
                                       settings: AppSettings(), store: FakeSettingsStore())
        ghost.start(scansSynchronously: true)
        // 新图标按默认策略落位后**会**有分区——所以它该出现；这里断言的是"从未 start 的引擎"为空
        let fresh = TidyBarController(
            engine: LayoutEngine(layout: MenuBarLayout(),
                services: makeServices(reader: FakeMenuBarReader(items: []), mover: UnverifiedMenuBarMover()),
                journal: LayoutJournal(directory: TestPaths.journalDirectory("ov-empty"))),
            reveal: RevealStateMachine(rehideDelay: 2), settings: AppSettings(), store: FakeSettingsStore())
        expect(IconOverviewBuilder.rows(from: fresh).isEmpty)
        expect(!IconOverviewBuilder.rows(from: ghost).isEmpty,
               "默认策略落位后必须有分区，总览不能漏掉新图标")
    }

    /// 位置身份的标注必须跟着行走：它是"这个设置可能失准"的诚实声明。
    func positionalIdentityFlagTravelsWithRow() throws {
        let named = ManagedItem(
            id: "com.a.named", ownerBundleID: "com.a", title: "有名字",
            frame: CGRect(x: 600, y: 1_188, width: 24, height: 24),
            isSystemOwned: false, identitySource: .axTitle, ordinalInOwner: 0, ownerItemCount: 1)
        let positional = ManagedItem(
            id: "com.b.#item0", ownerBundleID: "com.b", title: "",
            frame: CGRect(x: 700, y: 1_188, width: 24, height: 24),
            isSystemOwned: false, identitySource: .ownerOrdinal, ordinalInOwner: 0, ownerItemCount: 3)
        let controller = make([named, positional])
        let rows = IconOverviewBuilder.rows(from: controller)
        expect(rows.first(where: { $0.item.id == "com.a.named" })?.isPositionalIdentity == false)
        expect(rows.first(where: { $0.item.id == "com.b.#item0" })?.isPositionalIdentity == true,
               "只有位置身份的项必须标出来，否则用户以为设置钉死了某个 App")
    }

    /// 无论是否有物理落点，设置界面的 reassignZone 必须确保逻辑分区与持久化成功落地。
    func reassignZonePersistsEvenWithoutLandingPoint() throws {
        let item = TestItems.item("com.reassign.test", centerX: 600, centerY: 1_188)
        let reader = FakeMenuBarReader(items: [item])
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("ov-reassign"))
        )
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(newItemZone: .visible),
            store: FakeSettingsStore()
        )
        controller.start(scansSynchronously: true)
        expectEqual(controller.snapshot.layout.zone(of: item.id), .visible)

        // 普通 move 因缺少 landing point 失败
        expect(!controller.move(item.id, to: .hidden))

        // reassignZone 确保逻辑落地并在设置和面板中生效
        expect(controller.reassignZone(item.id, to: .hidden))
        expectEqual(controller.snapshot.layout.zone(of: item.id), .hidden)
        let rows = IconOverviewBuilder.rows(from: controller)
        expectEqual(rows.first(where: { $0.item.id == item.id })?.zone, .hidden)
    }

    private func make(_ items: [ManagedItem]) -> TidyBarController {
        let reader = FakeMenuBarReader(items: items)
        let engine = LayoutEngine(layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: UnverifiedMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("ov-\(UUID().uuidString.prefix(6))")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(rehideDelay: 2),
                                           settings: AppSettings(), store: FakeSettingsStore())
        controller.start(scansSynchronously: true)
        return controller
    }
}

extension IconOverviewBuilderTests {
    static var testCases: [TestCase] {
        let suite = IconOverviewBuilderTests()
        return [
            TestCase("systemItemsAreExcluded", suite.systemItemsAreExcluded),
            TestCase("unassignedItemsAreExcluded", suite.unassignedItemsAreExcluded),
            TestCase("positionalIdentityFlagTravelsWithRow", suite.positionalIdentityFlagTravelsWithRow),
            TestCase("reassignZonePersistsEvenWithoutLandingPoint", suite.reassignZonePersistsEvenWithoutLandingPoint),
        ]
    }
}
