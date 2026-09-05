---
id: P4-A
title: 剪贴板 Recorder Foundation
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - P4-A 剪贴板 Recorder Foundation
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P4-A 剪贴板 Recorder Foundation

## Scope

本轮只把剪贴板 recorder 的基础数据和 helper 承载边界放进正式工程，不实现完整历史 UI、不注册 Login Item、不长期轮询、不读取真实剪贴板、不调用 AI/provider。

已实现：

- `JDToolCore` 新增剪贴板 recorder redacted model：kind、format summary、source app candidate、policy、pinned、restorable、excluded、snapshot skipped 和 short signature。
- `JDToolCore` 新增低敏 fixture store document，P4-A 初始 schema version 为 `0.1.0`；P4-E 已向后兼容升级到 `0.2.0`。
- `JDToolLoginItemHelper` 链接 `JDToolCore`，新增显式 `--recorder-fixture` debug path。
- Debug fixture 只写 redacted metadata；sandbox helper 默认写自身 Application Support 路径，不读取真实剪贴板，也不写 fixture 原文。
- 新增 `tools/verification/p4a_clipboard_recorder_checks.py`，验证构建、helper fixture、schema、record count、排除项和仓库 runtime store 的 ignore 保护。
- `.gitignore` 增加 `apps/JDTool/RuntimeClipboardRecorder/`，为后续非 sandbox debug/export 产物提供提交保护。

## Acceptance Notes

- Given helper 以 `--recorder-fixture --store-name p4a-fixture --reset` 启动，Then 输出 JSON `ok=true`。
- Given fixture store 写入完成，Then store 包含 5 条 redacted records，其中 4 条 restorable fixture、1 条 excluded / snapshot skipped。
- Given sandbox helper 写入 fixture store，Then 输出只暴露 schema、文件名、数量和安全计数，不暴露完整路径、fixture 原文、URL 原值或图片 base64。
- Given 后续 debug/export 需要写 `apps/JDTool/RuntimeClipboardRecorder/`，Then 该路径已被 git ignore。
- Given helper 没有显式 `--recorder-fixture` 参数，Then 仍保持原 stub heartbeat 行为并自动退出。

## Privacy And Safety

- 不读取真实剪贴板内容。
- 不保存真实剪贴板原文、RTF、图片 base64、URL 原值、真实文件路径、secret 或 provider 输出。
- `source_app` 仍只是候选信号，不写成可靠历史来源。
- Helper 不注册 Login Item，不常驻，不执行 hook，不调用外部 CLI/provider。

## Not Covered Yet

- 真正后台 recorder 轮询、去重、过期清理、固定保留和恢复写回迁入正式 App。
- 历史面板 UI、搜索、固定/分组、暂停记录和隐私排除设置。
- 第三方复杂剪贴板样本、长期 helper 功耗、App Store 审核边界。

## Verification

已执行并通过：

- `python3 tools/verification/p4a_clipboard_recorder_checks.py --timeout 180`
- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`
- `python3 -m py_compile tools/verification/p3c_screenshot_checks.py tools/verification/p4a_clipboard_recorder_checks.py`
- project Markdown local link check
- `git diff --check`
- sensitive content scan
