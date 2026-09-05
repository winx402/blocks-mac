# P7-R Permission Assist Validation

状态：implemented / granted-state pass recorded / revoked-flow retained

## Scope

P7-R 只收敛 P7-P 留下的 Permission Assist 验收缺口：当前已授权状态下的关闭条件、状态机、System Settings 定位策略、箭头方向和拖拽隔离门禁。它不重置 TCC，不修改系统隐私数据库，不新增权限功能。

## Current Runtime Constraint

当前稳定 App 的 Screen Recording 和 Accessibility 均已 granted。按产品设计，Permission Assist 在 `session.kind.isGranted` 时会进入 granted close condition 并收起，因此本轮无法在不撤销权限的情况下真实观察完整拖拽引导流程。

## Changes

- 固化 Permission Assist 状态机和关闭条件为 P7-R 门禁。
- 明确 granted-state 验收：权限已 granted 时不继续遮挡用户，而是关闭辅助流程并刷新 permission snapshot。
- 将 revoked-flow 的 System Settings 目标页、面板相对定位、箭头方向和拖拽 App 图标保留为环境依赖复测，而不是写成已完整通过。
- 更新 Alpha readiness 文档，避免把 P7-P 的 Permission Assist 目标页体验继续写成当前唯一阻塞。

## Acceptance

- Permission Assist state machine includes `openingSystemSettings`、`waitingForSettingsWindow`、`guiding`、`checkingPermission`、`granted`、`failed`、`cancelled`、`timedOut`.
- Permission Assist waits for a visible System Settings window before showing the guiding panel, with fallback after timeout.
- The panel arrow direction follows the System Settings relative position.
- Dragging the App icon uses file URL drag and does not move the whole panel.
- The flow closes on granted permission, System Settings close, user close, timeout, or replacement by another permission flow.
- Revoked permission guide remains explicitly `not_covered` in this run because current TCC is granted and this pass does not reset TCC.

## Verification

- `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing`
- `python3 tools/verification/p7r_permission_assist_ux_checks.py --timeout 180`
- Manual/runtime result is recorded in [P7-R acceptance record](../acceptance/p7-r-permission-assist-acceptance-record.md).
