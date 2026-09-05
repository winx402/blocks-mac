# P4-G 剪贴板长期 Recorder Debug Session

状态：implemented
日期：2026-07-02
来源级别：implementation record

## Summary

本轮在 P4-F runtime gate 上增加显式长期 debug session：主 App 可以启动最长 5 分钟的 helper redacted recorder、停止 session、导入已 flush 的脱敏摘要，并显示 App Group candidate preflight 状态。它仍不是开机常驻 Login Item recorder，不启用 App Group entitlement，不保存真实剪贴板原文，也不开放真实用户内容恢复。

## Implemented

- Clipboard 面板新增 Recorder Session Gate：
  - Session 时长选择，范围 15 到 300 秒。
  - Start Redacted Recorder。
  - Stop Recorder。
  - session 状态：running、stopped、completed、blocked。
  - App Group candidate 状态展示。
- `ClipboardRecorderRuntimeService` 新增 session 管理：
  - 同一时间只允许一个 helper recorder session。
  - start 后不等待 helper 完成。
  - stop 时终止 helper 并 inspect redacted store。
- `JDToolLoginItemHelper --recorder-watch` 新增 debug 参数：
  - `--long-session`：最长允许 300 秒。
  - `--flush-each-event`：每次事件立刻写入 redacted store。
  - `--poll-interval-ms`：显式轮询间隔。
- preflight 新增 `app_group_candidate_status`：
  - 当前 ad hoc signing / no development team 下为 `not_configured_for_app_group`。
  - 不把 App Group 未启用当作 P4-G 失败。
- 新增 `p4g_clipboard_long_recorder_checks.py`：
  - 验证 helper session 在 fixture 事件后仍保持运行。
  - 验证 stop/terminate 前已经 flush redacted record。
  - 验证 exclude-frontmost 不读取 snapshot types。
  - 验证 App Group entitlement 仍未启用。
  - 验证三语 String Catalog 和 App 侧 session symbols。

## Boundaries

- P4-G 不注册 SMAppService Login Item，不验证开机自启或长期功耗。
- P4-G 不启用 App Group entitlement；共享容器仍需开发签名 / provisioning 决策后复测。
- 真实 watch 事件仍 `fixture_owned=false`、`restorable=false`，不写 payload。
- 主 App 不直接读取 `NSPasteboard`；系统剪贴板读取仍只发生在显式 helper debug session 内。
- Provider、翻译、hook、自动粘贴和真实内容恢复不在本轮范围。

## Verification

- `python3 tools/verification/p4g_clipboard_long_recorder_checks.py --timeout 180`
- `python3 tools/verification/p4f_clipboard_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p4e_clipboard_recorder_restore_preflight_checks.py --timeout 180`
- `python3 tools/verification/p4d_clipboard_real_recorder_debug_checks.py --timeout 180`
- `python3 tools/verification/p4b_clipboard_panel_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`

完整回归结果以本轮提交前命令输出为准。
