# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-09-10T14:38:53Z (read-only projection)
> **Git State:** `dirty` | **Branch:** `main` | **Events Count:** 122

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] `native-fold-acceptance-20260909` — 最终63716565包自身两项权限已生效，完整原生验收完成：AdGuard抽屉右键、4.2秒保活、主动关闭后复位；主按钮展开与折叠时8常显/19隐藏分界正确；真实图标19/19及悬停收起通过。Debug与Release各312条41套件通过，配置保持。详见docs/findings/17-final-drawer-acceptance.md。
- [DONE] `native-test-permission-20260908` — 用户已为b82694测试包授权；同包重启PID25636启动日志确认辅助功能已授予、完整接管，读取35至38项。权限阻塞已消除，后续锁屏及原生交互验收另行记录。
- [DONE] `review-1935331` — 原始16项审查问题及复核追加的恢复保护、同区保序、手动扫描时序、事件隔离和UI结果链问题已修复。Debug与最终Release回归均253/253、38套件通过；全目标编译、应用打包、签名及plist校验通过。详见docs/findings/10-review-fixes.md；真实菜单栏拖拽未做现场验证。
- [DONE] (codex, 2026-09-10) 完成原生面板存活修复及最终63716565包真机验收：右键保活关闭、主按钮左右分区、19/19图标与悬停收起均通过；Debug/Release各312条，设置保持，App运行，报告17已保存。
- [DONE] (codex, 2026-09-10) 授权真机复测与补充修复完成；Debug/Release各311条、短菜单下18/18原样图标通过；新包65e5已启动，临时自动收起恢复2秒，待新签名两项授权继续最终包验收
- [DONE] (codex, 2026-09-10) 三项修复与终审修正已落地；Debug/Release各309条通过，最终包已签名启动，分组保留；第三方抽屉实测等待当前包两项TCC授权
- [DONE] (codex, 2026-09-09) 当前b82694包已授权；两项实际折叠、展开回屏内及2.13秒自动收起已取证。Otty菜单仍遮挡部分展开区，新图标整理及始终隐藏未验收；Mac自动锁屏待用户解锁。未改分组，App25636保持运行，临时工具已清理，未提交未推送。
- [DONE] (codex, 2026-09-09) 完成同屏边界补修及双轴复核；Debug/Release各279条40套件通过，最终b82694包PID16703已启动，保留最新35项配置并清理临时桌面工具；真实隐藏仍待当前包辅助功能授权，未提交未推送

## 📋 Open Issues & Backlog ([TODO])

_No open issues._

## 🔄 Active Leases & In-Progress Work

- **agy** (`44ceb2e3-2fd7-4a0e-b14d-c7796f1f9c52`): 借鉴Ice设计逻辑优化TidyBar：多维手势触发体系与Spotlight搜索HUD升级 *(files: sources/tidybarcore/panel/tidybarsearchpanel.swift)*

## 📝 Working Tree Changes

- `.M` `Sources/TidyBar/main.swift`
- `.M` `Sources/TidyBarChecks/Cases/ActivationTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/DragEventTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/DropTargetTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/EngineTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/IconBitmapTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/IdentityLedgerTests.swift`
- `.M` `Sources/TidyBarChecks/Cases/TestFakes.swift`
- `.M` `Sources/TidyBarChecks/main.swift`
- `.M` `Sources/TidyBarCore/Accessibility/AccessibilityMenuBarMover.swift`
- `.M` `Sources/TidyBarCore/Accessibility/AccessibilityMenuBarReader.swift`
- `.M` `Sources/TidyBarCore/Accessibility/AppKitServices.swift`
- `.M` `Sources/TidyBarCore/Accessibility/DragEventPoster.swift`
- `.M` `Sources/TidyBarCore/Accessibility/MenuBarDropTarget.swift`
- `.M` `Sources/TidyBarCore/Accessibility/MenuBarIconCapture.swift`
- `.M` `Sources/TidyBarCore/Accessibility/MenuBarItemPolicy.swift`
- `.M` `Sources/TidyBarCore/Accessibility/Protocols.swift`
- `.M` `Sources/TidyBarCore/App/BackgroundEnumerator.swift`
- `.M` `Sources/TidyBarCore/App/IconOverviewView.swift`
- `.M` `Sources/TidyBarCore/App/RuleEditorWindow.swift`
- `.M` `Sources/TidyBarCore/App/SettingsWindow.swift`
- `.M` `Sources/TidyBarCore/App/TidyBarApplication.swift`
- `.M` `Sources/TidyBarCore/App/TidyBarController.swift`
- `.M` `Sources/TidyBarCore/App/TidyBarMenu.swift`
- `.M` `Sources/TidyBarCore/Events/EventEngine.swift`
- `.M` `Sources/TidyBarCore/Events/GlobalHotKey.swift`
- `.M` `Sources/TidyBarCore/Events/RevealPolicy.swift`
- `.M` `Sources/TidyBarCore/Layout/DividerGeometry.swift`
- `.M` `Sources/TidyBarCore/Layout/LayoutEngine.swift`
- `.M` `Sources/TidyBarCore/Model/ManagedItem.swift`
- `.M` `Sources/TidyBarCore/Model/MenuBarLayout.swift`
- `.M` `Sources/TidyBarCore/Panel/IconBitmapStore.swift`
- `.M` `Sources/TidyBarCore/Panel/PanelGeometry.swift`
- `.M` `Sources/TidyBarCore/Panel/TidyBarPanel.swift`
- `.M` `Sources/TidyBarCore/Persistence/IdentityLedger.swift`
- `.M` `Sources/TidyBarCore/Rules/RuleEngine.swift`
- `.M` `Sources/TidyBarCore/Rules/Rules.swift`
- `.M` `Sources/TidyBarCore/Rules/SystemContextProvider.swift`
- `.M` `Sources/TidyBarCore/Safety/LayoutJournal.swift`
- `.M` `Sources/TidyBarDragProbe/main.swift`
- `.M` `Sources/TidyBarSelfDrag/main.swift`
- `??` `Sources/TidyBarChecks/Cases/ArrangementTests.swift`
- `??` `Sources/TidyBarChecks/Cases/ClickRelayTests.swift`
- `??` `Sources/TidyBarChecks/Cases/HitTestingTests.swift`
- `??` `Sources/TidyBarChecks/Cases/ReviewRegressionTests.swift`
- `??` `Sources/TidyBarCore/Accessibility/MenuBarClickRelay.swift`
- `??` `Sources/TidyBarCore/App/MenuBarAccessSession.swift`
- `??` `Sources/TidyBarCore/Layout/MenuBarArrangement.swift`
- `??` `docs/findings/10-review-fixes.md`
- `??` `docs/findings/11-desktop-test.md`
- `??` `docs/findings/12-physical-fold.md`
- `??` `docs/findings/13-hit-testing-and-fold.md`
- `??` `docs/findings/14-authorized-native-fold.md`
- `??` `docs/findings/15-drawer-native-interaction.md`
- `??` `docs/findings/16-authorized-drawer-validation.md`
- `??` `docs/findings/17-final-drawer-acceptance.md`

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

