import Foundation

// TidyBarChecks —— 零依赖回归 runner。
//   swift run TidyBarChecks            跑全部
//   swift run TidyBarChecks --verbose   列出每条用例
//   swift run TidyBarChecks --filter 规则  只跑套件名/用例名包含关键字的
// 退出码非 0 表示有失败，可直接接进 CI。

let arguments = CommandLine.arguments
let verbose = arguments.contains("--verbose")
let filter: String? = {
    guard let index = arguments.firstIndex(of: "--filter"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}()

let suites: [TestSuite] = [
    // M0 真机验证结论固化
    TestSuite("MenuBarItemPolicy", MenuBarItemPolicyTests.testCases),
    TestSuite("ScreenCoordinateSpace", ScreenCoordinateSpaceTests.testCases),
    TestSuite("ItemIdentity", ItemIdentityTests.testCases),
    TestSuite("EnumerationCadence", EnumerationCadenceTests.testCases),
    // 模型层
    TestSuite("MenuBarLayout", MenuBarLayoutTests.testCases),
    TestSuite("MenuBarZone", MenuBarZoneTests.testCases),
    // 安全层（本工具的立身之本）
    TestSuite("EventSentinel", EventSentinelTests.testCases),
    TestSuite("LayoutJournal", LayoutJournalTests.testCases),
    TestSuite("LayoutEngine", LayoutEngineTests.testCases),
    TestSuite("DragEventDiscipline", DragEventDisciplineTests.testCases),
    TestSuite("MenuBarDropTarget", DropTargetTests.testCases),
    TestSuite("EngineGuardDivision", EngineGuardDivisionTests.testCases),
    TestSuite("GracefulShutdown", GracefulShutdownTests.testCases),
    TestSuite("InFlightDragRelease", InFlightDragTests.testCases),
    TestSuite("PendingIntentReplay", PendingIntentReplayTests.testCases),
    TestSuite("MenuBarActivation", ActivationTests.testCases),
    TestSuite("IconBitmap", IconBitmapTests.testCases),
    TestSuite("DragGate", DragGateTests.testCases),
    TestSuite("PositionSignature", PositionSignatureTests.testCases),
    TestSuite("TitleDriftAdoption", TitleDriftAdoptionTests.testCases),
    TestSuite("ResidualPairing", ResidualPairingTests.testCases),
    TestSuite("IdentityLedger", IdentityLedgerTests.testCases + LedgerAcrossLaunchTests.testCases + LedgerMigrationTests.testCases),
    TestSuite("SettingsEvolution", SettingsEvolutionTests.testCases),
    TestSuite("DividerGeometry", DividerGeometryTests.testCases),
    TestSuite("IconOverview", IconOverviewBuilderTests.testCases),
    // 行为层
    TestSuite("RevealStateMachine", RevealStateMachineTests.testCases + RevealStateMachineTests.idleTimerContractCases),
    TestSuite("EventEngine", EventEngineThrottleTests.testCases),
    TestSuite("TidyBarController", TidyBarControllerTests.testCases),
    // 规则层
    TestSuite("RuleCondition", RuleConditionTests.testCases),
    TestSuite("RuleEngine", RuleEngineTests.testCases),
    TestSuite("LiveSystemContext", LiveSystemContextProviderTests.testCases),
    // 支撑层
    TestSuite("PanelGeometry", PanelGeometryTests.testCases),
    TestSuite("ItemSearch", ItemSearchTests.testCases),
    TestSuite("ImageCache", ImageCacheTests.testCases),
    TestSuite("PerformanceBudget", PerformanceBudgetTests.testCases),
    TestSuite("AppSettings", AppSettingsTests.testCases),
]

let selected = filter.map { keyword in
    suites.compactMap { suite -> TestSuite? in
        let cases = suite.cases.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        if suite.name.localizedCaseInsensitiveContains(keyword) { return suite }
        return cases.isEmpty ? nil : TestSuite(suite.name, cases)
    }
} ?? suites

if selected.isEmpty {
    print("没有匹配「\(filter ?? "")」的用例")
    exit(2)
}

let summary = Runner.run(selected, verbose: verbose)
exit(summary.didAllPass ? 0 : 1)
