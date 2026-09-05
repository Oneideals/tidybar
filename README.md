# TidyBar

> 装完即忘的 macOS 菜单栏管家：默认干净，需要时聪明。

原生 Swift 开发的菜单栏图标整理工具，对标 Bartender / Ice，主打**低占用**与**在 macOS Tahoe 上的可靠性**。产品决策与完整功能清单见 [docs/软件开发计划.md](docs/软件开发计划.md)。

当前进度：**M0 技术验证 4/4 通过 + 真实菜单栏闸门全绿，已进入 M1**（P0 功能面）。
已完成 M1-1 [点击转发](docs/findings/06-click-forwarding.md)、M1-2 [面板真实缩略图](docs/findings/07-icon-bitmaps.md)、
[跨启动身份台账](docs/design/跨启动身份台账.md)，以及设置窗口 / 首启向导 / 全局热键（Carbon）/ 开机自启 / 新图标问答 / 内存压力清理。

## 当前状态

**M0 技术验证完成**（4/4 通过），分层与逻辑已落地并有 171 条回归用例。枚举与 ⌘ 拖拽两个高危环节都已在真机打通；但 100 次全绿是在**自造 fixture 图标**上取得的，所以产品侧接管闸门（`isConfirmedSupportedOS`）仍未开放——现在它读得到你的图标，但不会移动任何一个。

| 能力 | 状态 |
| --- | --- |
| 三分区布局模型、显隐状态机、规则求值、收纳面板几何、崩溃恢复日志、事件哨兵判定、图标搜索、位图 LRU 缓存 | 已实现，有测试 |
| 光标/权限/屏幕（含刘海）真实读取 | 已实现（AppKit + AXIsProcessTrusted） |
| 菜单栏图标枚举（辅助功能 API） | **已实现并真机验证**：macOS 26.6.2 实测读到 28 个第三方 + 5 个系统图标 |
| ⌘ 拖拽移动图标（合成事件） | **已真机验证并在本机开放**：在用户点名的 QuitAll 图标上 100 轮 / 200 次往返全绿、位置逐项复原；接管开关改为**按机器 + 系统版本的确认名单**（本机 26.6.2 已命中 ⇒ 模式=完整接管），其他机器/版本仍是只读不搬 |
| 强杀/崩溃恢复 | **已真机验证**：kill -9 于拖拽中途，全新进程读到鼠标与 ⌘ 均无残留、图标不损坏、孤儿意图可重放 |
| 优雅退出收尾 | **已真机验证**：SIGTERM/SIGHUP/SIGINT 挂 DispatchSource 信号源；半空拖拽被确定性抬起；孤儿意图重放失败两次即放弃并回落上次已提交布局 |
| 常驻占用 | **已真机验证**：phys_footprint 13 MB（36 图标在栏，静置无增长）、空闲 CPU 0.0%、包 932 KB、4 线程 |
| 点击转发（面板/搜索里点一下 = 点真实图标） | **M1 第一步，已真机验证**：走 `AXPress` 而非合成鼠标事件；本机 66 个 AX 子项 98% 接受代点，点不动的会给出人话提示 |

接管闸门开放前，工具自动运行在**收纳面板（降级）模式**：只在自有面板里管理图标，不改动系统菜单栏。这是刻意设计——Bartender 5/6 在 Tahoe 上的幽灵点击与光标劫持正是这条路径失控的结果。

## 快速开始

需要 macOS 14+，Command Line Tools 或 Xcode 均可。

```bash
swift build                       # 编译全部目标
swift run tidybar-checks          # 跑 171 条回归用例
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
  TidyBarProbe/         # 真机枚举探针（耗时、身份分布、--expect-bundle 已知答案断言）
  TidyBarAttrDump/      # 图标 AX 属性穷举，用来确认「读不到什么」
  TidyBarFixture/       # 自造图标 App：破坏性实验只作用于它
  TidyBarDragProbe/     # 拖拽闸门（--repeat N / --destructive / --via-engine）
  TidyBarDragTune/      # 落点三态验证（邻居槽位 / 空隙 / 同位）
  TidyBarCrashProbe/    # 强杀恢复：drag / inspect / recover
docs/                   # 软件开发计划、M0 验证清单、findings/ 真机结论
scripts/                # 打包、性能核对、fixture 构建、M0 强杀演练
```

依赖：仅 Foundation / AppKit。无第三方包，Carbon HotKey 与屏幕采样默认不启用。

## 性能预算

写进代码并有用例守护（`PerformanceBudgetTests`），不达标即视为回归。内存口径固定为 **phys_footprint**（`footprint` 工具），不用 `ps` 的 RSS——后者把 AppKit 共享页算进来，菜单栏工具会虚高 2~3 倍。

| 指标 | 上限 | 真机实测（macOS 26.6.2，36 图标在栏） |
| --- | --- | --- |
| 常驻内存（20 图标静置 1 小时） | 40 MB | **13 MB**（2 min 内无增长；1 小时未测） |
| 空闲 CPU | ≈ 0%（事件驱动，节流窗口 200ms） | **0.0%** |
| 呼出/隐藏响应 | 100 ms | 待 M1（收纳面板尚未接通 UI） |
| 冷启动到接管 | 2 s | **0.52 / 0.61 / 0.70 / 1.01 s**（逐进程并发 12 + 单进程 500ms 超时；改前串行是 2.8~13.3 s） |
| 安装包 | 10 MB | **932 KB** |
| 图标位图缓存 | 20 MB | 有用例守护，真实截图路径未接入 |

复测：`./scripts/perf-check.sh --minutes 5`

## 隐私

不收集、不上报任何数据。设置与布局日志写入 `~/Library/Application Support/TidyBar/`，卸载即清除。

## 真机验证结论（M0）

- 验证项 1（枚举）：**通过**，并推翻了「用 title 做稳定 id」的假设——88% 的图标读不到任何名字，
  只能靠 (归属进程 + 序号)；细化身份强度后真正不稳的只剩 6%。冷启动扫描 2.6s，因此首扫必须异步。
  详见 [docs/findings/01-enumeration.md](docs/findings/01-enumeration.md)。
- 验证项 2（⌘ 拖拽）：**通过**。但真机数据推翻三条假设：决定成败的是**落点必须踩邻居槽位**（拖进空隙会被
  macOS 静默忽略）、鼠标事件自带的 `maskCommand` 才是 ⌘ 拖拽的判定依据（真实按键不能替代）、
  而这个 flags 会**改写全局修饰键状态**——抬起事件必须不带 flags，否则用户的普通点击会变成 ⌘ 点击。
  详见 [docs/findings/02-drag.md](docs/findings/02-drag.md)。
- 验证项 3（强杀恢复）：**通过**，并抓到主路径 bug（引擎残留已被证伪的光标预检 → 真实产品路径此前一直静默中止）。教训：旁路直连底层跑出的绿灯不能证明主路径可用，验证必须从引擎入口进。详见 [docs/findings/03-crash-safety.md](docs/findings/03-crash-safety.md)。
- 真实环境闸门（追加轮次）：被拖对象换成我们自己的 ☰ 图标、邻居换成用户真实图标，48 轮 / 96 次拖拽全绿、
  全局顺序逐项复原。它抓到一条只在真实布局下暴露的 bug：**结果复核读帧太急**——菜单栏重排是异步的，
  35 个图标时第一次读到的还是旧位置，于是把"还没落定"误判成"系统没接受"并回滚（表现为全新进程第一次拖拽
  稳定失败、第二次起成功；4 个 fixture 图标上永远看不到）。已改为有界轮询（600ms / 60ms，落位一到即返回，
  成功路径不付额外延迟）。详见 [docs/findings/05-real-bar-gate.md](docs/findings/05-real-bar-gate.md)。
- 验证项 4（占用与功耗）：**四项预算全部达标**（13MB / 0.0% / 932KB / 4 线程）。顺带修掉两处测量本身的问题：
  闸门改从 `LayoutEngine.apply` 打（引擎路径比直连 mover 慢约 100ms，这才是真实开销），结果复核从两次全量枚举
  改为「before 全量 + after 定向读归属进程」。详见 [docs/findings/04-performance.md](docs/findings/04-performance.md)。

## 下一步

① 经单独授权后，把某个用户 App 的图标真的拖走再放回（补上"用户真实图标"这条字面判据），
通过后才考虑开放 `isConfirmedSupportedOS`；② 补 1 小时静置与 Energy 评级实测；③ 进入 M1 功能面
（三分区 + 收纳面板 + 搜索 + 首启向导）。已完成：SIGTERM/SIGHUP 收尾、重放两次即放弃、
冷启动接管并发化（2.8s → 0.5~1.0s）、真实菜单栏 96 次往返闸门。
