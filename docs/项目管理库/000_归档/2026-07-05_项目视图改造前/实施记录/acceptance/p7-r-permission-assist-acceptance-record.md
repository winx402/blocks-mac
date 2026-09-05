# P7-R Permission Assist 验收记录

日期：2026-07-03
状态：`granted-state passed; revoked-flow not covered`
运行 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`
Bundle ID：`com.jdtool.app`

## 当前 TCC 状态

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Stable Apple Development signing | `passed` | `./script/build_and_run.sh --verify-permissions-existing` 输出 Team ID `LOCAL_TEAM_ID_REDACTED`，Authority 为 Apple Development。 |
| Screen Recording TCC | `passed` | TCC row `kTCCServiceScreenCapture | com.jdtool.app | 2`，当前 App 可识别授权。 |
| Accessibility TCC | `passed` | TCC row `kTCCServiceAccessibility | com.jdtool.app | 2`，Clipboard 自动粘贴核心路径已在 P7-O 通过。 |

## Permission Assist 验收

| 项目 | 结果 | 实际观察 / 门禁 |
| --- | --- | --- |
| Granted close condition | `passed` | 当前权限已 granted；产品逻辑命中 `session.kind.isGranted` 后关闭辅助流程，避免已授权状态仍弹出拖拽面板遮挡用户。 |
| State machine shape | `passed` | 代码保留 `openingSystemSettings -> waitingForSettingsWindow -> guiding -> checkingPermission -> granted / failed / cancelled / timedOut`。 |
| System Settings wait/fallback | `passed_static_gate` | Presenter 使用 `settingsLaunchGraceSeconds`、`settingsWindowFallbackSeconds` 和 `SystemSettingsWindowLocator.visibleWindowFrame()`；窗口不可定位时显示 fallback，而不是静默消失。 |
| Arrow placement | `passed_static_gate` | 面板根据 System Settings 窗口左右空间设置 `.left` / `.right` 箭头方向，箭头指向权限列表方向。 |
| Drag isolation | `passed_static_gate` | `panel.isMovableByWindowBackground = false`；App 图标区域只发 file URL drag，不移动整个面板。 |
| Close conditions | `passed_static_gate` | 关闭条件覆盖 permission granted、System Settings closed、user close、timeout 和 flow replacement。 |

## 尚未覆盖

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| Revoked Screen Recording guide | `not_covered_policy` | 当前 Screen Recording 已 granted；本轮不使用 `tccutil reset` 或修改 TCC，所以不能自然进入未授权引导分支。 |
| Revoked Accessibility guide | `not_covered_policy` | 当前 Accessibility 已 granted；本轮不撤销系统授权。 |
| Real arrow-to-System-Settings visual pass under revoked TCC | `not_covered_environment` | 需要未授权状态或新 bundle id 才能自然显示完整 guide；当前 granted-state 会按设计关闭。 |

## 结论

P7-R 关闭“当前已授权状态下 Permission Assist 是否会继续遮挡/卡住用户”的风险；完整 revoked-flow 交互仍按环境依赖项保留。后续若需要彻底验证 revoked-flow，应在单独机器、临时 bundle id 或手动撤销权限后执行，不能在当前已授权状态下伪造通过。
