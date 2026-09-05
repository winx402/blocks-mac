# P7-P Alpha Readiness Closure

状态：implemented / superseded by P7-Q/P7-R/P7-S final baseline

## Scope

P7-P 基于 [P7-O 真实权限与交互验收记录](../acceptance/p7-o-real-permission-interaction-acceptance-record.md) 收敛 Alpha 前剩余缺口：Permission Assist 状态机可验收性、Window / Fullscreen 截图模式补验入口、P7-N/L/M stale 文档修正和新的 Alpha readiness closure gate。后续 [P7-Q](p7-q-screenshot-window-fullscreen-validation.md)、[P7-R](p7-r-permission-assist-validation.md) 和 [P7-S](p7-s-alpha-readiness-final.md) 已补充最终状态。

本轮不新增 OCR runtime、真实 provider、长期 Login Item、完整剪贴板内容恢复或新的工具能力。

## Changes

- Permission Assist 不再在打开权限流程后立即弹出完整辅助面板；优先等待 System Settings 窗口出现，超过等待窗口后才显示等待/失败辅助面板。
- Permission Assist 关闭条件明确为 granted、System Settings 关闭、用户关闭、超时或流程替换；拖拽 App 图标仍只拖 file URL，不移动面板。
- 新增 `tools/verification/p7p_alpha_readiness_closure_checks.py`，检查稳定 App 路径、existing TCC gate、P7-O 事实、Permission Assist 状态机、Window / Fullscreen 路径和 P7-N/L/M stale 文案清理。
- P7-N / P7-L / P7-M 更新为当前事实：稳定 App 的 Screen Recording / Accessibility 已通过，默认真实快捷键为 `Control + Option + A/V/D`，Clipboard 和 Translation 核心路径已在 P7-O 实测通过。

## Acceptance

- Stable signed app path and existing TCC gate pass without using `tccutil reset`.
- P7-N/L/M no longer say Screen Recording is blocked, Option-only is the current default, or Clipboard / Translation shortcuts are still unverified.
- Permission Assist state-machine behavior is statically gated; P7-R 已关闭 granted-state 风险，并保留 revoked-flow 为环境依赖项。
- Screenshot Region remains covered by P7-O; Window / Fullscreen 已由 P7-Q 真实点击验收通过。

## Verification

- `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing`
- `python3 tools/verification/p7p_alpha_readiness_closure_checks.py --timeout 180`
- `python3 tools/verification/p7h_stable_signing_permission_identity_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- Markdown local link check、`git diff --check`、sensitive token scan。

## Notes

- P7-O 曾用一次针对 `com.jdtool.app` 的 ScreenCapture TCC reset 清理旧 cdhash 绑定；P7-P 不再使用 reset，也不把 reset 写入产品流程。
- P7-Q/P7-R/P7-S 是 P7-P 的后续收口；当前 Alpha 前基线以 P7-S 记录为准。
