# TidyBar

> 装完即忘的 macOS 菜单栏管家：默认干净，需要时聪明。

原生 Swift 开发的菜单栏图标整理工具，对标 Bartender / Ice，主打**低占用**与**在 macOS Tahoe 上的可靠性**。产品决策与完整功能清单见 [docs/软件开发计划.md](docs/软件开发计划.md)。

## 当前状态

**M0 骨架阶段**（不面向使用）。分层与逻辑已落地并有 88 条回归用例；**与系统交互的两个高危环节仍是占位实现**，因此现在不会真的移动你的菜单栏图标。

| 能力 | 状态 |
| --- | --- |
| 三分区布局模型、显隐状态机、规则求值、收纳面板几何、崩溃恢复日志、事件哨兵判定、图标搜索、位图 LRU 缓存 | 已实现，有测试 |
| 光标/权限/屏幕（含刘海）真实读取 | 已实现（AppKit + AXIsProcessTrusted） |
| 菜单栏图标枚举（辅助功能 API） | 占位，待 M0 真机验证 |
| ⌘ 拖拽移动图标（合成事件） | 关闭，待 M0 真机验证 |

机制未验证前，工具自动运行在**收纳面板（降级）模式**：只在自有面板里管理图标，不改动系统菜单栏。这是刻意设计——Bartender 5/6 在 Tahoe 上的幽灵点击与光标劫持正是这条路径失控的结果。

## 快速开始

需要 macOS 14+，Command Line Tools 或 Xcode 均可。

```bash
swift build                       # 编译全部目标
swift run tidybar-checks          # 跑 88 条回归用例
swift run tidybar-checks --verbose
swift run tidybar-checks --filter 规则   # 按套件/用例名过滤

./scripts/build-app.sh            # 组装可双击运行的 TidyBar.app（ad-hoc 签名）
./scripts/perf-check.sh           # 对照性能预算测一次常驻内存
```

`swift run tidybar` 会以菜单栏 ☰ 图标的形式启动（无 Dock 图标）。

## 结构

```
Sources/
  TidyBarCore/          # 全部逻辑，公开接口即测试面
    Model/              # 三分区、图标、布局真相源
    Accessibility/      # 系统能力协议边界 + 真实/占位实现
    Layout/             # 变更生命周期：意图落盘 → 预检 → 执行 → 复核 → 提交
    Safety/             # 事件哨兵、崩溃恢复日志
    Events/             # 呼出状态机、事件节流
    Rules/              # 条件显示（规则卡片）
    Panel/              # 收纳面板与几何（含刘海避让）
    Search/ Performance/ Persistence/ App/
  TidyBar/              # NSApplication 薄入口
  TidyBarChecks/        # 零依赖回归 runner
docs/                   # 软件开发计划、M0 验证清单
scripts/                # 打包与性能核对
```

依赖：仅 Foundation / AppKit。无第三方包，Carbon HotKey 与屏幕采样默认不启用。

## 性能预算

写进代码并有用例守护（`PerformanceBudgetTests`），不达标即视为回归。内存口径固定为 **phys_footprint**（`footprint` 工具），不用 `ps` 的 RSS——后者把 AppKit 共享页算进来，菜单栏工具会虚高 2~3 倍。

| 指标 | 上限 | 骨架实测 |
| --- | --- | --- |
| 常驻内存（20 图标静置 1 小时） | 40 MB | 11.2 MB（启动 5s，5 线程） |
| 空闲 CPU | ≈ 0%（事件驱动，节流窗口 200ms） | 0.0% |
| 呼出/隐藏响应 | 100 ms | 待 M0 |
| 冷启动到接管 | 2 s | 待 M0 |
| 安装包 | 10 MB | 688 KB |
| 图标位图缓存 | 20 MB | 有用例守护 |

复测：`./scripts/perf-check.sh --minutes 5`

## 隐私

不收集、不上报任何数据。设置与布局日志写入 `~/Library/Application Support/TidyBar/`，卸载即清除。

## 下一步

按 [M0 技术验证清单](docs/M0-技术验证清单.md) 在本机验证图标枚举与 ⌘ 拖拽的可行性与失败模式，决定是否进入 MVP。
