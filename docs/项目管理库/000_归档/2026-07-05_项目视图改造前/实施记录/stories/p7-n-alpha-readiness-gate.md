# P7-N 验收脚本与 Alpha Readiness

状态：implemented / stable-signing-and-core-tcc-passed / superseded by P7-S final baseline

## Scope

P7-N 汇总 P7-K/L/M 的自动检查和 P7-A 低敏人工验收入口。它不新增功能，只建立 Alpha 前的串行门禁。

## Changes

- 新增 `tools/verification/p7n_alpha_readiness_gate_checks.py`，按顺序运行构建、P7-K、P7-L、P7-M、P7-A 和 P2 action smoke。
- Gate 明确串行执行，不并发写同一 `DerivedData/JDTool`。
- 当前 Alpha readiness 的稳定签名和核心 TCC 门禁已通过：`--verify-permissions` 使用 Apple Development 签名并运行成功；P7-O 真实验收后，Screen Recording 与 Accessibility 均能被当前稳定 App 识别。默认真实快捷键已迁移为 `Control + Option + A/V/D`，Clipboard / Translation 浮层和 Region 截图主链路已实测通过。后续 P7-Q 已关闭 Window / Fullscreen UI 点击验收，P7-R 已关闭 Permission Assist granted-state 风险，P7-S 已形成最终 Alpha readiness baseline；多屏、Permission Assist revoked-flow 和撤销重授权继续作为环境依赖项。

## Verification

- `python3 tools/verification/p7n_alpha_readiness_gate_checks.py --timeout 180`
- `git diff --check`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

## Readiness Rule

- 自动化通过且 P7-S final baseline 完成后，才可进入 P8-A Alpha Packaging / Tester Readiness。
- 若后续 `--verify-permissions` 再次因证书信任异常失败，Alpha readiness 退回 `partial / blocked-by-local-signing`；当前状态是 core TCC paths passed，Region / Window / Fullscreen mode checks 已通过。
