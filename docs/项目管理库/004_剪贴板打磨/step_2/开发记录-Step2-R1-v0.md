# 004_剪贴板打磨 Step 2 返工开发记录 R1 v0

日期：2026-07-07
角色：开发
范围：仅处理 Step 2 标签 / 收藏模型开发复审后的返工；未进入 Step 3/4/5。

## 改动范围

- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
  - `markSearchDocumentTagsDirty(recordIDs:)` 在 search document 缺失时不再静默跳过，会按当前 record + 当前 `clipboard_record_tags` / `clipboard_tags` 关联重建 search document。
  - `rebuildSearchDocuments(limit:)` 重建缺失 search document 时写入当前 tag tokens。
- `apps/Blocks/BlocksCore/ClipboardRepository.swift`
  - 将既有 `loadRecord(recordID:)` 调整为模块内可见，供 search document extension 重建单条记录使用。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
  - 浮窗 header 的“清除全部筛选”判断改为合并后的 `displayFilterState.hasActiveFilters`，tag-only filter 也会显示清除入口。
- `apps/Blocks/BlocksApp/Stores/ClipboardController.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
  - 移除 active App 层旧 `pinnedCount` 入口。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardTagStore.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
  - 将 `ClipboardTagOperationError.localizedMessage` 接入 String Catalog。
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
  - tag chips 超过 3 个时显示 `+N`。
  - 右键菜单默认新建文案从 `New Tag...` 改为明确的 `Create "New Tag"` 口径。
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
  - 增加“已有记录带标签 -> 删除 search document -> dirty 修复 / rebuild -> 标签搜索仍命中”的 fixture。
- `tools/verification/p13b_clipboard_tags_model_checks.py`
  - `tag_search.e2e_gate` 绑定到上述 P9A 当前 fixture。
  - 增加 `pinnedCount` 旧 active path 负向检查。
- `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
  - 增加 `pinnedCount` 旧 active path 负向检查。
- `tools/verification/p8_clipboard_product_polish_checks.py`
  - 将 clear-all/tag filter 检查收紧到 `ClipboardFloatingPanelView.header` 块。
  - 更新右键默认新建文案检查到当前事实源。

## Reviewer findings 收口

- R1：已修复。
  - search document 缺失时，dirty path 和 rebuild path 都读取当前标签关联并写入 `tagTokens`。
  - P9A 覆盖 `tag_search_missing_document_repair` 和 `tag_search_rebuild_path`。
  - P13B `tag_search.e2e_gate=pass` 仅在 P9A 当前 fixture 存在时成立。
- R2：已修复。
  - tag-only filter 下 header 使用 `displayFilterState.hasActiveFilters`，清除动作继续调用 `clipboardStore.clearFilters()`，该动作会同时清普通 filters 和 `tagStore.selectedTagID`。
- R3：已修复。
  - active App 层旧 `ClipboardController.pinnedCount` / `ClipboardStore.pinnedCount()` 入口已移除。
  - P13B / P9B 增加 `pinnedCount` active path 负向检查。

## P2 处理

- 已顺手收口：
  - 标签操作错误文案迁入 String Catalog。
  - 条目 tag chips 超过 3 个显示 `+N`。
  - 右键默认新建标签文案改为 `Create "New Tag"`，不暗示弹出输入。
- 明确保留：
  - Settings 行内反馈未做真实 UI 体验改造，本轮仅保持现有 Settings 标签管理路径可用并由静态 / smoke 门禁覆盖。
  - 未做真实 UI 自动化、真实右键菜单交互、真实剪贴板操作。

## 验证结果

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | `ok=true`，`tag_search.e2e_gate=pass`，legacy active store paths clear。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `verified_tag_fixtures` 包含 `tag_search_missing_document_repair`、`tag_search_rebuild_path`。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | `ok=true`，未发现 `pinnedCount` 旧 active path。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | header clear-all / tag filter 检查通过。 |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | `ok=true`。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | `ok=true`，Step 2 tag/favorite UI/store guard 通过。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | `ok=true`。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出 CLI usage 和 `blocks.screenshot.capture` action。 |
| `git diff --check` | PASS | 无 whitespace error。 |

## 低敏与安全声明

- 本轮未触发真实 App、真实系统剪贴板、真实 OCR、provider、Keychain、TCC、系统设置、Show in Finder 或 restart。
- 验证使用 repository smoke / 静态门禁 / build；未输出真实剪贴板正文、图片、OCR 原文、provider 响应或凭据。
- P9A 输出仍保持 `<TMP>` 形式，不暴露临时数据库完整路径。

## 残余风险

- P0：无已知。
- P1：无已知。
- P2：Settings 标签管理的行内反馈未做真实 UI 实物验收；右键菜单新建标签仍是固定默认名，完整命名输入交互未在本轮实现。
