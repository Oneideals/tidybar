# 图标统一呈现与抽屉单项浮现设计

日期：2026-09-15。状态：待用户评审。

## 1. 目标

两条用户需求：

1. 菜单栏、抽屉、设置面板、搜索面板里的图标只有一套显示标准：一律是菜单栏原样截图；截不到时画同一种中性占位，不再混入彩色 App 图标或 SF Symbol。
2. 点击空白菜单栏呼出抽屉；点击抽屉里的图标 X，X 被物理移到 TidyBar 按钮右侧、紧贴常显组临时显示；用户可直接右键 X 打开其原生菜单；菜单关闭后 X 自动回到隐藏区。

## 2. 现状与根因（摘自 2026-09-15 代码分析）

- 三处 UI 已共用 `IconBitmapStore`，但都各自回退到 `AppIconResolver`，回退链本身就是三种视觉语言。
- 冷启动首帧即折叠，隐藏项从未出现在屏上，截图永远缺失；只有物理整理成功后的预热才截图，而首扫判定已分区时会跳过整理。
- 位图与 `AppIconResolver` 缓存都不随深浅色外观失效。
- 当前浮现实现（`revealSingleItemInMenuBar`）把推杆归零后用两扇遮罩盖住其他隐藏项。全局监听把任何右键当作收起请求，转发的合成右键没有打 `syntheticEventTag`，右键会立即触发折叠；硬计时 6 秒收起，不检测原生菜单；主线程反复全量枚举。
- 已验收过的 `requestProxyClick` 与 `MenuBarClickRelay` 链路已无调用方。

## 3. 需求一设计：统一图标呈现

### 3.1 组件：`MenuBarIconPresentation`（新文件 `Sources/TidyBarCore/Panel/MenuBarIconPresentation.swift`）

```swift
public enum IconPresentation: Equatable {
    case bitmap(CGImage)          // 已验证的菜单栏截图
    case placeholder(reason: PlaceholderReason)
}
public enum PlaceholderReason: Equatable {
    case captureNotAuthorized     // 未授权屏幕录制
    case notCapturedYet           // 已授权，尚未截到
    case itemNotRunning           // 台账项，当前不在菜单栏
}
public enum MenuBarIconStyle {
    public static let glyphHeight: CGFloat = 22
    public static let placeholderWidth: CGFloat = 22
    public static let cornerRadius: CGFloat = 5
    /// 纯函数：由条目与位图查找结果决定呈现方式。
    public static func presentation(for item: ManagedItem, bitmap: CGImage?, captureAuthorized: Bool) -> IconPresentation
    /// 由呈现方式与容器矩形算出绘制矩形：位图按截图比例等比缩放到 glyphHeight。
    public static func glyphRect(for presentation: IconPresentation, in container: CGRect) -> CGRect
    /// 统一绘制：位图直接绘制；占位画虚线圆角框加淡色首字母。
    public static func draw(_ presentation: IconPresentation, for item: ManagedItem, in container: CGRect)
}
```

判定顺序固定：`item.frame == .zero` 且不在当前扫描里 → `itemNotRunning`；未授权 → `captureNotAuthorized`；有位图 → `bitmap`；否则 `notCapturedYet`。

### 3.2 三处接入

- 抽屉 `TidyBarPanelView.draw`：删除 `AppIconResolver` 分支，统一调用 `MenuBarIconStyle.draw`。`contentLayout` 的尺寸计算改用 `glyphRect` 的宽度，占位宽度固定为 `placeholderWidth`。
- 设置面板 `DraggableIconCellView`：不再持有 `NSImageView` 与 `cachedImage` 图像；`draw` 里先画底板（保留，作为拖拽目标的可视区域），再调用 `MenuBarIconStyle.draw`。Inspector 图标同样改为呈现层输出。
- 搜索面板 `createRowView`：行内图标改为一个 `MenuBarIconGlyphView`（`NSView` 子类，`draw` 转发到 `MenuBarIconStyle.draw`），固定 22pt 高。
- 删除 `Sources/TidyBarCore/Accessibility/AppIconResolver.swift`。

三处的 `imageProvider` 闭包保留，仍指向 `TidyBarPanelController.cachedImages`。

### 3.3 截图来源：幕布截图扫描（`CurtainCaptureSweep`）

新文件 `Sources/TidyBarCore/App/CurtainWindow.swift` 与 `Sources/TidyBarCore/App/CaptureSweep.swift`。

- `CurtainWindow`：无边框、不透明、`level = statusWindow + 1`、`ignoresMouseEvents = true`、`canJoinAllSpaces`，覆盖从屏幕左缘到 TidyBar 按钮左缘的菜单栏带。颜色取当前位图缓存的角点中位色，缓存为空时取系统菜单栏背景色近似值。
- `CaptureSweep.run(items:completion:)`（主线程）：
  1. 前置：屏幕录制已授权；`controller.capability == .fullDrag` 不是必需；无进行中的整理、代点、浮现；`userIdleTime >= 1`；键鼠未按下。
  2. 记录幕布窗口的 `windowNumber`，升起幕布。
  3. `applyMenuBarFoldState` 的推杆归零分支复用为 `setPusherExpanded(true)`，不改变 `RevealStateMachine`。
  4. 后台 `reader.discoverItems()` 取新帧，主线程调用 `panelController.prewarmBitmaps(for:)`。
  5. 完成或 2 秒超时后 `setPusherExpanded(false)`，撤幕布，回调。
- `ScreenCaptureKitIconCapturer.capture` 增加参数 `excludingWindowNumbers: [CGWindowID]`，用 `SCShareableContent.windows` 匹配后传给 `SCContentFilter(display:excludingWindows:)`，幕布本身不会进入截图。
- 触发时机：首扫完成后位图缺项；外观变化通知（`NSApplication.effectiveAppearance` KVO 与 `AppleInterfaceThemeChangedNotification`）后先 `purgeBitmaps` 再扫描；屏幕参数变化；重扫发现新图标且缺位图。同一时刻只允许一次扫描，重复请求合并。

## 4. 需求二设计：抽屉单项浮现

### 4.1 状态机（`PeekCoordinator`，新文件 `Sources/TidyBarCore/App/PeekCoordinator.swift`）

```
idle ──request(X)──▶ movingOut ──placed──▶ presented ──rehide──▶ movingBack ──done──▶ idle
                        │failed                                       │failed
                        ▼                                             ▼
                      idle(notice)                              idle(notice + 请求整理)
```

每个状态携带 `itemID`、`since`、`autoRightClick: Bool`。协调器持有：`services.reader / mover / cursor`、`MenuBarAccessSession` 构造闭包、幕布、推杆控制闭包 `setPusherExpanded(Bool)`、代点入口 `requestProxyClick(item, .secondary, unfold: false)`、回调 `onStateChanged`。

### 4.2 移出流程（`movingOut`）

1. 收起抽屉与搜索面板，`controller.peekedItemID = X.id`。
2. 升幕布；`setPusherExpanded(true)`；创建 `MenuBarAccessSession` 并等待 `whenPrepared`。
3. 串行队列：`reader.discoverItems()`，按 `DividerGeometry.physicalItems` 排序，找到 X 与按钮（`controls.toggle`）。目标下标为 `toggleIndex`（X 在按钮左侧，移到按钮右侧即越过按钮）；`MenuBarDropTarget.targetX(in:moving:to:)` 得落点；`expectedHitTargets` 传给 `mover.move`。落点须仍在屏内菜单栏，否则失败。
4. 移动后重读，验证 X 的 `centerX` 大于按钮 `centerX` 且小于第一个常显项，最多重试 2 次。
5. 主线程：`setPusherExpanded(false)`；撤幕布；结束访问会话；`CGWarpMouseCursorPosition` 到 X 中心；进入 `presented`。
6. `autoRightClick` 为真时调用 `requestProxyClick(X, .secondary, unfold: false)`，由 `MenuBarClickRelay` 发带 `syntheticEventTag` 的真实右键并观察菜单。

失败（会话不可用、移动被中断、图标消失、落点不合法）：撤幕布、推杆撑回、清空 `peekedItemID`、抽屉显示 `ActivationOutcome.userReadable` 类型的提示并重新打开抽屉。

### 4.3 展示期（`presented`）

- 推杆保持 10,000pt，X 物理位于按钮右侧，常显组紧随其后。
- 回收判定 `RehidePolicy.shouldRehide(now:)`（纯函数）：`reader.isMenuPresented(for: X) == false`、鼠标未按下、光标不在 X 帧内、距最近一次交互超过 `rehideDelay`（0 表示不自动回收）。`isMenuPresented` 返回 `nil` 视为不能回收。轮询 0.25 秒一次，仅在 `presented` 状态挂表。
- 交互续期：光标进入 X 帧、菜单栏带内任何点击、代点 relay 报告 `pressed/menuPresented`。
- 立即回收：用户点击 TidyBar 按钮、点击空白菜单栏呼出抽屉、`toggleMenuBarFold`、锁屏、退出。
- 全局事件：`EventEngine` 的 `rightMouseDown` 只在菜单栏带外才发 `onConcealRequest`；带内右键视为与图标交互。`leftMouseDown` 命中 X 时 `TidyBarController.handle` 走现有「命中真实图标」分支，不触发抽屉。

### 4.4 移回流程（`movingBack`）

与移出对称：幕布、推杆归零、访问会话、拖到隐藏区末位（`controls.rightDivider` 左侧，落点为最后一个隐藏项 `maxX + 2`，隐藏区为空时落在右分隔符中心）、验证 X 的 `centerX` 小于右分隔符、推杆撑回、撤幕布、清空 `peekedItemID`。移回失败时保留 `peekedItemID` 为空并调用 `scheduleAlignment()`，交给常规整理收尾。

### 4.5 控制器与整理引擎的豁免

- `TidyBarController.peekedItemID: String?`。
- `DividerGeometry.partitionDisorder / isCorrectlyPartitioned / foldingOrder` 新增可选参数 `exempt: Set<String>`，豁免项按 `.visible` 计。`isCurrentLayoutCorrectlyPartitioned` 与 `alignDividerToVisibleBoundary` 传入 `peekedItemID`。
- `scheduleAlignment`、`scheduleRefresh` 的 `allowAlignment`、`CaptureSweep` 在浮现非 idle 时一律推迟，浮现结束后补跑一次。
- `adoptScan` 不受影响：`engine.fold` 只按 id 分区，不读物理位置。
- 布局日志与台账不写入任何浮现相关变化。

### 4.6 与现有代码的取舍

- 删除 `MenuBarIsolationMaskView`、`revealSingleItemInMenuBar`、`findAndIsolateItem`、`applySingleItemIsolation`。
- `requestProxyClick` 增加 `unfold: Bool`，浮现路径传 `false`，其余调用保持原语义；抽屉左键改为 `peek(X, autoRightClick: false)`，右键改为 `peek(X, autoRightClick: true)`，搜索面板激活等同左键。
- 拖拽能力未通过 `DragGate` 时（`capability != .fullDrag`），抽屉点击退回为现有 `requestProxyClick(X, .primary)` 并显示「当前系统未确认拖拽接管，无法临时浮现」提示。

## 5. 错误处理与安全

- 所有合成输入仍打 `syntheticEventTag`，`EventEngine` 忽略自家事件。
- 浮现期间锁屏或会话不可交互：取消当前步骤，释放在途拖拽（`releaseInFlightDrag`），推杆撑回，撤幕布，`peekedItemID` 清空并请求整理。
- 退出：`stopBeforeExit` 先 `PeekCoordinator.cancelAndDrain`，再走现有收尾。
- 幕布升起超过 3 秒未撤（任一步骤卡住）由看门狗强制撤下并撑回推杆，记录一条失败。
- 主线程不再调用 `discoverItems`；浮现与截图扫描的枚举都在串行队列。

## 6. 测试

离线回归（`Sources/TidyBarChecks/Cases`）：

- `IconPresentationTests`：四种判定顺序；`glyphRect` 对宽图标保比例、对占位固定宽；三处 UI 不再引用 `AppIconResolver`（编译期由删除文件保证）。
- `PeekPlanTests`：给定物理顺序与按钮，移出落点等于越过按钮的 `targetX`；移回落点为隐藏区末位；隐藏区为空时落右分隔符中心；X 不在屏内返回失败。
- `PeekCoordinatorTests`：用 `FakeMenuBarReader` 与联动 `FakeMenuBarMover` 走完整状态机；移动失败回到 idle 并携带提示；锁屏取消；`peekedItemID` 在 `presented` 期间非空、结束后为空。
- `RehidePolicyTests`：菜单开着不回收；`nil` 不回收；光标在帧内不回收；延迟 0 不自动回收；条件满足才回收。
- `DividerGeometryExemptTests`：豁免项在按钮右侧不计逆序。
- `EventEngineTests`：带内右键不发收起请求，带外右键仍发。
- `CaptureSweepTests`：未授权不启动；进行中合并重复请求；超时撤幕布。

真机验收沿用 `docs/findings` 的取证方式：抽屉左键浮现后截图对照 X 紧贴按钮右侧；用户手动右键 AdGuard 面板保持超过 rehideDelay；面板关闭后 X 回到隐藏区且分区哈希不变；深浅色切换后抽屉位图更新；冷启动后无需展开即可看到 19/19 位图。

## 7. 范围外

- TidyBar 自身按钮的「◀/▶」文字换成模板图标：会影响以标题识别按钮的整理逻辑，另行处理。
- 位图去底色转模板图：不在本次范围。
- 位图持久化到磁盘：不在本次范围。
