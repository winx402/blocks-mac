---
id: P4-B
title: 剪贴板历史最小面板
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - P4-B 剪贴板历史最小面板
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P4-B 剪贴板历史最小面板

## Scope

本轮把 P4-A 的 redacted recorder model 接到正式 App 的主窗口和菜单栏，形成最小剪贴板历史面板。不读取真实剪贴板、不启动长期 helper、不实现完整分组/恢复/AI 操作。

已实现：

- 主窗口从固定截图详情改为 `AppSection` 导航：截图、剪贴板、翻译、设置。
- `ScreenshotHomeView` 承接原截图详情，保留 P3-B/P3-C 的区域、窗口和全屏入口。
- `ClipboardHistoryView` 展示 redacted fixture records：搜索框、暂停/继续记录、列表摘要、固定标记、可恢复标记、排除 App 状态、snapshot skipped 状态。
- 菜单栏 Clipboard 会打开主窗口并选中剪贴板面板；Pause Recorder 只切换内存态暂停状态。
- Translation 保留结构化占位入口，不调用 provider，不触发 external transfer。
- 新增三语 String Catalog 文案，覆盖当前可见 P4-B UI。
- 新增 `tools/verification/p4b_clipboard_panel_checks.py`，验证构建、本地化 key、project refs、P4-A fixture 回归和 P4-B 面板不读取真实 NSPasteboard。

## Acceptance Notes

- Given 用户从菜单栏点击 Clipboard，Then 主窗口打开并显示剪贴板历史面板。
- Given 面板加载默认 fixture，Then 只展示摘要、来源候选、类型数量、短哈希和状态 badge。
- Given 用户输入搜索词，Then 列表基于摘要、来源候选、类型和 kind 过滤。
- Given 用户点击 Pause/Resume，Then 只切换本次运行内存态状态，不注册 Login Item、不启动长期 recorder。
- Given 排除项 fixture 存在，Then 列表显示 excluded / skipped 状态，不显示内容快照。

## Privacy And Safety

- P4-B 面板不导入或调用 `NSPasteboard`。
- 真实用户剪贴板仍不会被读取、写入日志或保存到仓库。
- 当前 records 来自低敏 fixture / redacted model；不包含原文、图片 base64、真实 URL、真实文件路径或 secret。
- Agent / CLI 仍不能读取完整剪贴板内容；后续完整内容读取必须走 `preview` 确认。

## Not Covered Yet

- 真正后台 recorder 轮询、去重、过期清理、固定保留、恢复写回和真实排除 App 设置。
- 完整分组 UI、详情预览、格式恢复、自动粘贴和 AI 处理。
- 长期 helper 功耗、复杂第三方剪贴板样本和 App Store 审核边界。

## Verification

已执行并通过：

- `python3 tools/verification/p4b_clipboard_panel_checks.py --timeout 180`
- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `/Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- project Markdown local link check
- `git diff --check`
- sensitive content scan
