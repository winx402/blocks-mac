---
id: P7-A
title: 低敏人工验收与 UI Readiness Gate
status: implemented
date: 2026-07-03
sourcePlan: P7-A 低敏人工验收与 UI Readiness Gate
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../acceptance/p7-a-low-sensitive-acceptance-record.md
  - ../../../../../apps/JDTool/README.md
---

# P7-A 低敏人工验收与 UI Readiness Gate

## Scope

本轮把 P6-C / P4-K / P5-Q / P3-F 合并为进入 Alpha 前的低敏 UI readiness gate。P7-A 不新增产品能力，只建立自动化回归、低敏人工验收清单和未覆盖项记录。

已实现：

- 新增 P7-A 验收记录，按 Shortcut、Screenshot、Clipboard、Translation、Privacy and safety 分组。
- 新增 `tools/verification/p7a_low_sensitive_acceptance_gate_checks.py`，统一构建 JDTool，并串联 P6-C、P4-K、P5-Q、P3-F 验证脚本。
- 验收记录明确区分 `passed`、`pending_low_sensitive_manual_acceptance`、`not_covered` 和 `blocked`，要求所有未覆盖项写明原因。
- 看板和索引同步到 P7-A 状态，下一步转向低敏人工点击验收结果收敛、长期 recorder/helper 策略和 Alpha 前 UI 可用性打磨。

## Acceptance Notes

- Given 自动化执行 P7-A gate，Then App 构建、P6-C、P4-K、P5-Q 和 P3-F 回归必须返回结构化结果。
- Given 真实快捷键触发需要当前输入焦点和系统状态，Then 验收记录不能把未执行的 Option+A、Option+V 或 Option+D 写成通过。
- Given 真实截图涉及当前屏幕内容，Then Region / Window / Fullscreen 的人工验收只能在低敏屏幕环境记录结果。
- Given 剪贴板和翻译浮层涉及系统剪贴板，Then 只允许使用低敏样本，例如 `jdtool low sensitive sample`。
- Given 截图 AI route-ready 入口，Then 只能记录 preview / route 状态，不执行 OCR、不上传图片、不调用 provider。

## Privacy And Safety

- P7-A 不调用真实 provider，不执行本地 CLI provider，不读取环境变量。
- P7-A 不保存真实截图、真实剪贴板原文、provider 原始输出、认证 header、证书或支付配置。
- P7-A 不注册长期 Login Item，不启用 App Group，不开放真实用户内容恢复。
- P7-A 的自动化只能证明 wiring、文档门禁和静态边界；真实 UI 行为必须在低敏人工验收中单独记录。

## Not Covered Yet

- 真实 `Option+A`、`Option+V`、`Option+D` 按键触发结果。
- 真实 Region / Window / Fullscreen 截图点击路径。
- 多屏、跨屏、权限撤销/重授权、系统快捷键冲突和输入焦点异常。
- 真实复杂第三方剪贴板样本、长期 helper 功耗、App Group/provisioning 共享容器正式落地。
- 真实 OCR、截图图片外发、剪贴板历史完整内容外发和 hook runtime。

## Verification

需要执行的验证：

- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `./script/build_and_run.sh --verify`
- `python3 tools/verification/p7a_low_sensitive_acceptance_gate_checks.py --timeout 180`
- `python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py --timeout 180`
- `python3 tools/verification/p4k_clipboard_recorder_policy_checks.py --timeout 180`
- `python3 tools/verification/p5q_translation_language_error_ux_checks.py --timeout 180`
- `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`

低敏人工验收结果写入 [P7-A acceptance record](../acceptance/p7-a-low-sensitive-acceptance-record.md)，未执行项必须保持 `pending_low_sensitive_manual_acceptance` 或 `not_covered`，不伪造通过。
