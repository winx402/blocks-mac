# 004_剪贴板打磨 Step 6 低敏集成验证 v0

日期：2026-07-07
角色：项目负责人
对象：Step 6 收口复审补证据

## 1. 结论

结论：`low-sensitive-evidence-pass`。

项目负责人按 Step 6 角色复审要求补跑最新低敏集成证据矩阵。P13A / P13B / P13C / P13D / P13E / P11E / P8 / P8I / P9A / P9B / P9C 均通过；Blocks App Debug build、BlocksCLI Debug build、CLI help 和 `git diff --check` 均通过。

本验证不触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举、真实用户数据库 mutation 或真实系统状态变更。Xcode build 包含默认 LaunchServices / execution-policy registration 输出，但未启动 App，未执行 CLI mutation。

## 2. Gate 矩阵

| Gate | 结果 |
| --- | --- |
| P13A | PASS；`exit=0`、`ok=true`、`failures=0` |
| P13B | PASS；`exit=0`、`ok=true`、`failures=0` |
| P13C | PASS；`exit=0`、`ok=true`、`status=pass`、`failures=0` |
| P13D | PASS；`exit=0`、`ok=true`、`status=pass`、`failures=0` |
| P13E | PASS；`exit=0`、`ok=true`、`status=pass`、`failures=0` |
| P11E | PASS；`exit=0`、`ok=true`、`failures=0` |
| P8 | PASS；`exit=0`、`ok=true`、`failures=0` |
| P8I | PASS；`exit=0`、`ok=true`、`failures=0` |
| P9A | PASS；`exit=0`、`ok=true`、`schema_version=5` |
| P9B | PASS；`exit=0`、`ok=true`、`failures=0` |
| P9C | PASS；`exit=0`、`ok=true`、`failures=0` |

运行命令：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13e_clipboard_privacy_policy_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
```

## 3. Build / CLI / Diff

| 验证项 | 结果 |
| --- | --- |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；`** BUILD SUCCEEDED **`。保留既有 AppIntents metadata warning；Xcode build 默认执行 LaunchServices 注册输出，未启动 App |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；`** BUILD SUCCEEDED **`。Xcode build 默认执行 execution-policy registration 输出，未执行 CLI mutation |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS；输出 `blocks.screenshot.capture`、`privacy.subjects.list`、`privacy.subjects.resolve`、`privacy.policy.get`、`privacy.policy.set`、`privacy.action.blocked` |
| `git diff --check` | PASS |

## 4. 旧事实源 Active Path Audit

执行了以下只读静态检索：

```bash
rg -n "pinboardID|pinnedCount|isPinned|preservePinned|clearUnpinned|pinboard|pinned" apps/Blocks/BlocksApp apps/Blocks/BlocksCore -g '*.swift'
rg -n "redactedPreview\\(|searchableText|redacted|excludedBundleIDs|excludedBundleIdentifiers|clipboard\\.policy\\.excludedBundleIDs" apps/Blocks/BlocksApp apps/Blocks/BlocksCore -g '*.swift'
rg -n "selectedTagID|recordTags|preserveFavorite|clearUnfavorited|Favorite|favorite" apps/Blocks/BlocksApp/Features/Clipboard apps/Blocks/BlocksCore -g '*.swift'
```

结论：

- 旧 `pinboard` / `pinned` 仍存在于 `ClipboardRepository` legacy storage、`ClipboardRecorderFoundation` fixture / archive support、`AppDatabase` legacy table 和 `ClipboardPinboard` 支持结构中。
- 当前面板过滤、搜索和收藏 active path 使用 `ClipboardTagStore.recordTags`、`selectedTagID`、`preserveFavorite`、`clearUnfavorited`、`ClipboardTagRepository.ensureFavoriteTag()` 等标签/收藏事实源。
- 旧 `redacted` helper 仍存在于 `ClipboardReadModel`、`ClipboardSearchDocument` 的派生状态、provider warning 和 fixture/baseline 文案中；P13A / P11E / P8I 的当前 gate 已约束其不作为默认明文面板或搜索 ok fact source。
- 旧 `clipboard.policy.excludedBundleIDs` 只在 `Step5OneShotMigration` 作为 legacy migration input；截图服务自有 `excludedBundleIDs` 属于 screenshot service 排除列表，不是 Step 5 privacy policy fact source。

## 5. 收口判断

本轮补证据关闭了测试/质量与 App 架构师提出的 Step 6 最新低敏证据矩阵要求。以下内容仍按 P2 residual 处理，不在 Step 6 内强行补真实系统证据：

- 真实 App UI、真实 VoiceOver、真实系统剪贴板、真实 Vision OCR 质量、真实 App 三目录扫描、真实 icon 视觉截图。
- 真实用户数据库 migration / policy mutation。
- P13E temp DB runtime migration harness。
- P13C `.label` localization 完整键级证明。
- P13D `current_evidence.dispatch` 指针细化。
- 既有构建 warning 清理。
