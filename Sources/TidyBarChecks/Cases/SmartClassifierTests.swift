import Foundation
import CoreGraphics
import TidyBarCore

struct SmartClassifierTests {
    private func makeItem(_ id: String, owner: String, title: String, isSystemOwned: Bool = false) -> ManagedItem {
        ManagedItem(
            id: id,
            ownerBundleID: owner,
            title: title,
            frame: CGRect(x: 100, y: 1100, width: 24, height: 24),
            isSystemOwned: isSystemOwned
        )
    }

    func testInstantMessageAppsRecommendedVisible() {
        let wechat = makeItem("com.tencent.xinWeChat", owner: "com.tencent.xinWeChat", title: "微信")
        let rec = SmartItemClassifier.classify(item: wechat)
        expect(rec.recommendedZone == .visible)
        expect(rec.category == .instantMessage)
    }

    func testHotkeyLaunchersRecommendedHidden() {
        let raycast = makeItem("com.raycast.macos", owner: "com.raycast.macos", title: "Raycast")
        let paste = makeItem("com.wiheads.paste", owner: "com.wiheads.paste", title: "Paste")
        expect(SmartItemClassifier.classify(item: raycast).recommendedZone == .hidden)
        expect(SmartItemClassifier.classify(item: paste).recommendedZone == .hidden)
    }

    func testPureDriversRecommendedAlwaysHidden() {
        let ntfs = makeItem("com.paragon-software.ntfs.FSMenuApp", owner: "com.paragon-software.ntfs.FSMenuApp", title: "FSMenuApp")
        let orbstack = makeItem("dev.kdrag0n.MacVirt", owner: "dev.kdrag0n.MacVirt", title: "OrbStack")
        expect(SmartItemClassifier.classify(item: ntfs).recommendedZone == .alwaysHidden)
        expect(SmartItemClassifier.classify(item: orbstack).recommendedZone == .alwaysHidden)
    }

    func testSystemCoreClockVisible() {
        let clock = makeItem("clock", owner: "com.apple.controlcenter", title: "2026年9月5日星期六 21:50:00", isSystemOwned: true)
        let rec = SmartItemClassifier.classify(item: clock)
        expect(rec.recommendedZone == .visible)
        expect(rec.category == .systemEssential)
    }
}

extension SmartClassifierTests {
    static var testCases: [TestCase] {
        let suite = SmartClassifierTests()
        return [
            TestCase("即时通讯类建议显示") { suite.testInstantMessageAppsRecommendedVisible() },
            TestCase("快捷键启动类建议隐藏") { suite.testHotkeyLaunchersRecommendedHidden() },
            TestCase("纯底层驱动建议始终隐藏") { suite.testPureDriversRecommendedAlwaysHidden() },
            TestCase("系统时间常驻显示") { suite.testSystemCoreClockVisible() },
        ]
    }
}
