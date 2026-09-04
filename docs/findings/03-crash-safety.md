# M0 验证项 3 结论：崩溃与强杀安全

日期：2026-09-05 ｜ macOS 26.6.2 ｜ 实验对象：自造 fixture 图标（`local.tidybar.fixture`）
复现：`./scripts/m0-crash-test.sh 3`（三角色：`drag` 受害者 / `inspect` 检查者 / `recover` 恢复者）

## 结论

**通过**。强杀后系统输入状态干净、图标不损坏、孤儿意图可被识别并重放收敛。但过程中抓到两个更值钱的东西：一个**主路径完全不可用**的 bug，和一个尚未处理的**优雅退出缺口**。

## 关键测量：残留状态必须由全新进程读

受害者死在 `mouseDown` 与 `mouseUp` 之间时 `defer` 不执行，自报清白没有意义。因此检查者是一个从未投递任何输入事件的新进程：

| 场景 | mouseButtons | session ⌘ | 图标数 | 孤儿意图 | 重放 |
| --- | --- | --- | --- | --- | --- |
| 拖拽中途 kill -9（3 轮） | 0 | no | 4→4 | 每轮都检出 | ✓ 全部 `pendingCleared=true` |
| SIGTERM | 0 | no | 4→4 | **仍残留** | — |
| journal 被写坏（非法 JSON） | 0 | no | 4→4 | none（读不出即视为无状态） | 不崩溃 |

三点结论：
1. **macOS 会在进程死亡时回收其事件源状态**——不会留下按住的鼠标键或 ⌘（这是验证项 2 那个隐患的最坏版本，实测不成立，值得放心）；
2. **图标不会被拖坏**：拖拽未完成时系统不提交重排，因此"按意图重放"是正确恢复策略（而不是回滚到旧状态）；
3. **journal 对损坏数据是安全的**（`try?` + 空态回退），不会把工具变成打不开。

## 抓到的主路径 bug：引擎里留着已被证伪的光标预检

`LayoutEngine.apply()` 在 mover 之前又做了一次 `sentinel.preflight(expectedCursor: 图标中心, actualCursor: 当前光标, …)`。验证项 2 已经证伪这个写法：光标是我们稍后 warp 过去的，动手前它本来就不在图标上，**比较结果永远是"漂移中止"**。

为什么之前没发现：**验证项 2 的 100/100 是直连 mover 测的，绕过了引擎**。也就是说产品真正的隐藏/显示路径其实一直是死的。这次走完整引擎链路（recover 重放）才暴露：`RECOVER replay failed cursorDrift(818pt)`，三次全中。

已按职责边界重做：

- **光标纪律归 mover**（warp → 放置复核 → 飞行中逐步复核），引擎不再比较光标；
- 引擎只保留自己该管的：用户是否按住鼠标、操作节奏；
- **引擎改为复核结果**：`MenuBarDropTarget.didMove(before:after:towardX:)`——图标真的朝目标动了才算成功，否则抛 `noVisibleEffect`、回滚、**绝不写入已提交布局**。这条同时把验证项 2 发现的"落进空隙被静默忽略"变成可检测失败。

新增 3 条用例锁死边界：光标停在屏幕中央时引擎必须照常工作；图标未动必须判失败且不提交；联动改位的成功拖拽才允许提交。回归 124 → **128 条全绿**。

**方法学教训（写在这里防止再犯）**：旁路直连底层组件跑出来的绿灯，不能证明产品主路径可用。之后所有验证都必须从引擎入口进（`LayoutEngine.apply`），mover 单测只作为组件级补充。

## 已补：优雅退出收尾 + 重放上限（2026-09-05 二轮）

原来的两个缺口都已闭合并真机复验。`scripts/m0-crash-test.sh` 现在多了两个场景：

| 场景 | 观测 | 判定 |
| --- | --- | --- |
| B：拖拽中途 SIGTERM（`--role terminate`，等到 `inflight=yes` 再发信号） | 受害者打印 `GRACEFUL signal=15 wasInFlight=yes pending=true`；独立进程读到 `mouseButtons=0 / commandHeld=no`；图标 4→4 | ✓ 半空拖拽被确定性抬起，意图按策略保留 |
| D：埋一个永远做不成的旧格式意图（`--role poison`） | 第一次 `outcome=retryScheduled(failures: 1) pending=true`，第二次 `outcome=abandoned pending=false`，随后 inspect 无 pending | ✓ 两次即放弃；升级前的 pending 文件仍可读出 |

实现分三层，都能单独被测：`GracefulShutdown`（SIGTERM/SIGHUP/SIGINT 信号源，回调最多跑一次）、
`AccessibilityMenuBarMover.releaseInFlightDrag()`（幂等抬起，且会让进行中的拖拽在下一步以 `dragInterrupted` 收手，
绝不"抬两次"或报假成功）、`LayoutJournal.noteReplayFailure` + `LayoutEngine.replay/noteReplayFailure`（计数累计到上限即清除意图并回落 committed）。装配层把信号路径与 `applicationWillTerminate` 汇到同一个 `flushForExit`，实测 `kill -TERM` 打真 app 会打印「退出收尾完成｜原因=signal:SIGTERM」并干净退出。

**顺带修正上一轮的一句话**：表格里的"重放 ✓ 全部 pendingCleared=true"给人的印象是重放会成功。本轮同样的 kill 场景里，重放分别以 `cursorDrift(56pt)`、`userInteracting`、`noVisibleEffect` 失败。差别来自环境（光标真在被移动、图标顺序已不同），不是回归。正确说法是：**重放只保证安全（失败即回滚、不提交、有上限），不保证成功**。这也是上限机制存在的理由。

## 两个方法学坑（都是"看起来像实现的 bug"）

1. **`raise()` 不会触发 DispatchSource 信号源**。`raise()` 是线程级投递，而我们为了挂源已经把该信号的处置设成 `SIG_IGN` —— 信号当场被丢弃，永远不会变成进程级 pending，kevent 看不见它。必须用 `kill(getpid(), sig)`。用 `raise()` 写出来的"信号没触发"会让人误以为实现有问题，白花一轮排查。
2. **`kill` 的参数顺序是 `(pid, sig)`**。写成 `kill(SIGTERM, getpid())` 等于给 PID 15 发信号：权限不允许时**静默返回错误**，测试表现为"永远不触发"，且完全看不出自己发错了对象。信号类断言第一次跑就必须看到"回调真的执行了"的正面证据（我们靠打印 `DBG armed 3 sources` + 最终 `GRACEFUL signal=15` 才定位到）。

## 下一步

验证项 4 已完成（定向读取已接进引擎，见 04-performance.md）。本项遗留的两条都已闭合，剩下的都是 M1 的事：冷启动接管时延（真 app 测得 2.80s，超预算）、以及在用户真实图标上复跑拖拽闸门。
