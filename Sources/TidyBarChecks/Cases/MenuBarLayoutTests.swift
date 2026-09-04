import Foundation
import Foundation
import CoreGraphics
import TidyBarCore

struct MenuBarLayoutTests {
    private let a = "com.test.dropbox"
    private let b = "com.test.wechat"
    private let c = "com.test.raycast"

    func appendAndZoneLookup() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append(b, to: .hidden)
        layout.append(c, to: .alwaysHidden)

        expect(layout.items(in: .visible) == [a])
        expect(layout.zone(of: b) == .hidden)
        expect(layout.position(of: c) == 0)
        expect(layout.occupiedCount == 2, "始终隐藏区不占物理菜单栏宽度")
    }

    func appendingExistingItemDoesNotDuplicate() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append(a, to: .visible)
        expect(layout.items(in: .visible).count == 1)
    }

    func moveAcrossZonesRemovesFromSource() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append(b, to: .visible)
        layout.move(itemID: a, to: .hidden)

        expect(layout.items(in: .visible) == [b])
        expect(layout.items(in: .hidden) == [a])
        expect(layout.zone(of: a) == .hidden)
    }

    func moveReturnsPreviousLocationForRollback() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append(b, to: .visible)

        let previous = layout.move(itemID: b, to: .hidden)
        expect(previous?.0 == .visible)
        expect(previous?.1 == 1)
    }

    func positionIsClampedNotCrashing() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.move(itemID: b, to: .visible, position: 99)
        expect(layout.items(in: .visible) == [a, b])

        layout.move(itemID: b, to: .visible, position: -5)
        expect(layout.items(in: .visible) == [b, a], "越界位置应收敛到边界")
    }

    func foldingAddsNewAndPrunesVanished() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append("com.test.uninstalled", to: .hidden)

        let folded = MenuBarLayout.folding(discovered: [a, b, c], into: layout, defaultZone: .hidden)

        expect(folded.items(in: .visible) == [a], "已存在图标不动")
        expect(Set(folded.items(in: .hidden)) == Set([b, c]))
        expect(folded.zone(of: "com.test.uninstalled") == nil, "已消失图标不应残留")
    }

    func removeUnknownItemIsNoOp() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.remove(itemID: "nope")
        expect(layout.items(in: .visible) == [a])
    }

    func codableRoundTrip() throws {
        var layout = MenuBarLayout()
        layout.append(a, to: .visible)
        layout.append(b, to: .hidden)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
        expect(decoded == layout)
    }

    func stableIDSurvivesCaseAndWidthChanges() throws {
        let lower = ManagedItem.stableID(ownerBundleID: "com.test.WeChat", title: "微信")
        let upper = ManagedItem.stableID(ownerBundleID: "com.test.wechat", title: "微信")
        expect(lower == upper)

        let trimmed = ManagedItem.stableID(ownerBundleID: nil, title: "  Dropbox ")
        let plain = ManagedItem.stableID(ownerBundleID: nil, title: "Dropbox")
        expect(trimmed == plain)
    }
}

struct MenuBarZoneTests {
    func physicalOrdering() throws {
        expect(MenuBarZone.visible < MenuBarZone.hidden)
        expect(MenuBarZone.hidden < MenuBarZone.alwaysHidden)
    }

    func onlyAlwaysHiddenLeavesTheBar() throws {
        expect(!MenuBarZone.alwaysHidden.occupiesMenuBar)
        expect(MenuBarZone.visible.occupiesMenuBar)
        expect(MenuBarZone.hidden.occupiesMenuBar)
    }
}

extension MenuBarLayoutTests {
    static var testCases: [TestCase] {
        let suite = MenuBarLayoutTests()
        return [
            TestCase("appendAndZoneLookup", suite.appendAndZoneLookup),
            TestCase("appendingExistingItemDoesNotDuplicate", suite.appendingExistingItemDoesNotDuplicate),
            TestCase("moveAcrossZonesRemovesFromSource", suite.moveAcrossZonesRemovesFromSource),
            TestCase("moveReturnsPreviousLocationForRollback", suite.moveReturnsPreviousLocationForRollback),
            TestCase("positionIsClampedNotCrashing", suite.positionIsClampedNotCrashing),
            TestCase("foldingAddsNewAndPrunesVanished", suite.foldingAddsNewAndPrunesVanished),
            TestCase("removeUnknownItemIsNoOp", suite.removeUnknownItemIsNoOp),
            TestCase("codableRoundTrip", suite.codableRoundTrip),
            TestCase("stableIDSurvivesCaseAndWidthChanges", suite.stableIDSurvivesCaseAndWidthChanges),
        ]
    }
}

extension MenuBarZoneTests {
    static var testCases: [TestCase] {
        let suite = MenuBarZoneTests()
        return [
            TestCase("physicalOrdering", suite.physicalOrdering),
            TestCase("onlyAlwaysHiddenLeavesTheBar", suite.onlyAlwaysHiddenLeavesTheBar),
        ]
    }
}
