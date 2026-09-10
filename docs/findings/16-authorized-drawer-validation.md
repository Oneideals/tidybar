# 授权后的抽屉实测与补充修复

日期：2026-09-10。

## 已验证的事实

原构建 `9a9ccd50207af354` 的辅助功能及屏幕录制授权确实生效。应用进入完整接管模式，首次预热得到 21/22 张图标，缺失 FSMenuApp。

- 折叠时：8 个常显项全部位于按钮右侧，22 个隐藏项位于屏外。
- 展开时：常显、隐藏项分别在按钮右、左侧，检查未发现越界项。
- Ghost Downloader 的抽屉右键第一次被可点击性检查拒绝；再次操作后，应用记录了真实点击及原生菜单可见。这说明不能只用一次成功掩盖首次展开的时序问题。
- FSMenuApp 在稳定展开时可以正常命中、截图。普通应用的长菜单遮住其位置时，命中检查会返回 `occluded`，保留占位是正确行为。
- 同一份 `MenuBarAccessSession` 在原生应用探针中取得了前台；使用短菜单时，新预热组件成功捕获当前运行的 **18/18** 个隐藏图标，包括 FSMenuApp。后一次会话运行的应用数不同于前一次，未为凑数量启动其他软件。

## 本轮补充修复

1. 点击转发在 0.8 秒内等待两次相同、可命中的目标帧。每轮及投递前继续检查用户输入、取消及会话状态，避免展开尚未稳定就误报遮挡。
2. 预热中因位置或命中校验失败的项目，重新枚举后最多补抓一次。重新读取有 2 秒兜底，补抓前后保持 `isValid` 和缓存 generation 校验；旧坐标截图不会被采纳。
3. 抽屉使用真实菜单截图边角像素的中位底色，保留原始图标比例和色彩，减少白色面板上明显的灰色截图块。

新增时序、补抓及绘制回归均已确认红→绿。Debug、Release 各 **311 条 / 41 个套件通过**，全部 Release 产品构建及严格签名验证通过。限定代码复核未发现新阻断。

## 当前构建与剩余验收

新构建已安装、启动：`dist/TidyBar.app`。

可执行文件 SHA-256：`65e5dd3e928c1a57b6830235cc5e741318947bff2055fe52fb0c593d15ad972a`。

新签名启动时，应用自身再次报告辅助功能、屏幕录制未授予。已请用户更新当前路径的两项授权；未操作授权开关或 TCC 数据库。

仍需在这份新构建上完成完整抽屉验收，尤其是 AdGuard 的真实右键菜单及多次首次展开。组件截图、离线回归和旧构建的部分真机通过，不替代当前包的完整验收。

## 配置与取证

临时的 0 秒自动收起已恢复为原 **2 秒**。分组文件仍为隐藏 27、常显 8 条记录（包含系统历史记录），SHA-256 保持 `086bf5bb5d644a6d107eb596aa69d0b072f09f8d11864bcf036d3e5a0a89d4d2`；未回退用户分组或微信台账修复。

- [原构建授权及交互日志](../../.build/drawer-acceptance-20260910-7/app.stderr.log)
- [折叠检查](../../.build/drawer-acceptance-20260910-7/folded-partition.json)、[展开检查](../../.build/drawer-acceptance-20260910-7/expanded-partition-confirmed.json)
- [旧抽屉实拍](../../.build/drawer-acceptance-20260910-7/drawer.png)
- [新组件绘制预览](../../.build/drawer-acceptance-20260910-7/drawer-component-preview.png)
- [短菜单取得前台的记录](../../.build/drawer-acceptance-20260910-7/menu-access-probe.log)、[18/18 捕获记录](../../.build/drawer-acceptance-20260910-7/capture-under-short-menu.log)
- [Debug](../../.build/drawer-acceptance-20260910-7/checks-debug.log)、[Release](../../.build/drawer-acceptance-20260910-7/checks-release.log)、[构建](../../.build/drawer-acceptance-20260910-7/build-release.log)
- [当前构建启动及权限日志](../../.build/drawer-acceptance-20260910-7/updated-app.stderr.log)

全部修改仍未提交、未推送。桌面操作使用实时窗口与输入状态检查；拒绝或无法确认的动作未记为成功。
