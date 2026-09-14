# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-09-14T14:10:45Z (read-only projection)
> **Git State:** `dirty` | **Branch:** `main` | **Events Count:** 163

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] `native-fold-acceptance-20260909` — 最终63716565包自身两项权限已生效，完整原生验收完成：AdGuard抽屉右键、4.2秒保活、主动关闭后复位；主按钮展开与折叠时8常显/19隐藏分界正确；真实图标19/19及悬停收起通过。Debug与Release各312条41套件通过，配置保持。详见docs/findings/17-final-drawer-acceptance.md。
- [DONE] `native-test-permission-20260908` — 用户已为b82694测试包授权；同包重启PID25636启动日志确认辅助功能已授予、完整接管，读取35至38项。权限阻塞已消除，后续锁屏及原生交互验收另行记录。
- [DONE] `review-1935331` — 原始16项审查问题及复核追加的恢复保护、同区保序、手动扫描时序、事件隔离和UI结果链问题已修复。Debug与最终Release回归均253/253、38套件通过；全目标编译、应用打包、签名及plist校验通过。详见docs/findings/10-review-fixes.md；真实菜单栏拖拽未做现场验证。
- [DONE] (agy, 2026-09-14) 吸收 Ice 项目核心架构：通过解除 AppKit 水平约束根除 16pt 间隙、采用 10,000pt 推杆与严密空白点击判定，真机验证完美通过
- [DONE] (agy, 2026-09-14) 彻底修复点击收起失效：推杆物理位置绑定与空白点击拦截修复，折叠展开循环验证 100% 通过
- [DONE] (agy, 2026-09-14) 撤回 isVisible 策略改用纯 length 控制，折叠/展开双向切换恢复正常
- [DONE] (agy, 2026-09-14) 修复折叠点击无效：isVisible/length 赋值顺序修正，展开→折叠→展开双向切换正常
- [DONE] (agy, 2026-09-14) 彻底消除展开状态下推杆占位残留的幽灵间隙，按钮左右间距完全恢复原生像素级对称

## 📋 Open Issues & Backlog ([TODO])

_No open issues._

## 🔄 Active Leases & In-Progress Work

- **agy** (`1d02cfa9-e97b-44fc-a30c-00a78297ecb4`): 优化启动体验：开机首帧瞬时折叠隐藏、已分区时跳过物理重排，消除开机图标逐个闪烁移动 *(files: sources/tidybarcore/app/tidybarapplication.swift)*

## 📝 Working Tree Changes

- `.M` `Sources/TidyBarCore/App/TidyBarApplication.swift`

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

