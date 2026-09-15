# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-09-15T08:58:29Z (read-only projection)
> **Git State:** `clean` | **Branch:** `main` | **Events Count:** 185

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] `native-fold-acceptance-20260909` — 最终63716565包自身两项权限已生效，完整原生验收完成：AdGuard抽屉右键、4.2秒保活、主动关闭后复位；主按钮展开与折叠时8常显/19隐藏分界正确；真实图标19/19及悬停收起通过。Debug与Release各312条41套件通过，配置保持。详见docs/findings/17-final-drawer-acceptance.md。
- [DONE] `native-test-permission-20260908` — 用户已为b82694测试包授权；同包重启PID25636启动日志确认辅助功能已授予、完整接管，读取35至38项。权限阻塞已消除，后续锁屏及原生交互验收另行记录。
- [DONE] `review-1935331` — 原始16项审查问题及复核追加的恢复保护、同区保序、手动扫描时序、事件隔离和UI结果链问题已修复。Debug与最终Release回归均253/253、38套件通过；全目标编译、应用打包、签名及plist校验通过。详见docs/findings/10-review-fixes.md；真实菜单栏拖拽未做现场验证。
- [DONE] (agy, 2026-09-15) 图标统一呈现组件与抽屉单项物理浮现实施完成。新增PeekCoordinator状态机、CaptureSweep幕布截图、CurtainWindow遮罩、MenuBarIconPresentation统一绘制。EventEngine右键路由双发。318/318测试全绿
- [DONE] (claude, 2026-09-15) 完成设计文档并提交，待用户评审后出实施计划
- [DONE] (agy, 2026-09-14) 已解决抽屉呼出卡顿不流畅问题，并完美实现抽屉内图标点击仅单独在菜单栏浮现目标图标以支持原生右键展开
- [DONE] (agy, 2026-09-14) 已解决空白菜单栏点击呼出抽屉，以及抽屉内图标点击后临时浮现至原生菜单栏并吸附光标支持原生右键交互
- [DONE] (agy, 2026-09-14) 已完成启动体验优化：开机首帧瞬时折叠，首扫跳过物理拖拽重排，消除开机图标闪烁

## 📋 Open Issues & Backlog ([TODO])

_No open issues._

## 🔄 Active Leases & In-Progress Work

- **agy** (`b30ba57a-24f8-428e-ba01-52c5b75c95de`): 完善PeekCoordinator匹配鲁棒性与日志，重新打包dist/TidyBar.app *(files: sources/tidybarcore/app/peekcoordinator.swift, sources/tidybarcore/app/tidybarapplication.swift)*

## 📝 Working Tree Changes

_Working tree is clean._

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

