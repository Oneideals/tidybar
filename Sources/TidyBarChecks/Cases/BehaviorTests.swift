import Foundation
import Foundation
import CoreGraphics
import TidyBarCore

struct RevealStateMachineTests {
    func beginnerDefaultsAvoidHoverTriggers() throws {
        expect(
            RevealTrigger.beginnerDefaults == [.dividerClick, .hotkey],
            "默认不开悬停，避免光标路过就展开造成的「图标乱跳」观感"
        )
    }

    func hoverDoesNotRefreshRevealClock() throws {
        let machine = RevealStateMachine(rehideDelay: 2)
        let start = Date(timeIntervalSince1970: 1_000)

        expect(machine.reveal(by: .hover, at: start))
        expect(!machine.shouldAccept(trigger: .hover), "已展开时再悬停不应续期，否则永远收不起来")
        expect(machine.shouldAccept(trigger: .dividerClick))
    }

    func autoConcealHonoursDelay() throws {
        let machine = RevealStateMachine(rehideDelay: 2)
        let start = Date(timeIntervalSince1970: 10_000)
        machine.reveal(by: .dividerClick, at: start)

        expect(!machine.shouldAutoConceal(at: start.addingTimeInterval(1.9)))
        expect(machine.shouldAutoConceal(at: start.addingTimeInterval(2.0)))
        expect(abs((machine.remainingRevealTime(at: start.addingTimeInterval(0.5)) ?? 0) - 1.5) < 0.001)
    }

    func zeroDelayMeansNeverAutoConceal() throws {
        let machine = RevealStateMachine(rehideDelay: 0)
        machine.reveal(by: .hotkey, at: Date(timeIntervalSince1970: 0))
        expect(!machine.shouldAutoConceal(at: Date(timeIntervalSince1970: 10_000)))
    }

    func demoModeCollapsesEverythingAndIgnoresHover() throws {
        let machine = RevealStateMachine(rehideDelay: 2)
        machine.reveal(by: .dividerClick, at: Date())
        machine.setDemoMode(true)

        expect(!machine.isRevealed, "进入演示模式必须立刻收起")
        expect(!machine.shouldAccept(trigger: .hover), "投屏时不允许被悬停误呼出")
        expect(machine.shouldAccept(trigger: .hotkey), "但必须留一条退出手势")
    }
}

struct EventEngineThrottleTests {
    func highFrequencyEventsCollapseWithinWindow() throws {
        let engine = EventEngine(throttleInterval: 0.2)
        expect(engine.passesThrottle(.hover, now: 0))
        expect(!engine.passesThrottle(.hover, now: 0.1), "100ms 内的悬停事件应被吞掉，守住空闲 CPU ≈ 0%")
        expect(engine.passesThrottle(.hover, now: 0.25))
    }

    func clicksAreNeverThrottled() throws {
        let engine = EventEngine(throttleInterval: 0.2)
        expect(engine.passesThrottle(.dividerClick, now: 0))
        expect(engine.passesThrottle(.dividerClick, now: 0.01))
    }

    func menuHitClassification() throws {
        let top: CGFloat = 900
        expect(EventEngine.classifyMenuBarHit(eventLocationY: 895, screenTopY: top) == .insideMenuBar)
        expect(EventEngine.classifyMenuBarHit(eventLocationY: 500, screenTopY: top) == .outsideMenuBar)
        expect(
            EventEngine.classifyMenuBarHit(eventLocationY: 500, screenTopY: nil) == .outsideMenuBar,
            "读不到屏幕信息时按「点别处」处理，宁可不动作也不误动作"
        )
    }
}

struct PanelGeometryTests {
    private let screen = ScreenInfo(
        identifier: 1,
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        menuBarHeight: 24,
        notchWidth: nil,
        isBuiltin: false
    )

    private let notched = ScreenInfo(
        identifier: 2,
        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        menuBarHeight: 24,
        notchWidth: 200,
        isBuiltin: true
    )

    private let metrics = PanelGeometry.Metrics(itemSide: 26, itemSpacing: 6, contentInset: 8)

    func panelSitsJustBelowMenuBar() throws {
        // 取一个宽度足以突破 Minimums.panelWidth 的数量，才能验到真实内容宽度
        let frame = PanelGeometry.panelFrame(screen: screen, itemCount: 6, metrics: metrics, anchorX: 700)

        expect(abs(frame.maxY - (900 - 24 - PanelGeometry.Margin.gapBelowMenuBar)) < 0.001)
        expect(abs(frame.height - metrics.rowHeight) < 0.001)
        expect(abs(frame.width - (metrics.contentWidth(for: 6) + metrics.contentInset * 2)) < 0.001)
    }

    func panelIsClampedInsideScreen() throws {
        let farRight = PanelGeometry.panelFrame(screen: screen, itemCount: 2, anchorX: 1_440)
        expect(farRight.maxX <= screen.frame.maxX - PanelGeometry.Margin.screenEdge + 0.001)

        let farLeft = PanelGeometry.panelFrame(screen: screen, itemCount: 2, anchorX: -500)
        expect(farLeft.minX >= screen.frame.minX + PanelGeometry.Margin.screenEdge - 0.001)
    }

    func emptyPanelStillHasMinimumWidth() throws {
        let frame = PanelGeometry.panelFrame(screen: screen, itemCount: 0, anchorX: 700)
        expect(abs(frame.width - PanelGeometry.Minimums.panelWidth) < 0.001)
    }

    func panelOverlappingNotchIsPushedToTheSide() throws {
        expect(notched.hasNotch)
        let notchLeft = notched.frame.midX - 100
        let notchRight = notched.frame.midX + 100

        // 纵向压到刘海区域的高面板（例如多行分组面板）
        let overlapping = CGRect(x: notched.frame.midX - 150, y: notched.frame.maxY - 30, width: 300, height: 20)
        let adjusted = PanelGeometry.adjustedForNotch(overlapping, screen: notched)

        expect(!(adjusted.minX < notchRight && adjusted.maxX > notchLeft), "面板不得横跨刘海")
        expect(adjusted.minX >= notchRight, "应整体让位到刘海一侧")
    }

    func standardPanelBelowMenuBarIsNotAffectedByNotch() throws {
        let frame = PanelGeometry.panelFrame(screen: notched, itemCount: 6, anchorX: notched.frame.midX)
        expect(
            PanelGeometry.adjustedForNotch(frame, screen: notched) == frame,
            "贴菜单栏下沿的常规面板本就位于刘海之下，不应被无谓平移"
        )
    }

    func itemOriginsAdvanceHorizontally() throws {
        let panel = CGRect(x: 100, y: 800, width: 300, height: 42)
        let first = PanelGeometry.itemOrigin(in: panel, index: 0, metrics: metrics)
        let second = PanelGeometry.itemOrigin(in: panel, index: 1, metrics: metrics)

        expect(abs((second.x - first.x) - 32) < 0.001)
        expect(abs(first.x - (panel.minX + metrics.contentInset)) < 0.001)
    }

    func notchReducesSafeMenuBarRightEdge() throws {
        let narrowNotched = ScreenInfo(
            identifier: 3,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            menuBarHeight: 24,
            notchWidth: 200,
            isBuiltin: true
        )
        expect(abs(narrowNotched.safeMenuBarRightEdge - 400) < 0.001)
        expect(abs(screen.safeMenuBarRightEdge - 1_440) < 0.001)
    }
}

extension RevealStateMachineTests {
    static var testCases: [TestCase] {
        let suite = RevealStateMachineTests()
        return [
            TestCase("beginnerDefaultsAvoidHoverTriggers", suite.beginnerDefaultsAvoidHoverTriggers),
            TestCase("hoverDoesNotRefreshRevealClock", suite.hoverDoesNotRefreshRevealClock),
            TestCase("autoConcealHonoursDelay", suite.autoConcealHonoursDelay),
            TestCase("zeroDelayMeansNeverAutoConceal", suite.zeroDelayMeansNeverAutoConceal),
            TestCase("demoModeCollapsesEverythingAndIgnoresHover", suite.demoModeCollapsesEverythingAndIgnoresHover),
        ]
    }
}

extension EventEngineThrottleTests {
    static var testCases: [TestCase] {
        let suite = EventEngineThrottleTests()
        return [
            TestCase("highFrequencyEventsCollapseWithinWindow", suite.highFrequencyEventsCollapseWithinWindow),
            TestCase("clicksAreNeverThrottled", suite.clicksAreNeverThrottled),
            TestCase("menuHitClassification", suite.menuHitClassification),
        ]
    }
}

extension PanelGeometryTests {
    static var testCases: [TestCase] {
        let suite = PanelGeometryTests()
        return [
            TestCase("panelSitsJustBelowMenuBar", suite.panelSitsJustBelowMenuBar),
            TestCase("panelIsClampedInsideScreen", suite.panelIsClampedInsideScreen),
            TestCase("emptyPanelStillHasMinimumWidth", suite.emptyPanelStillHasMinimumWidth),
            TestCase("panelOverlappingNotchIsPushedToTheSide", suite.panelOverlappingNotchIsPushedToTheSide),
            TestCase("standardPanelBelowMenuBarIsNotAffectedByNotch", suite.standardPanelBelowMenuBarIsNotAffectedByNotch),
            TestCase("itemOriginsAdvanceHorizontally", suite.itemOriginsAdvanceHorizontally),
            TestCase("notchReducesSafeMenuBarRightEdge", suite.notchReducesSafeMenuBarRightEdge),
        ]
    }
}
