# Step 4D Clipboard hardening 测试质量验收记录 v0

- 日期：2026-07-06
- 角色：测试/质量
- 结论：`accepted-with-residual-risk`
- 验收范围：Step 4D Clipboard hardening 实现、P11E / P8 / P8I / P9A / P9B / P9C 门禁、App / CLI build、CLI help、低敏输出边界。

## 结论

Step 4D 可进入主会最终接受判断。独立串行验收矩阵在最新工作区、purpose-keyed cache 修复、pinned `displayName` P1 修复和 `ClipboardController.filteredRecords` pinned `displayName` P1 修复之后全部 PASS。未发现 P0 / P1。

本结论不替主 agent 接受残余风险；真实 App UI、真实系统剪贴板、真实 paste / copy / hover / translation preview、VoiceOver、多语言长句和窄宽度实物场景仍未自动化覆盖。

## 已验证项

- P11E fail-closed 门禁存在并通过；输出包含 `ok=true`、`failures=[]`、current evidence、baseline reference、allowlist / denylist、explicit read sites、denied default sites、repository state summary、sensitive output scan、target membership。
- 默认 denylist 覆盖 repository load / reload、default list/card/row/tray、Settings summary、DataAudit、CLI default output。
- explicit allowlist 仅包含 `paste`、`copyPlainText`、`hoverDetail`、`translationPreview`。
- P8 / P8I / P9B 已迁移当前 Step 4D PRD、当前开发记录和当前代码事实源；旧 story/archive/acceptance 不参与 `ok`。
- P9A 输出低敏：`storage_root` 为 `<TMP>`，`database_file` 仅为文件名。
- Blocks App / BlocksCLI Debug build 通过。
- `blocks --help` 仍只列出 screenshot action，未新增 clipboard payload 默认 CLI 输出。
- 写入验收记录前 `git diff --check` 通过。

## Purpose-keyed cache 复核

- `ClipboardPayloadCacheKey` 已存在，字段为 `recordID` 和 `purpose: ClipboardPayloadReadPurpose`。
- `ClipboardStore.payloadCache` 类型为 `[ClipboardPayloadCacheKey: ClipboardRecorderPayload]`，不是旧的按 recordID 宽缓存。
- `loadRepositoryState(limit:)` 只加载 records / pinboards / pinned metadata，并执行 `payloadCache.removeAll()`；未批量读取 recent payload。
- `readPayload(recordID:purpose:)` 使用 `ClipboardPayloadCacheKey(recordID:purpose:)` 查询 cache，并在 repository path 下按显式 purpose 返回 payload result。
- fixture / in-memory 兼容路径通过 `replacePayloadCacheForFixtures` 为每个 allowlist purpose 写入 scoped cache；`payloadCacheSnapshotForFixtures` 只导出 `.paste` purpose 的兼容 snapshot。
- P9B 在最新工作区 PASS；脚本要求 `private var payloadCache: [ClipboardPayloadCacheKey: ClipboardRecorderPayload] = [:]`、`ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose)` 和 `payloadCache.removeAll()`。

## Pinned displayName P1 关闭情况

安全 / UI 复审指出 redacted preview/search/default search 仍信任历史 pinned `displayName` 的 P1 已关闭：

- `ClipboardRedactedPreviewBuilder.preview` 不再使用 `metadata?.displayName`。
- `ClipboardRedactedPreviewBuilder.searchableText` 不再包含 `metadata?.displayName`。
- `ClipboardController.filteredRecords` 不再把 `pinnedMetadata[record.id]?.displayName` 拼入 default search。
- P11E 增加 `redacted_preview_uses_pinned_display_name` 和 `filtered_records_uses_pinned_display_name` fail-closed 检查。
- 最新 P11E 输出 `denied_default_sites.filtered_records_no_pinned_display_name=true`。
- 最新 P11E 独立复跑 PASS，`failures=[]`。

## 命令结果

以下结果均为收到 `ClipboardController.filteredRecords` pinned `displayName` P1 修复后的最新工作区串行复跑结果。

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `git diff --check`（写记录前） | PASS | 无输出。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | `ok=true`，`failures=[]`；`filtered_records_no_pinned_display_name=true`；allowlist / denylist、explicit sites、denied sites、target membership、sensitive scan 均输出。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | `ok=true`，`legacy_sources_used_for_ok=false`。 |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | 输出 `P8-I checks passed.` |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | 输出 `{"database_file":"Blocks.sqlite","fts_enabled":true,"ok":true,"recent_count":0,"storage_root":"<TMP>"}`；未输出完整临时路径。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | `ok=true`，`failures=[]`；当前 evidence 指向 AppState、ClipboardStore、PayloadAccess、ReadModel。 |
| `python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py` | PASS | 输出 `ok: reset fixtures UI/code removed`。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；见 Xcode 多 destination warning、既有 AppIntents metadata skipped warning，以及 `AppState.swift` unused `record` warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；仅见 Xcode 多 destination warning。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅列出 `blocks.screenshot.capture`，未列 clipboard payload action。 |

## 安全 / 隐私边界复核

- 本轮未运行真实 App。
- 未触发真实系统剪贴板读取、真实 paste / copy / hover / translation preview。
- 未触发 TCC、provider、Keychain、系统设置、Show in Finder、restart、TCC reset、OCR、图片外发或网络外发。
- P11E / P8 / P9A / P9B 输出未包含剪贴板正文、完整 URL、完整 file path、图片/base64、OCR 文本、secret、Authorization header 或 provider raw response。
- 构建命令本身会输出标准构建路径；验收记录不复制完整构建路径作为证据。

## 未验证项

- 真实 Clipboard panel redacted list 视觉与交互。
- repository unavailable / storage degraded、empty、filtered、redacted 四类状态的真实 UI 体感。
- 真实 paste、copy、hover detail lazy read、translation preview explicit read。
- hover 退出、panel close、repository reload、record delete 后的 cache 体感。
- VoiceOver、keyboard、窄宽度、三语言长句实物验收。
- 真实用户剪贴板内容、真实权限环境、真实外部 provider 与 Keychain。

## P0 / P1 / P2

- P0：0。
- P1：0。purpose-keyed cache 修复已复核；redacted preview/search/default search 的 pinned `displayName` P1 已关闭。
- P2：
  - 真实 UI / VoiceOver / 多语言 / 窄宽度未实物覆盖。
  - 真实 paste/copy/hover/translation preview 未触发，只由静态门禁和 build 证明路径结构。
  - P11E 输出未单列 cache lifecycle 字段；该项由 P9B、代码抽查和开发记录共同覆盖，建议后续增强 P11E 输出摘要但不阻断本轮接受。
  - Blocks App build 出现 `AppState.swift` unused `record` warning；不影响构建结果，建议后续清理。

## 建议

建议主 agent 可以进入 Step 4D 最终接受判断；最终接受记录中应明确未覆盖真实系统剪贴板和真实 UI/TCC 场景。
