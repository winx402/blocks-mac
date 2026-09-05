# P4-K Clipboard Recorder Policy Foundation

状态：implemented
日期：2026-07-03
来源：P7 前剪贴板 recorder 深化

## 目标

把剪贴板历史从“可查看 redacted summaries”推进到可配置基础保存策略：

- 支持 retention days。
- 支持 max items。
- 支持 pinned 条目在清理时保留。
- 支持 excluded bundle IDs 命中后把本地摘要标记为 excluded / snapshot skipped。
- 支持一键清除未固定摘要。

## 实现范围

- `AppState.applyClipboardPolicy` 只处理 App 内当前 `clipboardRecords`。
- `SettingsView` 增加 Clipboard Policy 设置。
- `ClipboardHistoryView` 增加策略摘要、Apply Policy 和 Clear Unpinned。
- 本轮只操作 redacted metadata，不读取真实剪贴板原文、不恢复真实用户内容。

## 边界

- 不读取 `NSPasteboard.general`。
- 不保存真实用户剪贴板正文、RTF、图片 base64、URL 原值或真实文件路径。
- 不调用 provider，不执行 CLI，不注册长期 Login Item。

## 验证

- `python3 tools/verification/p4k_clipboard_recorder_policy_checks.py --timeout 180`
- 回归 `P4-J` Paste 风格浮层。
