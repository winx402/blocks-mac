# P4-F 剪贴板 Recorder Runtime Gate

状态：implemented
日期：2026-07-02
来源级别：implementation record

## Summary

本轮把剪贴板 recorder 从纯 helper debug command 推进到正式 App 的受控 runtime gate：主 App 可以显式运行 preflight、短时 redacted watch、导入 helper 返回的脱敏摘要，并重置 P4-F debug store。它仍不是长期 Login Item recorder，不启用 App Group，不保存真实剪贴板原文，也不开放真实用户内容恢复。

## Implemented

- Clipboard 面板新增 Recorder Runtime Gate：
  - Run Preflight。
  - Run 10s Redacted Watch。
  - Import Debug Store。
  - Reset Debug Store。
  - exclude frontmost app snapshot 开关。
- App 侧新增 `ClipboardRecorderRuntimeService`：
  - 只启动内嵌 `JDToolLoginItemHelper` 的显式 debug commands。
  - 通过 helper JSON 输出导入 redacted records。
  - 不直接读取 `NSPasteboard`。
- AppState 新增 recorder runtime state：
  - `disabled`、`preflightOnly`、`debugWatchAvailable`、`blocked`。
  - 展示 backend、App Group 可写状态和最近一次运行摘要。
- P4-F 验证脚本覆盖：
  - helper preflight。
  - redacted watch。
  - exclude-frontmost。
  - App Group entitlement 未启用。
  - workspace runtime store ignored。
  - 三语 String Catalog。

## Boundaries

- P4-F 不注册 SMAppService Login Item，不长期常驻，不验证功耗。
- P4-F 不启用 App Group entitlement；当前 backend 仍是 sandbox Application Support fallback。
- 真实 watch 事件仍 `fixture_owned=false`、`restorable=false`，不写 payload。
- P4-E 的低敏 fixture restore 能力不扩展到真实用户内容。
- Provider、翻译、hook 和自动粘贴不在本轮范围。

## Verification

- `python3 tools/verification/p4f_clipboard_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p4e_clipboard_recorder_restore_preflight_checks.py --timeout 180`
- `python3 tools/verification/p4d_clipboard_real_recorder_debug_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`

完整回归结果以本轮提交前命令输出为准。
