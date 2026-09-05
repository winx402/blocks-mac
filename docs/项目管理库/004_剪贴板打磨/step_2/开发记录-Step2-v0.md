# 004_剪贴板打磨 Step 2 开发记录 v0

## 结论

DONE_WITH_EVIDENCE。

本批次按 `项目负责人-开发派发-Step2-v0.md` 完成 Tag / RecordTag 独立事实源、内置 favorite 标签、面板单标签筛选、右键标签增删/新建入口、设置页标签管理、收藏从旧 pinned/pinboard 迁出，以及 P13B / P8 / P8I / P9A / P9B / P11E 当前事实源门禁迁移。

## 改动范围

- Core 数据与仓储：
  - 新增 `ClipboardTag.swift`、`ClipboardTagRepository.swift`。
  - `AppDatabase.swift` 增加 schema v3：`clipboard_tags`、`clipboard_record_tags`、`clipboard_search_documents.tag_tokens_json`，并 seed `tag.favorite`。
  - `ClipboardRepository.swift` 的清理策略改为 `preserveFavorite` / `clearUnfavorited()`；旧 pinboard/pinned storage API 保留为 baseline/兼容存储，不作为当前 UI / Store 事实源。
  - `ClipboardSearchDocument*` 与 `ClipboardRepository+SearchDocuments.swift` 增加 `tagTokens` 投影与 `markSearchDocumentTagsDirty(recordIDs:)`。
- App 状态与 UI：
  - 新增 `ClipboardTagStore.swift`，作为 feature-level tag / RecordTag / selectedTagID 事实源。
  - `ClipboardStore` 持有并桥接 `ClipboardTagStore`，搜索和默认列表筛选走 `recordTags + selectedTagID`。
  - `AppModel` 保留薄 facade：`clipboardTagStore`、`toggleClipboardFavorite`、`setClipboardTagFilter`、`clearUnfavoritedClipboardSummaries`。
  - `ClipboardFilterBarView` 改为单标签筛选，favorite first。
  - `ClipboardRecordViews` 增加标签右键菜单、favorite toggle、tag chips。
  - `ClipboardSettingsPane` 增加标签管理区，favorite 为内置不可改标签；策略 UI 从 preserve pinned 改为 preserve favorite。
  - 补充 Step 2 标签 UI 本地化 key。
- Verification：
  - 新增 `p13b_clipboard_tags_model_checks.py`，fail-closed 输出 `baseline_reference` / `current_evidence` / `legacy_exit` / `tag_search` / `sanitizer`。
  - 迁移 `p8_clipboard_product_polish_checks.py`、`p8i_settings_clipboard_system_checks.py`、`p9a_clipboard_repository_storage_smoke.py`、`p9b_clipboard_appstate_repository_integration_checks.py`、`p11e_clipboard_hardening_checks.py` 到 Step 2 当前事实源；旧 pinboard/pinned 只作为 baseline reference，不参与 ok。

## 未改范围

- 未进入 Step 3 hover / toolbar / 选中反馈 / 密度专项。
- 未进入 Step 4 详情编辑。
- 未进入 Step 5 隐私页 App 清单 / CLI 广义对象。
- 未重做 Step 1 搜索 / OCR；仅扩展 search document 的 tag token 投影。
- 未触发真实剪贴板、provider、Keychain、TCC、系统设置或自动化动作。

## 关键实现决策

- Step 1 已占用 `PRAGMA user_version = 2`，本批次用 schema v3 承载 Step 2 tag 表与 `tag_tokens_json`，作为 PRD “V2 或等价 migration” 的当前实现口径。
- favorite 使用独立内置 tag `tag.favorite`，通过 `clipboard_record_tags` 表关联记录；不再以 `ClipboardRecorderRecord.pinned` 作为当前收藏事实源。
- tag 搜索不把标签名写入 payload / summary；P9A 使用低敏 fixture 证明 `Research` tag 不在正文中，但可通过 search document / FTS 命中。
- 面板右键菜单的 “New Tag...” 当前使用固定低敏默认名 `New Tag` 并立即附加；设置页提供完整命名、改色、排序、合并、删除能力。

## 验证结果

- `python3 tools/verification/p13b_clipboard_tags_model_checks.py`：PASS。P13B 输出 `ok=true`，`legacy_exit` 全 true，`tag_search.contract_gate=pass`，`tag_search.e2e_gate=pass`，e2e 来源为 P9A smoke。
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`：PASS。含 Step 2 单标签筛选、右键 tag menu、favorite surface、旧 pinboard UI 退出证据。
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS。含 Step 2 设置页标签管理、preserve favorite、旧 pinboard settings 退出证据。
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`：PASS。输出低敏 `<TMP>`；schema v3；fixture 包含 favorite_builtin、record_tag、tag_search、clear_unfavorited、preserve_favorite_policy、body_excludes_tag_name。
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`：PASS。AppModel / ClipboardStore / ClipboardTagStore / search coordinator 当前事实源证据通过。
- `python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py`：PASS。
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS。Step 2 tag/favorite UI/store 默认路径无 payload read / system sensitive token。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。仍存在既有 `FloatingPanelSupport.swift` 的 `NSApp.isActive` main-actor warning，以及 xcodebuild 多 destination / AppIntents metadata 常规 warning；未发现 Step 2 新增 Swift 编译错误。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`：PASS，输出 `blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`。
- `git diff --check`：PASS。

## 低敏与安全声明

- 本批次 verification fixture 使用合成低敏文本、URL、文件名、tag 名称和临时数据库。
- 未输出真实用户剪贴板正文、真实 OCR 文本、真实截图、完整本地路径、Keychain secret、provider request / response 或系统权限内容。
- P9A 失败路径接入 shared sanitizer，临时路径 / workspace root 不应进入可复制输出。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化动作。

## 残余风险

- P2：面板右键 “New Tag...” 目前是固定默认名 `New Tag` 的最小入口；完整重命名和冲突处理在设置页，若产品希望右键原地命名，需要后续 UI 专项补强。
- P2：旧 `clipboard_pinboards` / `clipboard_pinned_metadata` 与 `ClipboardRecorderRecord.pinned` 仍作为 legacy storage / baseline 代码存在，当前门禁确认它们未作为 active UI/store/filter/policy ok 证据。
- P2：本批次未做真实 macOS UI 自动化验收；Settings / context menu / filter 行为由静态门禁、repository smoke 和 build 覆盖，实物交互建议由项目负责人后续安排。
- P2：`FloatingPanelSupport.swift` 既有 main-actor warning 保留，非 Step 2 引入。
