import Foundation
import CoreGraphics
import TidyBarCore

/// 落点推导的回归用例。
/// 真机扫描证明「拖进空隙」会被系统静默忽略（不报错也不动），
/// 所以这里锁死"目标必须由邻居推导"，防止有人日后退回"往左 N 像素"的写法。
struct DropTargetTests {
    private func icon(_ id: String, _ x: CGFloat) -> ManagedItem {
        ManagedItem(
            id: id,
            ownerBundleID: "local.tidybar.fixture",
            title: id,
            frame: CGRect(x: x, y: 1_053, width: 24, height: 24)
        )
    }

    private var row: [ManagedItem] { [icon("FX4", 393), icon("FX3", 438), icon("FX2", 482), icon("FX1", 526)] }

    func forwardInsertLandsOnNeighboursRightEdge() throws {
        guard let target = MenuBarDropTarget.targetX(in: row, moving: 0, to: 2) else {
            return try record("应有合法落点")
        }
        // 往后插要越过目标图标的右缘，系统才认定"超过它"
        expectEqual(target, 482 + 24 + 2)
    }

    func backwardInsertLandsOnNeighboursCentre() throws {
        guard let target = MenuBarDropTarget.targetX(in: row, moving: 2, to: 0) else {
            return try record("应有合法落点")
        }
        expectEqual(target, 405, "往前插落在目标图标中心")
    }

    func sameIndexHasNoTarget() throws {
        expectNil(MenuBarDropTarget.targetX(in: row, moving: 1, to: 1), "原地不动不该浪费一次拖拽")
    }

    func outOfRangeHasNoTarget() throws {
        expectNil(MenuBarDropTarget.targetX(in: row, moving: 0, to: 9))
        expectNil(MenuBarDropTarget.targetX(in: [], moving: 0, to: 1))
    }

    func hidingIntoEmptyZoneHasNoTarget() throws {
        let item = icon("FX1", 526)
        expectNil(
            MenuBarDropTarget.targetX(forHiding: item, neighborsInTargetZone: []),
            "目标区没有图标可踩时不得硬拖（真机表现是被静默忽略）"
        )
    }

    func hidingLandsRightOfLastNeighbour() throws {
        let item = icon("FX1", 526)
        let zone = [icon("H1", 100), icon("H2", 130)]
        guard let target = MenuBarDropTarget.targetX(forHiding: item, neighborsInTargetZone: zone) else {
            return try record("应有落点")
        }
        expectEqual(target, 130 + 24 + 2)
    }

    func reorderDetectionIsAboutOrderNotPosition() throws {
        // 图标被拖出去又弹回原位：坐标可能抖动，但顺序没变 → 必须判为"没成功"
        let before = ["FX4", "FX3", "FX2"]
        expect(!MenuBarDropTarget.didReorder(before: before, after: before))
        expect(MenuBarDropTarget.didReorder(before: before, after: ["FX3", "FX2", "FX4"]))
    }
}

extension DropTargetTests {
    static var testCases: [TestCase] {
        let suite = DropTargetTests()
        return [
            TestCase("forwardInsertLandsOnNeighboursRightEdge", suite.forwardInsertLandsOnNeighboursRightEdge),
            TestCase("backwardInsertLandsOnNeighboursCentre", suite.backwardInsertLandsOnNeighboursCentre),
            TestCase("sameIndexHasNoTarget", suite.sameIndexHasNoTarget),
            TestCase("outOfRangeHasNoTarget", suite.outOfRangeHasNoTarget),
            TestCase("hidingIntoEmptyZoneHasNoTarget", suite.hidingIntoEmptyZoneHasNoTarget),
            TestCase("hidingLandsRightOfLastNeighbour", suite.hidingLandsRightOfLastNeighbour),
            TestCase("reorderDetectionIsAboutOrderNotPosition", suite.reorderDetectionIsAboutOrderNotPosition),
        ]
    }
}
