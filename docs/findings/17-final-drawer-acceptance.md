# 抽屉与主按钮最终原生验收

日期：2026-09-10。

最终应用为 `dist/TidyBar.app`，可执行文件 SHA-256：
`63716565f62eea3cbc57755440bd351d78ae719a85e7133862754a3bbd23c9e9`。

这份应用启动时自行确认辅助功能、屏幕录制均已授予，并进入完整接管模式。以下验收在此构建上完成；独立测试工具的权限没有代替应用自身的权限判定。

## 最后一个修复：原生自绘面板的存活检测

旧构建已经能通过抽屉右键打开 AdGuard，但默认 2 秒自动收起会提前关闭其面板。复现脚本明确记录了「成功打开」之后「用户未操作，面板提前关闭」。

原因是 AdGuard 用原生弹出窗口承载自绘面板，并不暴露 `AXMenu`。原检测只认 AX 菜单，因而把这次操作当作普通点击完成，恢复了自动折叠。

`AccessibilityMenuBarReader.isMenuPresented` 现在也检查 WindowServer 中同一目标进程、当前可见、属于原生弹出菜单层级且紧邻被点击图标的窗口。普通文档窗口、尺寸过小或远离图标的窗口不会据此被当成菜单。已有的 AX 菜单检测继续保留。

新增回归 `nativeStatusPopoversAreRecognizedAsOpenMenus` 已确认红→绿。独立原生转发组件也验证了打开、保持超过 4 秒、再次点击原图标关闭、准确观察关闭的完整流程。

## 最终应用验收

| 项目 | 实测结果 |
| --- | --- |
| 抽屉右键 | 打开 AdGuard 自己的原生面板，应用日志确认「已打开原生菜单」。此前已将抽屉右键与直接右键的面板截图对照，两者完全一致。 |
| 面板保活 | 保留默认 2 秒收起设置，右键面板在 4.2 秒后仍然可见；光标未移动。 |
| 关闭与复位 | 再次点击 AdGuard 的真实菜单栏图标关闭面板；TidyBar 识别关闭，随后将 19 个隐藏图标收回屏外。 |
| 主按钮展开 | 真实左键点击主按钮后，19 个隐藏图标在按钮左侧，8 个常显图标在右侧，未发现越界项。 |
| 主按钮折叠 | 再次左键点击主按钮，隐藏图标收回屏外，常显图标继续位于右侧。 |
| 图标样式 | 冷启动预热完整捕获当前 19/19 个隐藏图标。抽屉实拍采用菜单栏原始图像及比例，包含宽图标和文字状态。 |
| 抽屉悬停 | 稳定显示后，光标停留超过 2 秒仍保持打开；移开后按默认延迟收起。 |

普通点击主按钮负责菜单栏原地展开／折叠；`⌥Space` 或按住 Option 点击主按钮可呼出收纳抽屉。

首次悬停检查恰好遇到后台重新整理菜单栏，采样瞬间面板因物理布局忙碌暂时隐藏，整理结束后恢复。原始失败日志保留；在布局稳定后重新计时，悬停与离开检查均通过。没有将重排期间的暂时隐藏误判为自动收起故障。

AdGuard 的这个面板不响应本次测试投递的 Escape。关闭验证改为再次点击经实时命中检查确认的原图标，并检查窗口实际消失，没有把按键投递成功当作关闭成功。

## 构建与配置

- Debug、Release 各 **312 条用例 / 41 个套件通过**。
- 全部 Release 产品构建通过；暂存包及安装包均通过严格代码签名验证。
- 用户的 `rehideDelay` 仍为 **2 秒**，设置与测试前一致。
- 持久化布局文件的 SHA-256 保持 `086bf5bb5d644a6d107eb596aa69d0b072f09f8d11864bcf036d3e5a0a89d4d2`。持久化记录仍为隐藏 27、常显 8；当前原生验收数量排除了未运行历史项与不可管理的系统项。
- 没有操作 AdGuard 防护开关或其他软件的功能设置，没有变更 TCC 数据库或代点权限开关。既有分组及微信身份台账修复保留。
- 最终 App 保持运行；源码修改未提交、未推送。

## 取证

全部本轮原始产物位于 `.build/drawer-final-20260910-8/`。

- [旧版提前关闭的复现](../../.build/drawer-final-20260910-8/adguard-cycle-stable.log)
- [修复后的原生组件完整流程](../../.build/drawer-final-20260910-8/adguard-relay-fixed-cycle.log)
- [最终 App 权限及原生点击日志](../../.build/drawer-final-20260910-8/app-popup-fixed.stderr.log)
- [最终抽屉右键完整流程](../../.build/drawer-final-20260910-8/adguard-cycle-final.log)
- [最终抽屉实拍](../../.build/drawer-final-20260910-8/adguard-cycle-final-drawer.png)、[超过自动收起时限的 AdGuard 面板](../../.build/drawer-final-20260910-8/adguard-after-delay-final.png)
- [悬停与主按钮检查](../../.build/drawer-final-20260910-8/hover-and-button-final-stable.log)、[悬停实拍](../../.build/drawer-final-20260910-8/hover-confirmed-final.png)
- [主按钮展开后的分区](../../.build/drawer-final-20260910-8/expanded-by-button-final.json)、[再次点击折叠后的分区](../../.build/drawer-final-20260910-8/folded-by-button-final.json)
- [右键面板打开时的分区](../../.build/drawer-final-20260910-8/expanded-popup-final.json)、[面板关闭后的分区](../../.build/drawer-final-20260910-8/folded-after-popup-final.json)
- [Debug 检查](../../.build/drawer-final-20260910-8/checks-debug.log)、[Release 检查](../../.build/drawer-final-20260910-8/checks-release.log)、[Release 构建](../../.build/drawer-final-20260910-8/build-release.log)

此前的完整修复说明见 [抽屉原生交互](15-drawer-native-interaction.md) 和 [授权后的抽屉实测](16-authorized-drawer-validation.md)。本记录更新了上一份报告中仍待验证的最终构建状态。
