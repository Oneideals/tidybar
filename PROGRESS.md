# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-10-09T13:54:06Z (read-only projection)
> **Git State:** `dirty` | **Branch:** `main` | **Events Count:** 263

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] `drawer-auto-conceal-on-item-click-20261009` — 点击抽屉内的图标使图标显示到菜单栏后，抽屉面板立即关闭。在 `handleDrawerItemClick` 中增加 `controller.conceal()`，确保视觉层与状态机层同步置为隐藏，杜绝光标悬停或定时器再次触发重开抽屉；并在 `toggleDrawer` 与 `toggleMenuBarFold` 触发时自动排空旧浮现状态；新增单元测试覆盖全生命周期；全部 330 项测试通过，安装运行验证无误。
- [DONE] `native-partition-alignment-20261009` — 实现原生折叠模式（NativeMenuBarHider）下的菜单栏物理分区规整架构。支持无推杆分隔符环境下的物理边界与逆序检测（isCorrectlyPartitioned / partitionDisorder），使所有隐藏区图标在 macOS WindowServer 底层物理排布上统一归拢至最左侧常显图标（BetterDisplay，x=1288）左侧。点击收纳抽屉图标浮现时，凭借系统连续流式紧凑排布（contiguous flow packing），浮现图标统一在常显区域最左侧边缘（紧邻 BetterDisplay）弹出，杜绝随机穿插与坐标位移；内存常驻 34MB（在 ≤40MB 预算内），329 项单元与回归测试全部通过。
- [DONE] `native-test-permission-20260908` — 用户已为b82694测试包授权；同包重启PID25636启动日志确认辅助功能已授予、完整接管，读取35至38项。权限阻塞已消除，后续锁屏及原生交互验收另行记录。
- [DONE] `review-1935331` — 原始16项审查问题及复核追加的恢复保护、同区保序、手动扫描时序、事件隔离和UI结果链问题已修复。Debug与最终Release回归均253/253、38套件通过；全目标编译、应用打包、签名及plist校验通过。详见docs/findings/10-review-fixes.md；真实菜单栏拖拽未做现场验证。
- [DONE] (agy, 2026-09-18) feat(panel): 引入独立窗口隔离捕获与代理状态项架构，彻底解决抽屉图标阴影、残留及展开卡顿 [DONE]
- [DONE] (agy, 2026-09-18) 完成独立窗口隔离捕获（WindowListIconCapturer），彻底消除抽屉图标阴影、邻居残留与边缘切割，支持屏外无感直截与 1:1 原生厚度对齐
- [DONE] (agy, 2026-09-17) 优化代理图标高保真质感、无窗口App操作兜底、收起零残留与抽屉交互体验
- [DONE] (agy, 2026-09-17) 优化代理图标呈现与鼠标吸附保护并重新打包运行最新构建
- [DONE] (agy, 2026-09-17) 修复折叠状态下物理重排误将隐藏项全部归入始终隐藏区Bug并在总览提供一键恢复

## 📋 Open Issues & Backlog ([TODO])

_No open issues._

## 🔄 Active Leases & In-Progress Work

_No active leases._

## 📝 Working Tree Changes

- `.M` `Sources/TidyBarChecks/Cases/ActivationTests.swift`
- `.M` `Sources/TidyBarCore/App/TidyBarApplication.swift`

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

