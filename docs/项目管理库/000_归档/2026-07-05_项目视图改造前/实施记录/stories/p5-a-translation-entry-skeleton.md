---
id: P5-A
title: 翻译入口 Skeleton
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - P5-A 翻译入口 Skeleton
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P5-A 翻译入口 Skeleton

## Scope

本轮只建立翻译入口和确认预览，不调用真实 provider、不读取真实 API key、不执行本地 CLI、不接 OCR、不上传内容。

已实现：

- 新增 `TranslationRequestPreview`，统一表达 manual / screenshot / clipboard 三类来源、目标语言、provider 状态、字符数和 confirmation level。
- 新增 `TranslationHomeView`，主窗口 Translation section 展示手动输入、字符数和确认预览。
- 新增 `TranslationConfirmationCard`，显示外部传输确认预览和 provider 未接入状态。
- 截图结果浮层新增 Translate 按钮；点击只在浮层内展开 screenshot translation preview。
- 剪贴板历史行新增 Translate 按钮；点击只基于 redacted record 摘要生成 preview 并跳转 Translation section。
- 三语 String Catalog 补齐当前可见 P5-A 文案。
- 新增 `tools/verification/p5a_translation_skeleton_checks.py`，验证构建、P4-B 回归、本地化、project refs、截图/剪贴板入口和无 provider/runtime 调用。

## Acceptance Notes

- Given 用户打开 Translation section，Then 能看到手动输入和确认预览卡片。
- Given 用户点击截图结果浮层 Translate，Then 只显示来源摘要和 confirmation preview，不调用 OCR/provider。
- Given 用户点击剪贴板历史行 Translate，Then 只用 redacted 摘要、短哈希和类型信息生成 preview，不读取完整剪贴板内容。
- Given provider 未配置，Then 确认按钮处于不可执行状态。

## Privacy And Safety

- P5-A 不包含 `URLSession`、provider SDK、本地 CLI 执行、真实 API key 或网络调用。
- 截图来源只传递尺寸、mode 和摘要，不传图片 bytes。
- 剪贴板来源只传递 redacted record 字段，不读取真实 `NSPasteboard`。
- 外部传输仍必须走 `external_transfer` confirmation；本轮只展示 preview，不执行。

## Not Covered Yet

- OCR、真实文本抽取、语言检测、provider 设置、BYOK、Codex/Claude CLI 调用、翻译结果面板和失败重试。
- 截图结果中的 OCR 翻译、剪贴板完整内容翻译和 agent action 调用。

## Verification

已执行并通过：

- `python3 tools/verification/p5a_translation_skeleton_checks.py --timeout 180`
- `python3 tools/verification/p4b_clipboard_panel_checks.py --timeout 180`
- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `/Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- project Markdown local link check
- `git diff --check`
- sensitive content scan
