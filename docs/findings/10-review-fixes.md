# 全量审查修复记录 · 2026-09-08

后续真实应用测试又修复了退出覆盖布局等问题；当前产物与最新验证结果见 [原生应用实测记录](11-desktop-test.md)。以下保留首次修复阶段的验证记录。

本次修复对应基线 `1935331537f3c897bf46d0b2a8c75fcf1d037ea9` 的 16 个独立审查问题，以及修复复核中发现的相关边界问题。原报告见 [2026-09-08 审查报告](../../.build/review-20260908/review.md)。S1 与 B1 是同一问题。

修复保留在工作区，未提交或推送。Debug 回归及最终 Release 回归均为 **253 / 253 条通过，38 个套件**；相对基线新增 32 条用例，其中 [ReviewRegression](../../Sources/TidyBarChecks/Cases/ReviewRegressionTests.swift) 包含 31 条生命周期、故障注入和界面回归。

## 原始问题与修复

| 编号 | 问题 | 修复结果 | 验证依据 |
| --- | --- | --- | --- |
| S1 / B1 | 空扫描导致渲染、刷新同步递归 | 面板同步直接接受空快照，枚举由独立刷新入口调度 | 装配调用链复核；空扫描及启动生命周期回归 |
| S2 | App 退出、重开后丢失用户分区 | 从身份台账恢复分配；提交立即更新台账；已确认改名保留分配身份和用户标记；外部图标集合变化后重新安排物理整理 | `userAssignmentSurvivesAbsenceAndRestart`、改名回归；物理整理接线静态复核 |
| S3 | 落点未准备好便消耗恢复次数 | 等待有效扫描和目标位置；等待不计失败；恢复跟随已确认改名；用户新选择可替代旧意图 | `startupWaitsForScanBeforeSpendingReplayAttempts`、`deferredRecoveryFollowsConfirmedRename`、`newUserChoiceSupersedesDeferredRecovery` |
| S4 | 删除 pending 早于保存 committed | 先持久化提交和事务回执，再清理 pending；写失败保留意图；已提交回执防止重复重放；放弃恢复也持久化结果 | `failedCommitKeepsRecoveryIntent`、`completedRecoveryReceiptPreventsDuplicateReplay`、`abandonedRenamedRecoveryDoesNotReappearFromLedger` |
| S5 | 歧义身份匹配接受先到者 | 新旧双方唯一才认领；多候选记录同样参与反向冲突检查 | `conflictingIdentityClaimsAreAllRejected`、IdentityLedger 套件 |
| S6 | 无法复核移动仍标记成功 | 缺少前后位置证据时返回无法验证；原地保持不累计真实拖拽确认 | `unavailableMoveResultIsNotConfirmed`、`samePositionDoesNotPostInputOrConfirmDrag` |
| S7 | 降级后继续调用移动器 | 能力状态约束统一执行入口；正常移动和恢复共用不支持系统的降级处理 | `fallbackStopsCallingUnsupportedMover`、恢复套件 |
| S8 | 所有重分区失败均被吞掉 | 仅缺少合法落点时允许保存面板分配；其他失败保留原布局；拖放、智能推荐、设置和档案菜单贯通真实结果 | `rejectedReassignmentDoesNotBecomeLogicalSuccess`、`overviewDoesNotReportRejectedMovesAsCompleted`；界面调用链复核 |
| B2 | 编辑器没有规则目标，规则不自动执行 | 显式选择图标或档案；拒绝无目标动作；统一 AND 语义；编辑保留身份、优先级和其余动作；刷新、唤醒和分钟定时器触发自动求值 | `targetlessRulesAreRejected`、`ruleEditorKeepsSelectionAndUneditedActions`、规则套件；定时器接线复核 |
| B3 | 始终隐藏与普通隐藏混在一起 | 普通抽屉排除始终隐藏，搜索仍可明确访问；两条独立分隔符控制两种隐藏区；物理整理确认完成后才允许折叠 | `ordinaryDrawerExcludesAlwaysHiddenItems`、`twoDividersKeepIndependentZonesAndLegalLandingSlots`；真实桌面部分见验证边界 |
| B4 | 菜单冻结在首次扫描前 | 每次打开菜单时按最新图标、待确认项、档案和规则重建 | 菜单构造与弹出调用链静态复核 |
| B5 | 自动收起忽略设置和交互 | 抽屉与原地展开共用显隐状态和倒计时；设置实时生效；悬停暂停；可见期间保留抽屉锚点；移除延迟关闭旧呈现的回调 | `autoHideSettingTakesEffectWithoutRestart`、`drawerAndMenuBarShareAutoHidePolicy`；面板接线复核 |
| B6 | 全桌面事件或关闭的触发器仍可呼出 | 鼠标事件先检查菜单栏范围，再节流和检查开关；明确的抽屉命令有独立入口；所有原生鼠标入口忽略自有合成事件 | `pointerTriggersAreRestrictedToTheMenuBar`、`disabledEmptyBarTriggerDoesNotReveal`、`syntheticMouseEventsCannotChangePresentation` |
| B7 | 演示模式退出不能恢复 | 演示为临时显示布局，保留永久分区和原显隐方式；失败时退出演示并反馈原因 | `demoModeRestoresLayoutWithoutPersistingTemporaryChoices`；物理恢复调用链复核 |
| B8 | 档案规则被丢弃或反复重排 | 档案展开成普通变更并遵守单项优先级；按逐步更新的布局生成排序，重复求值收敛；解析历史身份；过滤系统和自有控制项 | `profileRulesApplyOnceAndRespectItemPriority`、`profilePermutationCompletesInOneEvaluation`、`profilesAndRulesExcludeProtectedControls` |
| B9 | 未知 Wi-Fi 状态被当成断开 | 上下文携带状态可用性；使用 CoreWLAN 读取；缺失或被权限隐藏的 SSID 保持未知 | `unavailableWiFiStateIsNotTreatedAsDisconnected`、LiveSystemContext 套件 |

## 复核补充修复

- 恢复失败后，以磁盘中的 pending 判断是否仍在恢复，自动规则与自动整理不能覆盖它；见 `failedRecoveryCannotBeReplacedByAutomaticChanges`。
- 同区且未指定位置的操作保留原顺序，显式位置仍可重排；见 `reassignmentWithoutPositionKeepsExistingOrder`。
- 批量移动等待剩余安全间隔，等待后再次检查用户鼠标输入；见 `consecutiveProfileMovesWaitForTheSafetyInterval`、`userInputDuringCooldownStillAborts`。
- 手动 Cmd 拖拽结束立即使旧扫描结果失效，只用之后的扫描保存用户分区；等待期间，扫描、分钟定时器和规则保存入口统一暂停自动求值；见 `invalidatedScanCannotOverwriteManualChanges` 及装配复核。
- 外部图标变化会使物理布局重新整理。成员比较排除自有分隔符和控制按钮，避免折叠及按钮标题变化触发重复整理。
- 智能推荐遇到失败立即停止后续整理；提示保留已完成项数量，并采用失败图标。档案菜单只在应用成功后记录成功消息。

Standards 和 Spec 两个只读复核均已完成；本轮限定复核无剩余发现。

## 构建与验证

| 检查 | 结果 |
| --- | --- |
| `swift run --quiet tidybar-checks` | 253 条、38 个套件通过 |
| `swift build` | 全部 Debug 目标编译通过，包括自检及探针工具 |
| `./scripts/build-app.sh` | 全部 Release 目标编译和应用组装通过，无编译告警 |
| `.build/release/tidybar-checks` | 最终产物对应的 253 条、38 个套件通过 |
| `codesign --verify --deep --strict --verbose=2 dist/TidyBar.app` | 签名与 Designated Requirement 验证通过 |
| `plutil -lint dist/TidyBar.app/Contents/Info.plist` | 通过 |
| `git diff --check` | 通过 |

应用产物：[dist/TidyBar.app](../../dist/TidyBar.app)，本机 ad-hoc 签名，体积 **1924 KiB**，低于 10 MiB 预算。Release 回归输出见 [fix-checks-release.txt](../../.build/review-20260908/fix-checks-release.txt)。

主可执行文件 SHA-256：

```text
ca7b0a593061ecf3ef68d52dd8ddd2dd89f9875ea962404caad71a7bcf97b76c
```

## 验证边界

- 回归使用隔离目录、系统服务替身和测试进程中的 AppKit 控件。原生事件测试只构造事件对象，不向桌面投递；表单测试不展示窗口。
- 本轮未启动打包应用，也未对用户的真实菜单栏执行拖拽或崩溃实验。两条分隔符的真实折叠、跨 App 移动和多屏表现仍需现场验证；构建及离线回归不能替代该项验证。
- 专注模式、投屏或录屏状态的自动检测尚不可用，规则界面已明确标注。核心求值器仍接受调用方明确提供的状态。
- 辅助功能权限在本次进程启动时决定移动器能力。首次授权后需重启 TidyBar，向导已说明；完整接管仍受机器和系统版本的验证记录约束。
