# P7-K 稳定签名、权限闭环与 Permission Assist

状态：implemented / stable-signing-verified / core TCC paths passed

## Scope

P7-K 只处理 Alpha 前的权限身份门禁，不新增 OCR、provider、长期 Login Item 或真实剪贴板恢复。

## Changes

- `script/build_and_run.sh` 新增 `--verify-permissions`，该模式强制 Apple Development 稳定签名；证书缺失、Team ID 无法解析或证书信任异常时直接失败。
- 权限诊断继续展示当前 App path、Bundle ID、signature kind、Team ID、usage description 和 identity issue。
- Permission Assist 使用显式状态机，打开系统设置后跨空间展示辅助面板；找不到 System Settings 窗口时显示 fallback 文案而不是静默消失。
- Screen Recording 请求路径保留 `CGRequestScreenCaptureAccess()`；Accessibility 请求路径保留 `AXIsProcessTrustedWithOptions(prompt: true)`。

## Current Local Finding

本机存在 Apple Development 身份；P7-K 后已移除该证书的用户自定义 `Trust As Root` trust settings，并恢复系统默认信任。`./script/build_and_run.sh --verify-permissions` 与 `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing` 已通过，当前 App 使用 Apple Development 签名，Team ID 为 `LOCAL_TEAM_ID_REDACTED`。P7-O 真实验收已确认 Screen Recording 和 Accessibility 都能授权并被当前稳定 App 识别；`Control + Option + A` 已完成一次真实区域截图，Clipboard 自动粘贴已在 TextEdit 中通过 Return 和双击两条路径。

## Verification

- `python3 tools/verification/p7k_permission_identity_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify-permissions`

## Manual Acceptance

- Screen Recording：使用稳定签名 App 请求授权，点击“我已完成”后 preflight 变为 granted；若仍失败，必须显示 signing/path 诊断。
- Accessibility：权限页主动请求授权；授权后自动粘贴前 AX 状态刷新为 granted。
- Permission Assist：System Settings 可见后出现辅助面板；窗口定位失败时 fallback 面板仍可见；关闭、超时和授权完成能收起。
