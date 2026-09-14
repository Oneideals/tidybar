# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-09-14T14:41:00Z (read-only projection)
> **Git State:** `clean` | **Branch:** `main` | **Events Count:** 166

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] `native-fold-acceptance-20260909` — 最终63716565包自身两项权限已生效，完整原生验收完成：AdGuard抽屉右键、4.2秒保活、主动关闭后复位；主按钮展开与折叠时8常显/19隐藏分界正确；真实图标19/19及悬停收起通过。Debug与Release各312条41套件通过，配置保持。详见docs/findings/17-final-drawer-acceptance.md。
- [DONE] `native-test-permission-20260908` — 用户已为b82694测试包授权；同包重启PID25636启动日志确认辅助功能已授予、完整接管，读取35至38项。权限阻塞已消除，后续锁屏及原生交互验收另行记录。
- [DONE] (agy, 2026-09-14) 修复空白菜单栏点击呼出抽屉（解除推杆 target-action 二次触发与点击拦截），并实现抽屉内图标点击临时浮现至原生菜单栏（Bartender 式光标吸附与 7 秒原生右键交互）
- [DONE] (agy, 2026-09-14) 已完成启动体验优化：开机首帧瞬时折叠，首扫跳过物理拖拽重排，消除开机图标闪烁
- [DONE] (agy, 2026-09-14) 吸收 Ice 项目核心架构：通过解除 AppKit 水平约束根除 16pt 间隙、采用 10,000pt 推杆与严密空白点击判定，真机验证完美通过
- [DONE] (agy, 2026-09-14) 彻底修复点击收起失效：推杆物理位置绑定与空白点击拦截修复，折叠展开循环验证 100% 通过
- [DONE] (agy, 2026-09-14) 撤回 isVisible 策略改用纯 length 控制，折叠/展开双向切换恢复正常
- [DONE] (agy, 2026-09-14) 修复折叠点击无效：isVisible/length 赋值顺序修正，展开→折叠→展开双向切换正常

## 📋 Open Issues & Backlog ([TODO])

_No open issues._

## 🔄 Active Leases & In-Progress Work

- **agy** (`1d02cfa9-e97b-44fc-a30c-00a78297ecb4`): 修复空白菜单栏点击呼出抽屉，并实现点击抽屉图标临时浮现到菜单栏 *(files: sources/tidybarcore/app/tidybarapplication.swift, sources/tidybarcore/app/tidybarcontroller.swift)*

## 📝 Working Tree Changes

_Working tree is clean._

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

