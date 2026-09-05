# Step 4D Clipboard hardening 开发记录 v0

日期：2026-07-06

状态：development-complete-ready-for-review

## 范围

Step 4D 目标是将 Clipboard 默认读取模型收紧为 metadata-first / redacted-first：

- 默认 repository load / reload 不预读完整 payload。
- 默认 Clipboard list / row / card / bottom tray / Settings / DataAudit / CLI 输出不接收、不显示完整 payload。
- 完整 payload 读取只允许通过显式目的：`paste`、`copyPlainText`、`hoverDetail`、`translationPreview`。
- 历史 `record.summary` 和未标记 summary 默认视为敏感，不进入 redacted list、Settings、DataAudit、CLI 默认输出或 verification / 开发 / 验收材料。
- 搜索 query、matched snippet、highlight、FTS excerpt 默认视为敏感，不写入 verification JSON、audit、开发记录或验收记录。

## 基线红灯证据

P11E-first 基线低敏检查在实现前预期 FAIL。基线问题包括：

- `ClipboardStore.loadRepositoryState` 为 recent records 批量预读 payload。
- `AppState` 暴露无 purpose 的 `clipboardPayload(for:)` facade。
- Clipboard 默认 row/card/tray/hover overlay 可接收完整 payload。
- redacted preview builder 缺失，默认 preview 可能回退到 summary 或 payload。
- P8/P8I/P9B 旧门禁仍依赖旧 SettingsView、旧 payload 预加载形态或旧 story/archive 事实源。

上述基线只记录检查项名称和结构事实，不记录真实剪贴板正文、URL 全文、文件路径全文、图片/base64、OCR 文本、窗口标题、屏幕文本、真实凭据或请求内容。

## 实现摘要

- 新增 `ClipboardPayloadReadPurpose` / `ClipboardPayloadReadResult`，将完整 payload 读取目的收敛为 allowlist。
- 新增 `ClipboardRepositoryStateSummary` 与 `ClipboardRedactedPreviewBuilder`，默认预览只使用低敏 metadata：kind、format count、byte/text/file/url count、pinboard name、source display 与 signature 摘要。
- 安全 / UI 复审过程中进一步收紧 redacted preview 与搜索：历史 pinned `displayName` 可能来自旧 preview / 正文短标题，不再作为默认 redacted title、redacted searchable text 或 `ClipboardController.filteredRecords` 搜索输入；P11E 增加对应 fail-closed 检查。
- `ClipboardStore.loadRepositoryState` 改为只加载 records / pinboards / pinned metadata，并清理 payload cache；不再批量读取 payload。
- `ClipboardStore.readPayload(recordID:purpose:)` 成为唯一 repository payload read 入口。
- payload cache 收紧为 `(recordID, purpose)` keyed；repository load 不填充 cache，fixture / in-memory 兼容路径也通过 purpose scoped cache 暴露。
- `AppState` 移除无 purpose 的 `clipboardPayload(for:)` facade，新增 `readClipboardPayload(recordID:purpose:)`、`clipboardRepositoryUnavailable`、`clipboardRepositoryStateSummary`。
- paste / copy plain text / translation preview 改为显式 purpose 读取；copy plain text 在 payload 不可用时给出失败状态，不复制 redacted preview。
- Clipboard panel 默认 row/card/tray 改为 metadata-first redacted preview；hover detail 改为 lazy explicit `.hoverDetail` 读取。
- Settings Clipboard / DataAudit 增加 storage / redacted policy / allowlist 说明，不读取完整 payload。
- P8/P8I/P9B 迁移到当前 Step 4D 事实源；旧 story/archive 不参与 `ok`。
- 新增 P11E fail-closed 门禁，覆盖 target membership、read purpose allowlist、默认 denylist、explicit read sites、低敏输出扫描、旧门禁当前事实源和 repository 状态 UI。
- P9A storage smoke 输出改为低敏数据库文件名，不输出临时数据库完整路径。

## 安全与隐私边界

- 未启用 helper 生产写库、App Group、真实 Clipboard CLI payload 输出、OCR、provider call、网络外发、Keychain、TCC reset、系统设置、Show in Finder 或 restart。
- 未运行真实 App，未触发真实系统剪贴板读取、真实权限请求或 provider 调用。
- verification / 文档只允许输出低敏结构事实、相对路径、脚本名、门禁名称和状态摘要。

## 验证计划

已串行运行并通过：

- `python3 tools/verification/p11e_clipboard_hardening_checks.py`
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
- `python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py`
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`
- `git diff --check`

关键结果：

- P11E：`ok=true`，`explicit_read_sites` 覆盖 `paste` / `copyPlainText` / `hoverDetail` / `translationPreview`，`denied_default_sites` 覆盖 repository load、panel、record views、hover overlay、Settings、DataAudit、CLI 默认输出。
- P8 / P8I / P9B：已迁移到当前 Step 4D PRD、当前开发记录和当前代码事实源；旧 story/archive 不参与 `ok`。
- P9A：输出低敏，`storage_root` 为 `<TMP>`，`database_file` 仅为文件名。
- Blocks App build：PASS。过程中先发现并修复两个编译问题：`ClipboardPayloadReadResult` 不再声明不必要的 `Equatable`；`emptyState` 显式 `return`；hover lazy read helper 标注 `@MainActor`。
- BlocksCLI build：PASS。
- `blocks --help`：PASS，仅列出 screenshot action；未新增 clipboard payload 默认 CLI 输出。
- `git diff --check`：PASS。

## 残余风险

- 未运行真实 App，未触发真实系统剪贴板读取、真实 paste/copy/hover/translation preview、真实权限请求、系统设置、Show in Finder、restart、TCC reset、provider call 或 Keychain。
- 未做真实 Clipboard panel / Settings / DataAudit 窄宽度、多语言长句、VoiceOver 低敏实物验收。
- hover detail 的 lazy read 已静态和构建验证，真实 hover 退出、panel close、repository reload、record delete 后的 cache 体感仍需后续实物验收。
- 既有 `FloatingPanelSupport.swift` MainActor/NSApp warning 与 AppIntents metadata skipped warning 仍存在；本切片未触碰其根因，且未阻断本轮 build。

## 待回填

- 多角色实现复审结论。
- 测试/质量最终验收结论。
