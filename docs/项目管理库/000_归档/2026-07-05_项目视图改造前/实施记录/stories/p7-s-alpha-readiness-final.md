# P7-S Alpha Readiness Final

状态：implemented / alpha readiness baseline updated

## Scope

P7-S 汇总 P7-O、P7-P、P7-Q 和 P7-R 的结果，形成 Alpha 前当前可交付基线。它不新增产品功能，不进入真实 provider/OCR runtime，不做 packaging/notarization。

## Changes

- 将 Screenshot Window / Fullscreen 从 P7-P 未覆盖项推进为 P7-Q `passed`。
- 将 Permission Assist 从“目标页体验未覆盖”收敛为：当前 granted-state 通过；revoked-flow 指引仍是环境依赖复测项。
- 更新 README、App README、项目管理库索引、项目总览、项目看板和 docs index，避免入口文档继续说 Window / Fullscreen 未点击。
- 新增 P7-S final gate，串联 P7-P、P7-Q、P7-R 状态并检查 stale 文案。

## Alpha Readiness Position

当前状态可以进入 Alpha 前的体验缺陷修复 / 打包准备规划，但不等于可发布 Beta：

- 已通过：稳定签名、Screen Recording、Accessibility、Region / Window / Fullscreen 截图、Clipboard 自动粘贴核心路径、Translation 快捷浮层、P7 主要自动门禁。
- 仍需后续：多屏、权限撤销/重授权、Permission Assist revoked-flow、真实 OCR/provider runtime、长期 Login Item recorder、App Group/provisioning、第三方复杂剪贴板样本、packaging/notarization。

## Verification

- `python3 tools/verification/p7s_alpha_readiness_final_checks.py --timeout 180`
- `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py --timeout 180`
- `python3 tools/verification/p7r_permission_assist_ux_checks.py --timeout 180`
- Existing P7-P / P7-H / P2 smoke gates remain part of final verification.

## Next Recommended Stage: P8-A Alpha Packaging / Tester Readiness

P8-A Alpha Packaging / Tester Readiness should focus on packaging/notarization strategy, tester install flow, crash/log collection boundary, and a curated Alpha bug backlog. Product feature expansion should wait until the current Alpha baseline is stable.
