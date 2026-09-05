# Step 4D Clipboard hardening PRD v0

状态：accelerated-review-and-development
日期：2026-07-06
来源级别：product and architecture implementation plan

> 本文是 Step 4D 的 PRD 草案。它承接 Step 4C-4 go/no-go 后的拆分结论：Clipboard hardening 不在 Step 4C core 内接受，作为独立 Step 4D 进入方案复审、开发、验收闭环。根据用户最新要求，Step 4D 改为方案快速复审与开发并行推进；但复审或实现中出现 P0/P1 时，必须立即回写或返工，最终接受仍要求 P0/P1 为 0。

## 0. 决策摘要

Step 4D 聚焦 Clipboard hardening：默认列表、普通面板渲染、Settings summary、DataAudit 和 CLI 默认输出不得读取完整剪贴板 payload；完整 payload 只允许在明确用户动作或明确业务用例中读取。

本阶段不新增剪贴板能力，不启用 helper 生产写库、App Group、CLI 默认完整 payload、OCR、provider call、网络外发、Keychain 或任意自动化能力。

Step 4D 必须先解决验证能力，再改业务行为：

1. 新增 P11E fail-closed 门禁，先在当前基线暴露默认 payload 预读和普通渲染读取问题。
2. 明确 metadata-first / redacted read model、explicit payload read API、payload cache 生命周期和 `summary` 敏感级别。
3. 改造 ClipboardStore / AppState facade / Clipboard panel / Settings / DataAudit / CLI 边界。
4. 迁移旧 P8/P9 门禁到当前事实源。
5. 通过安全合规、测试/质量和主会验收后，才能接受 Step 4D。

并行开发例外：根据用户 2026-07-06 最新要求，允许开发线程在 PRD 快速复审期间并行推进 `P11E-first` 窄实现，但范围只限 P11E 红灯验证、低敏 fixture、read model skeleton、explicit purpose API、Store / AppState 默认读取边界收紧和 4D-1 必要的静态门禁。PRD P1 回写和主会确认前，不得进入 4D-2 UI / hover / Settings 实物路径验收，不得接受或合并会改变真实用户 clipboard 行为的实现；并行产物必须按回写后的 PRD 复核，不一致时以本文和最新复审为准。

## 1. 背景与当前事实基线

Step 4C core 已由主 agent 最终接受，范围包括 ScreenshotStore、ShortcutStore 和 Settings shell split。Conditional Step 4C-4 Clipboard hardening 经 go/no-go 后拆为 Step 4D。

当前基线：

- 最新阶段提交：`9b4c43b docs: close step 4c core and hand off clipboard hardening`
- Step 4C core 接受记录：`docs/项目管理库/003_架构升级/step_4/最终接受记录-Step4C-Core-v0.md`
- Step 4D handoff：`docs/项目管理库/003_架构升级/step_4/Step4D-Handoff-ClipboardHardening-v0.md`

当前代码事实：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
  - `loadRepositoryState(limit:)` 当前 `loadRecent` 后会调用 `loadPayloads(for:repository:)`。
  - `loadPayloads` 会对 recent records 循环调用 `repository.readPayload(recordID:)`。
  - `preview(for:)` 和 `filteredRecords(query:limit:)` 当前把 `payloads` 传给 `ClipboardController`。
  - `repositoryUnavailable` 已存在，但用户可见 degraded 状态还不完整。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
  - bottom tray 的 `ClipboardFloatingRecordCard` 当前接收 `payload: appState.clipboardPayload(for: record.id)`。
  - side list 的 `ClipboardFloatingRecordRow` 当前接收 `payload: appState.clipboardPayload(for: record.id)`。
  - hover overlay 当前为 `filteredRecords` 构建 `ClipboardHoverDetailItem` 时传入 payload。
- `apps/Blocks/BlocksApp/Support/ClipboardRecordPreview.swift`
  - `preview(metadata:payload:)` 会用 payload text、URL、fileURL 或 image base64 生成 title、body 或 image。
  - `searchableText` 当前包含 `summary` 和 `preview().searchableText`。
  - `summary` 可能来自正文短摘要，不应默认视为低敏。
- `apps/Blocks/BlocksApp/Stores/AppState.swift`
  - `clipboardPayload(for:)` 是无 purpose 的通用 facade。
  - `pasteClipboardRecord(recordID:)`、`copyClipboardRecordAsPlainText(recordID:)` 当前通过 `clipboardPayload(for:)` 读取 payload。
  - Translation clipboard preview 当前可由 `previewClipboardRecordForTranslation(recordID:)` 等路径使用 clipboard record / payload。
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
  - 当前有 policy、privacy exclusion、panel 设置等内容。
  - 尚未形成 repository unavailable / storage degraded / redacted read model 的用户可见 summary。
- `apps/Blocks/BlocksApp/Features/Settings/DataAuditSettingsPane.swift`
  - 当前展示 clipboard index count，不应在 Step 4D 中扩大为默认 payload 输出。
- `apps/Blocks/BlocksCLI/main.swift`
  - 当前 CLI 只暴露 screenshot action；未发现 clipboard payload 默认输出。
- 当前不存在 `tools/verification/p11e_clipboard_hardening_checks.py`。
- 旧门禁中至少 `p8_clipboard_product_polish_checks.py`、`p8i_settings_clipboard_system_checks.py`、`p9b_clipboard_appstate_repository_integration_checks.py` 需要迁移当前事实源和 hardening 后契约。

以上是当前事实，不代表这些结构合理或已满足 Step 4D。

## 2. 用户目标

用户需要：

- 打开 Clipboard panel 时，默认列表可用、可理解，但不默认读取或展示完整剪贴板正文、完整 URL、完整 file path、图片/base64 或 OCR 文本。
- 用户可以区分四种状态：没有历史、存储不可用、过滤无结果、内容被保护而仅展示摘要。
- repository unavailable / storage degraded 时，有明确的用户可见反馈，不把“历史不可用”误表达为“内容丢失”。
- 用户主动 paste、copy、hover detail、translation preview 时，允许读取完整 payload，但读取目的明确、失败反馈清楚。
- Settings 能解释默认列表保护策略、storage 状态和完整 payload allowlist，不展示真实剪贴板正文。

开发和后续 agent 需要：

- 一个稳定的 read model：metadata-first list item / redacted preview / explicit payload read。
- 一个可审计的 payload read API，所有完整 payload 读取都有 `purpose`。
- 一个 fail-closed 的 P11E，能阻止默认路径重新读取完整 payload。
- 旧 P8/P9 门禁不再把旧 story、旧归档、旧 payload preload 行为当成阻断事实源。

## 3. 范围

### 3.1 必须新增或修改

必须新增：

- `tools/verification/p11e_clipboard_hardening_checks.py`

建议新增，命名可调整：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardReadModel.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPayloadAccess.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardRepositoryState.swift`

必须修改：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/Stores/AppState.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift`
- `apps/Blocks/BlocksApp/Support/ClipboardRecordPreview.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/DataAuditSettingsPane.swift`
- 相关 P8/P9 verifier。

必须由 P11E 检查：

- `apps/Blocks/BlocksCLI/main.swift`

CLI 默认要求是不新增 clipboard payload 输出；只有新增或发现默认 clipboard payload 输出风险时才按需修改 CLI 文件。新增 Swift 文件必须加入 Blocks app target；如果触碰 CLI 文件，BlocksCLI build 必须通过。

### 3.2 Read model 目标

Step 4D 必须建立三层概念：

1. Metadata record：来自 repository record，不包含完整 payload。
2. Redacted display item：用于默认列表、普通卡片 / 行、Settings summary、DataAudit 和 CLI 默认输出。
3. Explicit payload read：用户动作或明确业务用例触发的完整 payload 读取。

默认列表允许使用：

- kind / localized kind。
- source app name / bundle id 的低敏展示。
- timestamp / relative time。
- pin state、pinboard name。
- format summary：item count、type list、text length、byte count、file count、url count。
- restorable、excluded、snapshotSkipped、fixtureOwned 等状态。
- signature short hash。
- redacted placeholder。

默认列表不得使用：

- payload text。
- payload urlString 全文。
- payload fileURL / file path 全文。
- payload pngDataBase64。
- 由 base64 解码生成的真实图片 preview。
- OCR 原文。
- 历史 `record.summary` 或任何未标记 summary。所有 summary 默认视为 sensitive；只有 Step 4D 新增明确字段或类型证明它由低敏 metadata 规则生成时，才可进入默认展示。字段名、生成规则和 P11E 检查必须写入开发记录。

### 3.3 Explicit payload read API

必须用枚举或等价结构表达读取目的。

建议模型：

```swift
enum ClipboardPayloadReadPurpose: String {
    case paste
    case copyPlainText
    case hoverDetail
    case translationPreview
}
```

建议接口：

```swift
func readPayload(recordID: String, purpose: ClipboardPayloadReadPurpose) -> ClipboardPayloadReadResult
```

命名不强制，但必须满足：

- 完整 payload 读取不能再通过无 purpose 的 `clipboardPayload(for:)` 暴露给任意 View。
- 新增 purpose 必须先更新本文、P11E allowlist 和测试矩阵。
- 失败结果必须能区分 not found、repository unavailable、payload unavailable、record not restorable 或 permission / policy blocked。
- read result 不得自动写入开发记录、verification JSON 或 audit 正文。

### 3.4 Payload cache 生命周期

必须明确：

- `loadRepositoryState(limit:)` 不得批量读取 recent records payload。
- 默认 reload 不得填满完整 payload cache。
- payload cache 只能由 explicit read API 写入。
- cache 不得被默认列表 / Settings / DataAudit / CLI 默认输出读取。
- 默认实现优先不缓存完整 payload；若必须缓存，只允许 keyed by `(recordID, purpose)`，不得作为宽 `@Published payloads` 暴露给默认列表。
- hover detail 退出、panel 关闭、repository reload 或 record 删除时必须清理对应 purpose cache。
- 若实现选择不缓存 payload，也可以；但 paste/copy/hover/translation 需要保持可用反馈。

### 3.5 Search / filter 策略

PRD 推荐默认只按 metadata / redacted display item 搜索，避免 query path 依赖 payload 正文。

如果开发选择继续使用 repository FTS 或历史 search_text：

- 结果列表仍只能展示 redacted display item。
- verification / logs 不得输出匹配到的正文片段。
- P11E 必须把 search path 明确列入 read model summary，说明它不读取完整 payload、不展示正文。

Search / filter query 本身也按敏感内容处理：

- verification JSON、audit、开发记录、验收记录和 logs 不得记录真实 raw query / filter text。
- 不得记录 matched snippet、highlight、FTS excerpt 或搜索命中的正文片段。
- 测试只能使用 synthetic query / fixture token；真实交互证据只能记录 query length、hash-like id、filter kind 或 redacted marker。
- P11E 的 `read_model_denylist` 和 `sensitive_output_scan` 必须覆盖 raw query、matched snippet、highlight、FTS excerpt。

### 3.6 UI / UX contract

Clipboard panel 必须覆盖：

- repository unavailable / storage degraded banner 或等价可见反馈。
- empty：没有历史摘要。
- unavailable：存储暂不可用或历史不可读 / 不可写。
- filtered：有历史，但当前搜索 / 过滤无结果。
- redacted：有记录，但正文被保护，仅显示 metadata / summary placeholder。
- 状态展示优先级必须稳定：repository unavailable / storage degraded 高于 empty；empty 高于 filtered；filtered 高于 redacted；redacted 是列表中有记录但内容受保护时的默认表达。
- row/card 默认 metadata-first，不展示 payload 正文。
- hover detail 是 lazy explicit read，不得为所有 filtered records 预读 payload。
- hover detail 必须有 loading、failed、unavailable 或等价本地化状态；hover 退出、panel 关闭、repository reload 后不得继续显示上一条 payload。
- paste / copy / translation preview 的失败反馈不能静默。

Settings Clipboard 必须覆盖：

- storage 状态：normal / degraded / unavailable。
- 默认列表策略：metadata-first / redacted。
- 完整 payload allowlist：paste、copy、hover detail、translation preview。
- 不启用范围：helper 生产写库、App Group、CLI 默认完整 payload。
- 沿用 Step 4C-3 Settings shell / pane / section / row 结构，不做视觉重设计；长句、三语言文案和 storage policy 说明不得挤压固定 trailing column。

DataAudit 必须保持低敏：

- 允许 count、state、redacted status、repository availability。
- 不允许剪贴板正文、URL 全文、file path 全文、图片/base64、OCR 文本。

CLI 默认输出：

- Step 4D 不新增 clipboard 默认 payload 输出。
- 如果为了验证新增 clipboard list dry-run，只能输出 metadata/redacted；完整 payload CLI 命令不属于 Step 4D。

## 4. 非目标

Step 4D 不做：

- 不启用 helper 生产写库。
- 不启用 App Group。
- 不新增 CLI 默认完整 payload 输出。
- 不新增 OCR。
- 不新增 provider call、网络外发、多模态图片上传。
- 不读取 Keychain secret。
- 不新增任意自动化执行能力。
- 不重做 Clipboard panel 视觉设计。
- 不重写 Settings shell、ShortcutStore、ScreenshotStore、PermissionStore、ProviderStore 或 TranslationStore。
- 不改变用户主动 paste / copy 的目标语义，只收紧默认展示和读取边界。
- 不把真实剪贴板正文、URL 全文、file path 全文、图片/base64 或 OCR 文本写入开发记录、验收记录、verification JSON、audit 或 logs。

## 5. 子批次

Step 4D 必须分批，不得一次性连续开发到最终验收。

### 5.1 Step 4D-1：P11E 与 read model 基础

目标：

- 新增 P11E，并让它在当前基线下红灯。
- 建立 explicit payload read purpose。
- 让 `loadRepositoryState(limit:)` 默认不再批量读取完整 payload。
- 收窄 AppState 无 purpose payload facade。
- 建立默认 redacted display item builder。
- 初步迁移 `p9b_clipboard_appstate_repository_integration_checks.py` 到新契约。
- 普通 panel list / card / row / tray 的完整 payload 输入必须在 4D-1 前移关闭；否则 4D-1 P11E 不得通过。

出口：

- 开发记录和验收记录必须包含低敏当前基线 P11E FAIL 证据，以及实现后 P11E PASS 证据。
- P11E 通过，并输出 allowlist / denylist 摘要。
- 默认 load / reload denylist 关闭。
- P9A repository storage smoke 与 P9B AppState repository integration 通过，且输出低敏。
- App build、BlocksCLI build、`blocks --help`、`git diff --check` 通过。
- App 架构师、安全合规、测试/质量无 P0/P1。
- 主会写 4D-1 stop/go 后，才能进入 4D-2。

### 5.2 Step 4D-2：UI / UX 与旧门禁迁移

目标：

- Clipboard panel 默认 row/card/list/tray 使用 metadata-first / redacted display item。
- Hover detail 改为 lazy explicit read。
- Paste / copy / translation preview 走 allowlist API。
- Clipboard panel 和 Settings 显示 repository unavailable / storage degraded / redacted policy。
- empty / unavailable / filtered / redacted 四类状态可区分。
- 迁移 `p8_clipboard_product_polish_checks.py`、`p8i_settings_clipboard_system_checks.py` 和相关 P7/P9 当前事实源。

出口：

- P11E、P8、P8I、P9A、P9B、P9C 通过。
- 低敏 UI 证据覆盖四类状态和 explicit payload read。
- App build、BlocksCLI build、`blocks --help`、`git diff --check` 通过。
- UI/交互、安全合规、测试/质量无 P0/P1。
- 主会写 Step 4D 最终接受记录。

如果 4D-1 发现 read model 需要更大拆分，必须停止并回到主会更新 PRD，不得继续扩大 4D-2。

## 6. P11E 门禁

新增：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

P11E 必须 fail closed：

- 脚本不存在时失败。
- 预期文件不存在时失败。
- target membership 无法解析时失败。
- 旧归档、旧 story、旧 acceptance 参与 `ok` 时失败。
- 检查项解析失败但未给出明确低风险解释时失败。
- 只输出 PASS/FAIL、没有 allowlist / denylist 摘要时失败。

P11E 输出必须包含：

- `ok`
- `failures`
- `checked_files`
- `current_evidence`
- `baseline_reference`
- `read_model_allowlist`
- `read_model_denylist`
- `explicit_read_sites`
- `denied_default_sites`
- `repository_state_summary`
- `sensitive_output_scan`
- `target_membership`

P11E 必须检查：

- 默认 load / reload 不调用 `loadPayloads` 或 `repository.readPayload(recordID:)`。
- 普通 list / card / row / tray / Settings / DataAudit / CLI 默认输出不传入 `ClipboardRecorderPayload`。
- `ClipboardDirectContentPreview` 不在默认 list/card 路径显示 payload text、URL 全文或 image base64。
- `ClipboardContentThumbnail` 默认不从 payload image base64 构造真实图片缩略图。
- `clipboardPayload(for:)` 不再作为无 purpose 的通用 facade 暴露。
- 允许完整 payload 的路径只包括 paste、copy plain text、hover detail、translation preview。
- Hover detail 不为所有 filtered records 预读 payload。
- 默认 redacted builder、searchable text、row/card/list/tray、Settings、DataAudit、CLI 默认路径不直接展示或搜索拼接历史 `record.summary` / 未标记 summary；除非命中 Step 4D 明确新增的 low-sensitive marker。
- raw query、matched snippet、highlight、FTS excerpt 不进入 verification JSON、audit、开发记录、验收记录或 logs。
- canary fixture 输出扫描覆盖 synthetic secret、URL、file path、base64-like payload、OCR-like text、window-title-like text，输出只保留 redacted marker。
- payload cache 生命周期输出摘要，至少覆盖 no-cache 或 `(recordID, purpose)` cache、hover exit、panel close、repository reload、record delete。
- repository unavailable、empty、unavailable、filtered、redacted 有可区分状态或本地化 key。
- helper 生产写库、App Group、CLI 默认完整 payload 未开启。
- verification 输出和文档不含剪贴板正文、raw query、matched snippet、highlight、FTS excerpt、URL 全文、完整 file path、图片/base64、OCR 文本、窗口标题、屏幕文本、真实凭据、Authorization header、request body 或 provider raw response。

## 7. 旧门禁迁移

Step 4D 阻断矩阵中凡使用旧 P7/P8/P9 脚本，必须迁移当前事实源。

必须处理：

- `p8_clipboard_product_polish_checks.py`
  - 旧 story / acceptance / archive 只能作为 `baseline_reference`。
  - `ok` 必须来自 Step 4D PRD、Step 4D 开发记录、当前 Clipboard UI / Settings / code。
- `p8i_settings_clipboard_system_checks.py`
  - 必须基于 Step 4C-3 后的 `Features/Settings` shell / pane。
  - 不得继续检查旧 `SettingsView.swift` route body。
- `p9b_clipboard_appstate_repository_integration_checks.py`
  - 不得继续要求 payload preload 结构。
  - 必须改为 metadata load 与 explicit payload read 边界检查。
- `p9a_clipboard_repository_storage_smoke.py`
  - 作为 repository storage regression 保留。
  - 不得替代 P11E read model gate。
- `p9c_no_reset_fixtures_ui_checks.py`
  - 保留 fixture / UI regression。
  - 输出不得包含真实 payload。
- 相关 P7L / P7D / P8M / P8N 如仍断言默认 preview 使用真实 payload，必须更新或降级 baseline。

## 8. 安全与隐私边界

开发、测试和验收允许记录：

- read purpose。
- synthetic id / fixture id / hash-like record id。
- kind、source app bundle id、timestamp bucket。
- text length、byte count、file count、url count。
- redacted、truncated、unavailable、repository availability。
- synthetic query / fixture token、query length、hash-like query id、filter kind。
- PASS/FAIL、失败代码、相对文件路径、sanitized command。

禁止记录：

- 剪贴板正文。
- 选中文本正文。
- raw search query / filter text。
- matched snippet、highlight、FTS excerpt。
- URL 全文。
- file path 全文。
- 图片/base64。
- OCR 原文。
- 窗口标题、屏幕文本。
- 真实用户主目录或完整本地路径。
- 真实凭据、Authorization header、request body、provider raw response。

公开验收材料中的 source app name / bundle id 优先使用 fixture / synthetic 值；真实 app 名和 bundle id 即使可作为本机 UI metadata，也不得原样复制到验收记录。

`p9a_clipboard_repository_storage_smoke.py` 的成功与失败输出必须低敏化，不得输出临时数据库完整路径、真实 payload、真实 URL、完整 file path 或用户主目录。

P11E 和相关 verifier 必须复用或扩展现有 sanitizer；新增 subprocess 输出必须接入低敏处理。

## 9. 验收矩阵

Step 4D-1 最低门禁：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

Step 4D-2 最低门禁：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如触碰 Shortcut、Permission、Provider、Translation、Screenshot 或 signing/TCC，按影响范围追加对应 P6/P7/P10/P11 门禁。

## 10. 最小实物证据

Step 4D 最终验收必须有低敏证据：

- Clipboard panel 正常 redacted list：默认列表不显示正文。
- repository unavailable / storage degraded。
- empty、unavailable、filtered、redacted 四类状态。
- paste explicit read。
- copy explicit read。
- hover detail lazy explicit read。
- translation preview explicit read。
- Settings Clipboard storage / redacted policy / allowlist summary。
- DataAudit 只展示低敏 count / state。
- CLI 默认输出不包含 clipboard payload。
- VoiceOver / keyboard / 窄宽度 / 三语言长句抽查。

证据不得包含真实剪贴板正文、完整 URL、完整 file path、图片/base64 或 OCR 文本。

## 11. 角色流程协议

### 11.1 方案复审

PRD 草案完成后并行派发：

- App 架构师：重点看 read model、Store API、AppState facade、payload cache 生命周期、target membership、子批次拆分。
- UI/交互设计师：重点看 redacted list、repository degraded、四类状态、hover detail lazy read、Settings 解释面和低敏实物证据。
- 安全合规顾问：重点看 payload allowlist / denylist、低敏输出、CLI / helper / App Group / provider / OCR / Keychain 禁止边界。
- 测试/质量：重点看 P11E 可执行性、旧 P8/P9 迁移、fail-closed、验收矩阵和证据格式。

常规规则是 P0/P1 未关闭前不得派开发。本阶段因用户要求提速，仅允许 `P11E-first` 窄实现并行启动；范围和限制以第 0 节并行开发例外为准。任何 P0/P1 未关闭前，不得进入 4D-2，不得做最终接受，不得提交包含真实用户 clipboard 行为变更的实现。

### 11.2 PRD 提交

四方快速复审完成、P0/P1 回写本文后，主 agent 提交 PRD 阶段文档。提交前允许保留并行产生的 `P11E-first` 草稿实现，但必须在 PRD 回写后复核；若实现与本文冲突，先返工再接受。PRD 提交前不得进入 4D-2。

### 11.3 开发回调

开发按子批次回调，每次必须提供：

- 子批次编号。
- 开发记录路径。
- 实际改动文件。
- 运行命令和结果。
- 未运行命令和原因。
- 低敏证据位置。
- 安全隐私声明。
- 残余风险。

### 11.4 验收与接受

- 每个子批次至少由测试/质量独立验收。
- 触碰 read model / AppState / store 边界时必须由 App 架构师复审。
- 触碰 payload、CLI、日志、verification output 时必须由安全合规复审。
- 触碰 panel / Settings / hover detail / state 文案时必须由 UI/交互复审。
- 主 agent 在每个子批次 P0/P1 为 0 后写 stop/go。
- Step 4D 最终接受记录必须明确接受范围、未覆盖真实系统场景和残余风险。

## 12. 可接受标准

Step 4D 最终接受必须同时满足：

- PRD 四方复审完成，P0/P1 为 0。
- PRD 阶段已提交；若存在并行 `P11E-first` 草稿实现，必须已按回写后的 PRD 复核并清零 P0/P1。
- 4D-1 和 4D-2 均有开发记录、必要复审、测试/质量验收和主会 stop/go。
- P11E 和相关 P8/P9 门禁通过。
- App / CLI build、`blocks --help`、`git diff --check` 通过。
- 无新增真实 secret 读写、剪贴板正文日志、图片/OCR 外发、provider call、helper 生产写库、App Group、CLI 默认完整 payload 或任意自动化能力。
- 主 agent 写 Step 4D 最终接受记录并提交。
