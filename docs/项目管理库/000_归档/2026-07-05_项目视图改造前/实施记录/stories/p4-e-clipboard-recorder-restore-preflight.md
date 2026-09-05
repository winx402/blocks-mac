---
id: P4-E
title: 剪贴板 Recorder Preflight 与低敏恢复写回
status: implemented
date: 2026-07-02
sourcePlan: P4-E 剪贴板 Recorder Preflight / Restore Debug Plan
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P4-E 剪贴板 Recorder Preflight 与低敏恢复写回

## Scope

本轮在 P4-D 的受控真实 recorder debug path 上补齐共享存储预检、低敏 fixture payload 模型和 fixture 恢复写回。它仍不是长期剪贴板 recorder，不注册 Login Item，不保存真实用户剪贴板原文，不启用 App Group entitlement。

已实现：

- `ClipboardRecorderStoreDocument` 升级到 `schema_version=0.2.0`，兼容旧 store，新增可选 `payloads` map。
- `ClipboardRecorderFixture` 增加低敏 fixture payload，只覆盖 text、rich text、image、URL。
- `JDToolLoginItemHelper` 增加 `--recorder-preflight`，输出 sandbox backend、App Group 可写性和 workspace store 边界。
- `JDToolLoginItemHelper` 扩展 `--recorder-fixture --include-restorable-payloads`，只为低敏 fixture 写入 payload。
- `JDToolLoginItemHelper` 增加 `--recorder-restore --record-id <id>`，只允许 `fixture_owned=true && restorable=true && payload exists` 的记录恢复写回 pasteboard。
- Settings 增加 Clipboard Recorder Diagnostics，只读展示 debug-only、App Group 未启用、长期 recorder 未启用和仅恢复 fixture payload 的边界。
- 新增 `tools/verification/p4e_clipboard_recorder_restore_preflight_checks.py`。

## Acceptance Notes

- Given helper 运行 `--recorder-preflight`，Then 输出 `backend=sandbox_application_support`，且 `app_group_entitlement_enabled=false`。
- Given helper 写入 `p4e-restore` fixture store 并启用 payload，Then report 显示 `payload_count=4`，但输出不包含 fixture 原文、URL 原值或 base64。
- Given helper restore text / rich text / image / URL fixture，Then pasteboard changeCount 更新，输出只包含 kind、长度/字节数、短哈希和 changeCount。
- Given helper restore excluded record，Then 返回 `record_not_restorable`。
- Given helper restore missing record，Then 返回 `record_not_found`。
- Given inspect store，Then inspect report 不暴露 `payloads`。

## Privacy And Safety

- P4-E 会短暂覆盖当前剪贴板来恢复低敏 fixture；不保存用户原剪贴板用于恢复。
- 真实 watch 事件仍为 `fixture_owned=false`、`restorable=false`，不会写 payload。
- Payload 只存在于 helper sandbox debug store，且只用于低敏 fixture；不会进入 helper JSON report、UI 摘要、日志或仓库。
- App Group 共享容器只做 preflight 记录；本地 `Sign to Run Locally` 不启用 App Group entitlement，以避免 provisioning profile 阻塞。

## Not Covered Yet

- 长期 Login Item recorder、功耗、崩溃恢复和用户撤销路径。
- 正式 App / helper 共享容器和 App Group entitlement 的开发签名复测。
- 真实用户剪贴板内容的可恢复保存、隐私排除设置页、复杂第三方样本和完整格式恢复策略。

## Verification

已执行并通过：

- `python3 tools/verification/p4e_clipboard_recorder_restore_preflight_checks.py --timeout 180`

全链路回归见本轮提交记录。
