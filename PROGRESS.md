# 🚀 Project Progress & Agent Handover — tidybar

> **Last Updated:** 2026-10-10T03:18:53Z (read-only projection)
> **Git State:** `clean` | **Branch:** `main` | **Events Count:** 263

---

## 🎯 Recent Milestones & Completed Tasks ([DONE])

- [DONE] (agy, 2026-10-10) fix(panel): 修复收纳抽屉中豆包浏览器图标纵向被切扁变形与 Tabbit 浏览器图标空白不显示的问题。根因精确定位与解决：1. 豆包浏览器在屏幕中间拥有一个 52x52 的桌面悬浮挂件窗口（Layer 27，Y=887），旧代码抓取窗口列表时未过滤菜单栏 Y 坐标带，误将悬浮挂件作为状态项窗口，且在修剪高度时将方形图标强制切除上下 30px 边距拉伸成 52x22 的狭长扁条；现增加 `isWithinMenuBarBand` 严格排除菜单栏区域外的悬浮窗，同时对宽高比接近 1:1 的方形图标保留原生完整比例，并在上下存在主体内容时禁止裁剪；2. Tabbit 浏览器折叠后被截获了纯色副屏灰色壁纸（[117,129,142]），旧 `hasVisiblePixels` 仅检查非全黑和不透明，导致纯色壁纸被视为有效图标并与抽屉底色融为一体形成“空白方块”；现增加亮度差对比度检测（`opaqueCount >= 85% && maxLum - minLum < 35 -> false`），并强化 `MenuBarIconStyle.presentation` 在无有效位图时无缝回退至系统高清 App 图标（`appIconFallback`），彻底消除抽屉空白方块与拉伸畸变。336 条单测全绿，Release 打包并热重启生效（PID 40217）。
- [DONE] (agy, 2026-10-11) fix(panel): 隔离系统折叠按钮窗口并完善物理几何相交检测，解决抽屉内 OpenClip 与 Tabbit 浏览器误显折叠箭头问题。1. 在 WindowListCapture 中对非系统项实施严格的多进程窗口所有权隔离，绝对禁止匹配 MenuBarAgent、Window Server 或 TidyBar 自身的窗口，杜绝误截系统折叠箭头；2. 升级物理几何相交检测（水平相交宽度超过 4pt 或接近折叠点即判定为挤压重叠），杜绝在挤压态下走屏幕录制切片；3. 菜单栏折叠状态下自动熔断 prewarmBitmaps 与 requestMissingBitmaps 对屏幕录制的调用；4. 无独立图层窗口的应用（OpenClip 与 Tabbit 浏览器）自动平滑降级至原生 128×128 高清 App 图标兜底；5. 自动化测试 340 条用例 41 个套件全部通过。
- [DONE] (agy, 2026-10-10) feat(peek): 完全移除外置盘降级限制，外置盘应用（豆包工作浏览器、Tabbit 等）全面统一为原生浮现。1. 彻底删除 `isExternalApp` 降级判断，外置盘应用从抽屉点击后 100% 呼出自身真实的原生 NSStatusItem，视觉与常显区完全一致（真假图标彻底统一）；2. 完善多显示器跨屏原生呈现检测（`isNativelyPresented`），支持副屏/主屏自适应合法菜单栏判定；3. 凭借精确 Bundle ID 匹配与 `unfold: false` 保护，WindowServer 全程稳定，绝无全屏菜单冲出与物理重排跳动；4. 彻底解决 Chromium 应用后台代点无反应问题，物理点击直达真实窗口。336 条单测全绿，Release 打包并热重启生效（PID 24610）。
- [DONE] (agy, 2026-10-10) fix(peek): 彻底解决点击豆包浏览器等外部扩展/Chromium应用导致整个菜单栏紊乱的问题。根因精确定位：1. 点击浮现代理图标时曾误传入 `unfold: true`，触发 `unhideAll()` 并在完成后调用 `scheduleAlignment()` 物理拖拽重排所有 30+ 个隐藏图标，导致菜单栏大乱；2. `applyMenuBarFoldState` 中存在前缀匹配循环（`bid.hasPrefix(peekedBundleID)`），误将外部磁盘安装的 `com.work.pc.doubao` 加入 `MBAssessmentModeAssertion` 白名单，引发 WindowServer 将主 App 全屏菜单渲染到菜单栏，挤占冲乱状态项；3. 代理点击严格保持 `unfold: false`，杜绝任何物理拖拽与展开紊乱；4. 增强 `isItemMenuPresented` 以识别 OPPO 互联等无标题 Layer 0 状态栏面板。336 条单测全绿，Release 打包并热重启生效。
- [DONE] (agy, 2026-10-10) fix(peek): 彻底解决浮现图标展开菜单后再次点击收起时「闪一下才会关闭」的问题。根因精准定位：菜单展开期间，用户的二次物理点击（mouseDown + mouseUp）直达目标 App 的状态栏按钮，对于采用 NSPopover / 自定义弹出面板的应用（如 AdGuard、UU远程、OPPO互联等），mouseDown 触发 AppKit 瞬态关闭（面板于 0ms 消失），紧接着 mouseUp 触发按钮 action（togglePopover: 检查 popover.isShown == false 并再次弹开面板），随后 TidyBar 延迟检测到未关闭又派发 AXPress / ESC 关闭，导致肉眼可见的「消失 -> 重弹 -> 关闭」闪烁。现已引入 `PeekCloseInterceptor`（基于 CGEventTap .cghidEventTap .headInsertEventTap）：当菜单处于展开状态时启用，精准命中二次物理点击并将其从 HID 硬件级事件流中消费吞掉（返回 nil，彻底阻止 mouseDown 与 mouseUp 到达目标 App），同时立即通过 AXPress / ESC 派发原生收起指令。全真机实测（AdGuard 与 UU远程）与 336 条自动化单测全绿，实现 0ms 瞬时干净收起，绝无任何二次弹开与闪烁！已完成 Release 打包与热重启（PID 13470）。
- [DONE] (agy, 2026-10-10) fix(peek): 彻底解决浮现图标首次点击菜单闪烁关闭与二次点击无法收起的问题。根因精确定位：用户的物理鼠标点击先于 TidyBar 的全局事件监听到达目标应用，目标应用在 mouseDown 阶段已极速创建面板窗口；当 handlePeekedItemInteraction 执行时调用 isPeekedMenuOpen 发现窗口已存在，误判为「展开状态下的二次点击」，从而在 0.12s 后派发 AXPress / ESC 将刚展开的面板关闭（闪烁消失）。现已重构为三态状态机 PeekedMenuState（.notYetOpened / .opened / .closed）：首次点击严格锁定展开意图（禁发收起），仅当状态已进入 .opened 且距展开超过 0.25s 时的二次点击才触发防反弹收起逻辑；空地点击原生关闭面板时同步复位状态。335 条单测全绿，Release 打包并热重启生效（PID 8085）。
- [DONE] (agy, 2026-10-10) fix(peek): 彻底解决浮现图标展开菜单后再次点击收起时闪烁且依然展开的问题。根据多显示器实机日志与屏幕截图精确定位：浮现条目位于副屏最左端，当其菜单处于展开状态时，用户再次点击关闭菜单（点击坐标可能略微偏离图标主体），emptySpacePredicate 因公差不足将其误判为「空白菜单栏点击」，触发 onEmptyBarClick -> cancelAndDrain() -> 隐藏条目，引发菜单栏闪烁与 WindowServer 模态菜单悬挂。现已修复：1. emptySpacePredicate 在 isMenuOpen 为 true 时拦截一切空白区判定，将点击完整交由 WindowServer 处理原生收起；2. onEmptyBarClick 在菜单展开期间严禁提前 cancelAndDrain；3. 浮现图标命中公差扩大至 ±36pt。335 条单测全绿。
- [DONE] (agy, 2026-10-10) fix(peek): 修复收纳抽屉图标浮现到菜单栏后点击菜单面板闪一下就不见了的问题。消除原生浮现模式下物理点击与 AXPress 重复冲突导致的菜单瞬间关闭，在 NativeMenuBarHider 模式下将物理点击交由 WindowServer 原生派发，仅在偏左意图推断区兜底补发 AXPress；移除 app.activate() 焦点抢占，并在浮现交互期间抑制 frontmostAppChanged 引起的重扫与断言重设，334 条单测全绿。
- [DONE] (agy, 2026-10-10) fix(peek): 修复收纳抽屉图标浮现到菜单栏后再次点击无反应的问题。打通 TidyBarController 与 TidyBarApplication 间的 onPeekedItemClick 专属激活通道，命中浮现图标时主动派发 AXPress / 代理点击以唤起目标菜单与窗口，前置 hitItem 检测彻底消除 emptySpacePredicate 早退死代码，334 条自动化单测全绿。
- [DONE] (agy, 2026-10-10) fix(peek): 修复抽屉项浮现到菜单栏后点击图标误触唤醒抽屉的问题。建立 ManagedItem 容差匹配机制、杜绝 proxyPresentedItem 降级污染自身按钮坐标、增强 emptySpacePredicate 与 hitItem 命中防护，提供 4s 初始宽限期与交互续期，334 条测试全绿。
- [DONE] `native-fold-acceptance-20260909` — 最终63716565包自身两项权限已生效，完整原生验收完成：AdGuard抽屉右键、4.2秒保活、主动关闭后复位；主按钮展开与折叠时8常显/19隐藏分界正确；真实图标19/19及悬停收起通过。Debug与Release各312条41套件通过，配置保持。详见docs/findings/17-final-drawer-acceptance.md。
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

_Working tree is clean._

## 💡 Handoff Instructions for Next Agent

1. Before making changes, register your task: `baton start --project . --tool <tool-name> --summary "<task-description>"`
2. Review the `[TODO]` items above and implement the required features/fixes.
3. Upon completion, close the lease and sync to GitHub: `baton finish --project . --tool <tool-name> --session <id> --summary "<what-was-done>" --push`

