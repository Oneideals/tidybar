# M0 验证项 1 结论：菜单栏图标枚举

日期：2026-09-04 ｜ 机器：MacBook（外接 1920×1080 为主屏 + 内置 1470×956 为副屏）｜ 系统：macOS 26.6.2 (25G83)
复现：`swift run tidybar-probe --repeat 12` ｜ `swift run tidybar-attr-dump <bundle-id>` ｜ `swift run tidybar-probe --expect-bundle local.tidybar.app`

## 一句话结论

**可行**。用辅助功能 API 按进程遍历 `AXExtrasMenuBar` 能稳定读到全机器第三方图标（本机实测 28 个第三方 + 5 个系统托管），但代价是三条硬约束：**必须过滤脏数据**、**不能靠名字做身份**、**必须异步扫描**。冷启动全量扫描实测 2.6~3.4s，绝不可能同步做。

## 实测数据

| 项 | 数值 |
| --- | --- |
| 探测进程数 | 90（其中 30 个暴露 `AXExtrasMenuBar`） |
| AX 返回原始子项 | 62 |
| 策略接受 | 32~33（第三方 28 + 系统托管 5） |
| 策略拦截 | 30：`zeroSize` 27~28、`outsideMenuBar` 3 |
| 冷启动全量扫描 | 2 622 ~ 3 380 ms |
| 稳态扫描 | p50 110ms ｜ p95 195ms ｜ max 237ms |
| 菜单栏真实高度 | 主屏 30pt、副屏 33pt（不是常见的 24pt） |
| 坐标系 | AX 为左上原点 y 向下；副屏 AppKit 原点 y = −384 |

读到的图标样本（含名称、坐标、尺寸，全部真实）：Raycast、微信、Telegram、1Password、AlDente、Surge、AdGuard、Boom 3D、PopClip、Paste、HapiGo、CleanMyMac、BetterDisplay、OrbStack、QuitAll、Rectangle Pro、CC Switch、滴答清单、Dropover、Bob、OPPO 互联、FSMenuApp、1Capture、BetterAndBetter、千问办公，以及系统的时钟、天气、控制中心、音频和视频控制、输入法菜单。

## 四个推翻了原设计的发现

### 1. 第三方图标普遍没有任何稳定标识 —— 「owner + title 当 id」不成立

对 Raycast 那个图标做属性穷举，得到的是：

```
属性名: AXEnabled, AXFrame, AXParent, AXSize, AXChildren, AXFocused, AXRole,
        AXTopLevelUIElement, AXHelp, AXPosition, AXTitle, AXWindow,
        AXRoleDescription, AXSelected, AXSubrole
AXRole = "AXMenuBarItem"   AXSubrole = "AXMenuExtra"
AXRoleDescription = "status menu"   AXTitle = ""     ← 空串
AXPosition = Point(776,3)  AXSize = Size(34,24)
```

**没有 `AXIdentifier`，没有 `AXUUID`**，`AXTitle` 是空串，也没有 `AXDescription`。全机器 32 个图标里，只有 1 个有 `AXTitle`、3 个有 `AXDescription`，**28 个（88%）只能靠 (归属进程 + 进程内序号) 识别**。

对策：引入身份强度 `IdentityStrength`。关键洞察是"靠序号"内部还分两种稳定性——单图标进程的序号恒为 0，结构上稳定、可持久化；只有多图标进程才真会因重排错位。细化后**真正需要"按位置认领"的只剩 6%（2/32）**，产品可用性从"八成不可靠"变成"极少数需重新认领"。

同时**禁止用 `roleDescription` 兜底取名**：它是"状态菜单"/"status menu"，全机器几十个图标共用，会把匿名项伪装成同名项，比承认匿名更糟。显示名改退回 `NSRunningApplication.localizedName`（于是列表里是"Raycast""微信"，可读性反而更好）。

### 2. Control Center 会把不可见项一起报出来

`com.apple.controlcenter` 一次报 37 个子项，其中 **28 个是 0×0**（当前不可见的菜单项）。不过滤就会让布局里塞满幽灵项，用户配置表变成 70 行垃圾。已按 `zeroSize` 拦截。

### 3. `AXExtrasMenuBar` 子项里混着弹层和离屏残留

实测 BetterDisplay 把一个 **310×346** 的弹层报进了 extras 子项；cubox 有一个 y=−24 的残留项（在它那块屏上，但远在菜单栏之下）。因此"在屏幕内"不等于"在菜单栏上"，判定必须**逐屏做菜单栏带命中**（含副屏负原点）。已按 `outsideMenuBar` 拦截。

### 4. 枚举耗时决定了它只能异步 + 事件驱动

首次对每个进程建立 AX 连接，全量扫描 2.6~3.4s；稳态仍要 110~195ms。原计划的"节流窗口 200ms + 启动即扫描"两条都不成立：

- 启动路径改为 `start(scansSynchronously: false)` + `BackgroundEnumerator` 后台首扫，结果回主线程落地（否则击穿"启动到接管 2s"预算，还会在启动瞬间卡住菜单栏）；
- 去抖窗口抬到 **250ms**（必须 ≥ 实测 p95，否则一次图标抖动引发连环重扫）；
- 只允许 5 类触发源刷新（图标增删、前台切换、屏幕参数变化、用户主动），**不做任何定时轮询**。

## 附带发现：CLI 进程不发布 `AXExtrasMenuBar`

探针自建 6 个图标后枚举到自己 = 0。对照实验证明这**不是 reader 的 bug**：无 bundle 的 CLI 进程压根不发布 `AXExtrasMenuBar`；换成已打包的 `TidyBar.app`（有 bundle id），它自己的 ☰ 图标被完整读出：

```
✓ 读到 "☰" @ 504,1053 24x24 身份=axTitle
```

方法学教训：**自检必须建立在有已知答案的真实对象上**。用探针自身当被测对象会得出"reader 完全不能用"的错误结论。已把这条固化成可复跑断言 `--expect-bundle`。

## 风险与遗留

| 项 | 状态 |
| --- | --- |
| 序号型身份在多图标 App 重启后错位 | 未解，v1 走"按位置认领 + 显式提示"，不做静默持久化 |
| 图标增删事件如何感知（不能轮询） | 待设计：AXObserver 观察归属进程的 `AXChildrenChanged`，或 KVO 前台切换；M1 决定 |
| 跨 Space / 全屏 App 下菜单栏高度与图标可见性变化 | 未测 |
| 多显示器下枚举归属哪块屏 | 已能读到坐标，但"图标属于哪块屏"未做映射 |
| 非 Tahoe 系统（14/15）行为差异 | 未测，需在第二台机器上复跑同一 probe |

## 对 Go/No-Go 的影响

M0 清单里"枚举在 10 个真实 App 上稳定，且有明确失败清单"一项**达成**（28 个真实 App，失败清单见上）。下一步进验证项 2（⌘ 拖拽与事件哨兵）——那才是真正决定产品能不能成立的一环，且已有明确的失败退路（拖不了就永久停留在收纳面板模式）。
