# P7-P Alpha Readiness Closure 验收记录

日期：2026-07-03
状态：`superseded by P7-Q / P7-R / P7-S for final alpha baseline`
运行 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`
Bundle ID：`com.jdtool.app`

## 验收结论

P7-P 不重复 P7-O 的 TCC reset 操作。本轮目标是把 P7-O 已经通过的稳定签名、Screen Recording、Accessibility、Clipboard 自动粘贴和 Translation 快捷浮层事实固化到门禁和文档。P7-P 当时保留了 Permission Assist 目标页体验、Screenshot Window / Fullscreen UI 为显式未覆盖项；这些项后续分别由 P7-Q / P7-R / P7-S 继续收敛。

## 已通过

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Stable App path | `passed` | `script/build_and_run.sh` 固定使用 `~/Applications/JDToolDev/Debug/JDTool.app`，P7-P gate 会检查 existing stable app 模式。 |
| Existing TCC gate | `passed` | `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing` 是 P7-P 自动门禁的一部分；不执行 `tccutil reset`。 |
| P7-O core facts | `passed` | P7-O 已记录 Screen Recording / Accessibility 均能被当前稳定 App 识别，Clipboard Return / 双击自动粘贴通过，Region 截图通过，Translation `Control + Option + D` 通过。 |
| Shortcut default docs | `passed` | P7-N/L/M 和入口文档同步为 `Control + Option + A/V/D`，不再把 Option-only 写成当前可靠默认。 |
| Permission Assist state machine shape | `passed` | Permission Assist 保留 `openingSystemSettings -> waitingForSettingsWindow -> guiding -> checkingPermission -> granted / failed / cancelled / timedOut` 状态，并补充等待 System Settings 窗口后再展示辅助面板的 gate。 |
| Screenshot mode code paths | `passed` | Window mode 仍走 hover overlay / Esc cancel / no-candidate error；Fullscreen mode 仍走当前鼠标 display、主 display、第一个 display fallback。 |

## P7-P 当时尚未覆盖，后续状态

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| Permission Assist 目标页定位、箭头方向和关闭时机真实体验 | `closed_by_p7r_for_granted_state` | P7-R 已确认当前 granted-state 会关闭辅助流程，不遮挡用户；revoked-flow 指引仍需撤销权限或新 bundle id 环境复测。 |
| Screenshot Window UI 点击验收 | `closed_by_p7q` | P7-Q 已真实触发 Window overlay、hover 高亮、Esc 取消和候选窗口点击捕获。 |
| Screenshot Fullscreen UI 点击验收 | `closed_by_p7q` | P7-Q 已真实触发 fullscreen capture 并确认结果浮层。 |
| 多屏、权限撤销/重授权 | `not_covered_environment` | 当前机器/当前授权状态未覆盖这些环境依赖场景；不伪造通过。 |

## 下一步

1. 以 [P7-S Alpha Readiness Final Record](p7-s-alpha-readiness-final-record.md) 作为当前 Alpha 前基线。
2. 后续单独复测 Permission Assist revoked-flow、多屏和权限撤销/重授权。
3. 下一阶段进入 P8-A Alpha Packaging / Tester Readiness 规划。
