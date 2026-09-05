# 004_剪贴板打磨 Step 4 App 架构师技术方案 v1

日期：2026-07-07
角色：App 架构师
阶段：Step 4 - 详情编辑与元数据组织
状态：technical-plan-v1
基线：`App架构师-技术方案-v0.md` + Step 4 技术方案角色复审 + `项目负责人-技术方案复审收敛-v0.md`

## 1. 结论

结论：`ready-for-project-owner-v1-review`

Step 4 技术方案 v1 保留 v0 的主线：bounded detail read model、metadata snapshot、显式 detail edit purpose、单一 Store / Repository save command、默认同步 repository transaction、rich text fidelity gate、OCR user-edited 防覆盖、P13D fail-closed gate。

本版吸收项目负责人收敛的 P1：

1. 新增 mutable `contentRevision` / optimistic concurrency token，不复用 capture-based revision。
2. 明确 schema migration v4：OCR source 默认 `none`，仅对成功且非空旧 OCR 文本条件回填 `vision`。
3. 重写 P13D 为 per-scenario evidence schema，要求 deterministic fixtures 和 fault injection。
4. 补齐 P13D state ownership、purpose matrix、save call graph 负向扫描。
5. 区分 save path pasteboard read/write、metadata full value read、metadata full value copy。
6. 把 rich text fidelity 和 URL validation 收敛为可执行 helper + fixture contract。
7. 补齐低敏 sanitizer、provider/network/automation denylist 与低敏 failure schema。

本版不进入 Step 5 / Step 6，不引入隐私页 Applications 管理、CLI 广义对象管理、外部 OCR provider、真实系统剪贴板同步、真实 App / TCC / Keychain / System Settings 自动化。

## 2. v1 相对 v0 的范围调整

### 保持不变

- 默认详情展示只读、bounded，不默认读取完整 payload。
- 编辑必须由显式 Edit 进入稳定详情编辑面，hover detail 不承载 dirty editor。
- View 不直接写 payload、summary、search document、FTS、OCR 状态。
- `ClipboardDetailStore` 只持有 draft / UI transaction state，不是持久化事实源。
- Repository 是 payload、派生字段、summary、search document、FTS、content revision 的唯一持久化写入边界。
- 保存默认同一 SQLite transaction；异步 reindex 只作为例外，不默认启用。

### v1 强化

- `ClipboardDetailReadModel.revision` 改为 mutable `contentRevision`，不再使用 Step 1 search document 的 capture revision。
- 保存命令必须带 `expectedContentRevision`，保存结果必须返回 `newContentRevision`。
- OCR user-edited、Vision OCR late completion、search document 更新都必须基于持久化 OCR source / content revision 判断，不能用 View-local 状态推断。
- P13D 必须证明每个场景，而不是只输出汇总布尔值。

## 3. 目标架构概览

推荐新增或调整的核心对象：

| 对象 | 所属 target | 职责 |
| --- | --- | --- |
| `ClipboardDetailReadModel` | BlocksCore | 详情页 bounded read model，包含 `contentRevision`、bounded content、metadata snapshot、可编辑能力和状态。 |
| `ClipboardDetailEditCommand` | BlocksCore | 单一保存命令，包含 record id、expected content revision、编辑类型、draft、purpose、fake clock time。 |
| `ClipboardDetailSaveResult` | BlocksCore | 保存结果，包含 new content revision、contentUpdatedAt、updated read model、search/index 状态和 changed fields。 |
| `ClipboardDetailSaveFailure` | BlocksCore | 保存失败分类，覆盖 revision conflict、invalid URL、rich text fidelity failed、OCR conflict、transaction/reindex failure。 |
| `ClipboardDetailURLValidator` | BlocksCore | 本地 URL 校验 helper，不发网络、不 open URL、不触发系统动作。 |
| `ClipboardRichTextFidelityService` | BlocksCore 或明确 macOS shared helper | 保守 RTF round-trip / representative fidelity gate。不能证明保真则失败。 |
| `ClipboardDetailStore` | BlocksApp | 编辑 draft、dirty、saving、save-failed、record-unavailable、dirty-navigation 状态机。 |
| `ClipboardDetailEditorView` | BlocksApp | 稳定详情编辑面，不使用 hover / 临时 popover 承载 dirty editor。 |
| `p13d_clipboard_detail_edit_checks.py` | tools/verification | Step 4 专属 fail-closed verifier。 |

AppState / AppModel / ClipboardController 只允许提供非事实源 facade、status banner 或入口协调，不持有 detail payload、OCR text、search document、save transaction result 作为事实源。

## 4. Mutable Content Revision

### 4.1 不复用 capture revision

当前 Step 1 search document revision 代表原始捕获身份，来源类似 `changeCount:signatureSHA256_12`。Step 4 不允许把它作为详情编辑的 optimistic concurrency token。

原因：

- 用户编辑 plain text、URL、rich text 或 OCR text 后，原始 capture signature 不应变化。
- stale draft 冲突检测需要针对可变内容，而不是原始捕获。
- detail read model、purpose-scoped cache、preview、search result 失效都需要可变内容版本。

### 4.2 推荐 schema 字段

v4 migration 在 `clipboard_items` 增加：

```text
content_revision INTEGER NOT NULL DEFAULT 1
content_updated_at REAL
```

推荐同时在 `clipboard_search_documents` 增加：

```text
content_revision INTEGER NOT NULL DEFAULT 1
```

含义：

- `clipboard_items.content_revision` 是记录可编辑内容的事实版本。
- `clipboard_items.content_updated_at` 是内容编辑更新时间；可与 `updated_at` 同步，但语义上表示内容事实更新时间。
- `clipboard_search_documents.content_revision` 是 search document 对应的内容版本，用于验证搜索索引是否与内容事实一致。

旧库回填：

- 所有旧记录 `content_revision = 1`。
- `content_updated_at` 优先使用既有 `updated_at`；若旧库无可靠值，使用 `created_at`。
- search document 的 `content_revision` 与对应 `clipboard_items.content_revision` 对齐。

### 4.3 何时推进 contentRevision

必须推进：

- plain text 保存成功。
- URL 保存成功。
- rich text 保存成功。
- OCR user-edited text 保存成功。
- Vision OCR completion 写入新的 OCR text 且未被 user-edited guard 拦截。
- 其他会改变 user-visible content、searchable content 或 derived content 的 repository-level 内容更新。

不推进：

- 仅切换 UI edit/view 状态。
- draft 修改但未保存。
- metadata copy full value。
- tag/favorite 操作本身，除非项目后续明确把 tag token revision 合并到同一 token；Step 4 不这样做。

### 4.4 保存命令与冲突检测

`ClipboardDetailEditCommand` 必须包含：

```swift
struct ClipboardDetailEditCommand {
    let recordID: ClipboardRecord.ID
    let expectedContentRevision: Int64
    let editableKind: ClipboardDetailEditableKind
    let draft: ClipboardDetailDraft
    let purpose: ClipboardPayloadReadPurpose
    let now: Date
}
```

Repository 保存时必须在同一 transaction 内：

1. 读取当前 `content_revision`。
2. 比较 `expectedContentRevision`。
3. mismatch 返回 `revisionConflict`，mutation count 必须为 0。
4. match 后写 payload / derived fields / summary / search document / FTS / updatedAt。
5. `content_revision += 1`。
6. 返回 `newContentRevision` 和基于新事实源构建的 `ClipboardDetailReadModel`。

P13D 必须覆盖：

- `detail_revision_advances_004`：保存成功后 revision 前进。
- `detail_stale_revision_conflict_004`：旧 expected revision 再保存失败且 mutation count 为 0。
- `detail_cache_invalidation_004`：保存后旧 detail read cache / preview / search result 不再作为唯一事实源。

## 5. Schema Migration v4

### 5.1 migration runner

`MigrationRunner` 必须支持 v4：

- v3 -> v4 增加 content revision、OCR source 等字段。
- `currentVersion > 4` 才进入 unsupported。
- migration 应幂等或通过现有 migration 框架保证只执行一次。
- P13D / P9A 需要提供旧 v3 fixture DB smoke，不读真实用户数据库。

### 5.2 OCR source 字段

`clipboard_search_documents` 增加：

```text
ocr_text_source TEXT NOT NULL DEFAULT 'none'
ocr_user_edited_at REAL
ocr_locked_content_revision INTEGER
```

推荐枚举：

```swift
enum ClipboardOCRTextSource: String, Codable {
    case none
    case vision
    case userEdited
    case ignoredLateVision
}
```

约束：

- 默认值必须是 `none`，不能是 `vision`。
- 只有旧库中 `ocr_status = succeeded` 且 `ocr_text` 非空时，migration 才可回填 `vision`。
- `userEdited` 只能由 Step 4 detail edit save command 写入。
- `ignoredLateVision` 只能在 late completion 被 user-edited guard 拒绝时写入或记录为低敏事件；如果不持久化，也必须在 P13D evidence 中表达被拒绝事实。

建议 backfill：

```sql
UPDATE clipboard_search_documents
SET ocr_text_source = 'vision'
WHERE ocr_status = 'succeeded'
  AND ocr_text IS NOT NULL
  AND TRIM(ocr_text) != '';
```

其他 pending、failed、succeeded empty、notRequired、非图片记录保持 `none`。

### 5.3 必须同步修改的读写点

技术方案要求开发阶段明确触达：

- `ClipboardSearchDocument` initializer / Codable / SQLite decode。
- `bindings(for:)` 或等价 SQL binding。
- `loadSearchDocument`。
- `upsertSearchDocument`。
- `updateOCRResult`。
- `rebuildSearchDocuments`。
- 任何构造 detail read model / metadata snapshot / search document fixture 的位置。

`updateOCRResult` 必须检查：

- 当前 OCR source 是否 `userEdited`。
- incoming OCR 对应的 expected content revision 是否仍有效。
- 如果用户已编辑 OCR text，则 Vision retry / late completion 不得静默覆盖。

### 5.4 v4 fixture 要求

P13D / P13A 必须至少覆盖：

- v3 old no OCR -> `ocr_text_source = none`。
- v3 OCR succeeded non-empty -> `vision`。
- v3 OCR pending -> `none`。
- v3 OCR failed -> `none`。
- v3 OCR succeeded empty -> `none`。
- Step 4 user-edited OCR save -> `userEdited`。
- user-edited 后 retry / late completion -> 不覆盖，输出 ignored / blocked 证据。

## 6. Detail Read Model

`ClipboardDetailReadModel` 是详情页默认读取模型，不是完整 payload dump。

建议字段：

```swift
struct ClipboardDetailReadModel: Equatable, Sendable {
    let recordID: ClipboardRecord.ID
    let contentRevision: Int64
    let captureIdentityRevision: String
    let kind: ClipboardContentKind
    let title: String
    let boundedPreview: ClipboardBoundedPreview
    let metadata: ClipboardMetadataSnapshot
    let editableCapabilities: ClipboardDetailEditableCapabilities
    let ocrState: ClipboardDetailOCRState
    let searchIndexState: ClipboardDetailSearchIndexState
    let updatedAt: Date
    let contentUpdatedAt: Date?
}
```

规则：

- `contentRevision` 用于编辑冲突、cache invalidation、save result。
- `captureIdentityRevision` 只用于调试原始捕获身份，不参与 detail edit conflict。
- 默认模型不包含完整 URL query/path、完整 file path、完整 OCR 文本、RTF body、图片 base64、真实剪贴板正文。
- `boundedPreview` 和 `metadata` 均必须可被低敏 sanitizer 验证。

## 7. Metadata Snapshot 与 Full Value 动作

### 7.1 metadata snapshot

默认 metadata snapshot 只允许：

- bounded display value。
- value kind / availability。
- length / line count / byte count / host category / scheme / type category。
- createdAt / updatedAt / contentUpdatedAt。
- tag/favorite/source 的 bounded label。

默认 snapshot 不允许：

- 完整 URL。
- 完整 file path。
- OCR 原文。
- RTF body。
- 图片 / base64。
- secret 命中原文。

### 7.2 full value read 与 copy 的区别

`detailFullValueRead` 只表示用户显式动作下读取完整值，用于展开、查看或准备复制 payload。它不等同于写系统 pasteboard。

如果实现“复制完整值”，必须使用单独显式动作和 purpose，例如：

```swift
case detailCopyFullValue
```

规则：

- 默认布局、tooltip、VoiceOver label 不触发完整值读取。
- copy full value 必须有 `copying`、`copied`、`copy failed` 低调反馈。
- P13D 使用 fake pasteboard / spy 验证 copy，不写真实系统 pasteboard。
- P13D 分开输出 `full_value_read_attempts`、`full_value_copy_attempts`、`pasteboard_read_attempts`、`pasteboard_write_attempts`。
- save path 的 pasteboard read/write 必须始终为 0。

## 8. Purpose Matrix

### 8.1 正向 purpose

Step 4 必须存在或等价提供：

| purpose | 使用场景 | 允许读取 | 禁止 |
| --- | --- | --- | --- |
| `detailEditRead` | 用户显式进入编辑态，构造 draft。 | 当前 editable content。 | 默认列表、hover、search、provider、paste。 |
| `detailFullValueRead` | 用户显式查看完整 metadata value。 | 被请求的单项完整值。 | 保存事务、默认 layout、tooltip 自动预取。 |
| `detailEditSave` | Repository 保存命令内读取当前事实源并写入。 | 当前 payload / search doc / revision。 | 系统 pasteboard、provider、automation。 |
| `detailCopyFullValue` | 可选，用户显式复制完整值。 | 被复制的单项完整值。 | 与保存路径混用、真实 pasteboard 测试。 |

### 8.2 禁止复用的 purpose

Step 4 detail edit / metadata full value / save path 禁止复用：

- `.hoverDetail`
- `.paste`
- `.copyPlainText`
- `.translationPreview`
- `.ocrInput`
- `.searchIndex`
- provider / route / multimodal 相关 purpose

P13D 必须输出 purpose matrix，并对每个 forbidden purpose 在 Step 4 路径中的复用次数要求为 0。

## 9. 单一保存命令与事务边界

### 9.1 call graph

保存路径必须收敛为：

```text
ClipboardDetailEditorView
  -> ClipboardDetailStore.save()
  -> ClipboardRepository.saveDetailEdit(command:)
```

允许 AppState / AppModel 做：

- 打开详情入口。
- status banner。
- 非事实源 facade。
- record missing / close panel 的外层协调。

禁止 AppState / AppModel / ClipboardController 做：

- 持久化 detail payload。
- 持久化 OCR text。
- 直接写 search document / FTS。
- 保存 detail save result 作为事实源。
- 在保存路径间接调用 paste / auto-paste / copy coordinator。

### 9.2 同步 transaction 默认路径

`saveDetailEdit(command:)` 默认在同一 SQLite transaction 内完成：

1. record existence + expected content revision 校验。
2. editable kind 校验。
3. payload / derived fields 写入。
4. summary / preview source 更新。
5. search document 更新。
6. FTS 更新。
7. `updated_at` / `content_updated_at` 更新。
8. content revision 前进。
9. 构建 save result / detail read model。

如果任何步骤失败：

- transaction rollback。
- mutation count 为 0，或进入明确 pending / failed 例外状态。
- UI 保留 draft。
- P13D 输出 low-sensitive failure。

### 9.3 异步 reindex 口径

Step 4 默认不启用异步 reindex。

如果开发证明现有 search/FTS 架构无法同步完成，才允许提出异步 reindex 例外，并必须由项目负责人接受：

- 成功保存但索引未完成：`saved-index-pending`。
- 索引失败：`reindex-failed` + retry / recovery。
- P13D 输出 per-scenario evidence。

如果本阶段未启用异步 reindex，P13D 必须输出：

```json
{
  "async_reindex_enabled": false,
  "not_applicable_reason": "Step 4 uses synchronous repository transaction for payload, search document and FTS updates."
}
```

## 10. Plain Text / URL / Rich Text / OCR Text 编辑策略

### 10.1 Plain text

保存 plain text：

- 写入 text payload。
- 清理不再适用的 URL / rich text / image editable derivation。
- 更新 summary、bounded preview、search document、FTS、updatedAt、contentUpdatedAt、contentRevision。
- 不写系统 pasteboard。

空文本保存口径：

- v1 推荐允许保存空文本。
- 阅读态 summary 显示 `Empty text` 或本地化等价文案。
- 正文搜索不匹配空 body，但标签、收藏、来源、类型、时间仍可检索。
- 如果开发或项目负责人后续决定禁止空文本，必须作为 field-level validation，保存前失败且 mutation count 为 0。

### 10.2 URL

新增 `ClipboardDetailURLValidator` 或等价 helper。

默认通过：

- `https://example.test/path?q=fixture`
- `http://localhost:8080/path`
- `mailto:user@example.test`

默认拒绝：

- empty / whitespace-only。
- relative path。
- missing scheme。
- control character。
- `http:///path`。
- `file:`。
- custom scheme，除非项目负责人后续明确 allowlist。

规则：

- 不自动补 `https://`。
- 不发网络请求。
- 不 open URL。
- 不触发 App launch / Finder / System Settings。
- evidence 不输出 URL 全文；只输出 scheme、synthetic host category、length、hash、fixture id。

### 10.3 Rich text

新增 `ClipboardRichTextFidelityService` 或等价 helper。

约束：

- Step 4 不是完整富文本编辑器，不提供 rich text toolbar。
- 用户编辑 rich text 的 plain string draft。
- helper 尝试在代表性范围内保留原 RTF 的结构性格式。
- 只要无法证明代表格式保留，就返回 `richTextFidelityFailed`，不得静默降级 plain text payload。

P13D rich text evidence 必须逐项输出：

- `link_preserved`
- `paragraphs_preserved`
- `inline_style_preserved`
- `list_representation_preserved`
- `kind_remains_rich_text`
- `plain_text_derivation_updated`

仅比较 plain text 不足以通过 rich text fidelity。

BlocksCore / AppKit 边界：

- 优先把 helper 放在 BlocksCore 可测试边界内。
- 如果 RTF read/write API 在当前 macOS toolchain 需要 AppKit，允许在 macOS-only BlocksCore target 明确引入 AppKit，但 Blocks App 与 BlocksCLI build 必须同时作为 gate。
- 不允许在 View 层单独做 rich text fidelity 判定后绕过 Repository 保存校验。

### 10.4 OCR text

Step 4 只允许编辑 OCR 派生文本，不修改图片 payload。

保存 OCR user-edited text：

- 写 search document OCR text / searchable text。
- `ocr_text_source = userEdited`。
- 写 `ocr_user_edited_at`。
- 写 `ocr_locked_content_revision` 或等价 guard token。
- 更新 summary / preview / FTS / updatedAt / contentUpdatedAt / contentRevision。
- 图片 payload 不变。

Vision retry / late completion：

- 如果当前 OCR source 为 `userEdited`，不得静默覆盖。
- 可以返回 blocked / needs confirmation / ignored late completion，具体 UI 由 PRD / UI 合同限定。
- P13D 必须证明 late completion 不覆盖 user-edited text。

## 11. Pasteboard / Provider / Automation 边界

### 11.1 保存路径 pasteboard read/write

Step 4 保存路径不得读写真实系统 pasteboard。

P13D 必须对 save path 输出：

```json
{
  "pasteboard_read_attempts": 0,
  "pasteboard_write_attempts": 0
}
```

static / call graph denylist 至少覆盖：

- `NSPasteboard.general`
- `clearContents`
- `setString`
- `setData`
- `writeObjects`
- `string(forType:)`
- `string`
- `data(forType:)`
- `pasteboardItems`
- `readObjects`
- `availableType`
- `ClipboardAutoPasteCoordinator`
- `pasteClipboardRecord`
- `copyClipboardRecordAsPlainText`

P13D 不得为了验证“不读写”而读取真实系统剪贴板内容。

### 11.2 metadata copy full value

copy full value 是用户显式动作，不属于保存事务。

如果实现：

- 走独立 adapter / purpose。
- 使用 fake pasteboard / spy 验收。
- 输出 copy feedback 状态，不输出完整值。
- 不影响 save path 的 pasteboard read/write = 0。

### 11.3 provider / network / automation denylist

Step 4 新增或 touched files 中，detail edit / metadata / URL validation / rich text / OCR text edit 路径不得引入：

- `URLSession`
- provider route 直连
- image upload / multimodal provider call
- `Authorization`
- `Bearer`
- shell / `Process`
- AppleScript
- CGEvent
- Accessibility automation
- ScreenCaptureKit
- Finder / System Settings 打开动作

已有 unrelated provider / automation 代码不因存在而失败；P13D 应限定在 Step 4 新增 / touched files 和 save/detail call graph。

## 12. Stable Detail Editor 与 UI 状态合同

### 12.1 默认承载形态

Step 4 默认采用稳定详情编辑面：

- 推荐 in-panel detail editor。
- 可以是稳定 sheet / pane，但不能跟随 hover 生命周期关闭。
- 禁止 hover preview、hover detail、临时 popover 承载 dirty editor。

Batch A 需要先引入 `ClipboardDetailStore` 空状态机 skeleton 和 stable editor 入口 placeholder，避免到后期才发现 Store / UI 状态无法接合。

### 12.2 fixed action bar

编辑器底部 action bar 固定承载：

- Save。
- Cancel。
- Retry / Save failed。
- saving spinner。
- transaction-level error。

P13D / evidence manifest 要覆盖：

- `view`
- `edit-clean`
- `dirty`
- `invalid`
- `saving`
- `save-failed`
- `record-unavailable`

要求 action bar 高度和主要按钮位置稳定，不挤压 2/4 行编辑区和 metadata 区。

### 12.3 dirty navigation

切换记录、关闭详情、切换筛选、离开编辑器时，如果有 dirty draft：

- 默认焦点在 `Continue Editing` 或等价安全动作。
- `Discard Changes` 标记 destructive。
- `Save and Continue` 失败时保留草稿，停留当前记录，进入 `save-failed`，不执行导航。
- Esc、sheet close、点击外部默认等价继续编辑 / 取消导航，不丢草稿。

### 12.4 keyboard / accessibility evidence

P13D evidence manifest 增加低敏分组：

- `keyboard`：Edit 可聚焦、进入编辑态后焦点进入编辑区或首个编辑控件、Save/Cancel/Retry 可达、dirty sheet 默认焦点安全动作、Esc/Cancel 语义一致。
- `accessibility`：状态 label、字段 label/value、invalid URL 错误、saving/save failed/reindex failed、Save/Cancel/Retry 可用性、metadata full value/copy affordance。

该 evidence 不能声称真实 VoiceOver 已实测；真实 VoiceOver 可作为后续验收残余。

## 13. P13D Verifier v1

### 13.1 基本规则

脚本：`tools/verification/p13d_clipboard_detail_edit_checks.py`

P13D 必须 fail closed：

- 缺脚本 -> fail。
- 缺任何必测 scenario -> fail。
- 缺 fixture id -> fail。
- 缺 mutation count -> fail。
- 缺 sanitizer result -> fail。
- 缺 purpose matrix -> fail。
- 缺 state ownership -> fail。
- 缺 call graph negative scan -> fail。
- 输出命中敏感 pattern -> fail。
- baseline red 缺证据 -> fail。

P13D 不运行真实 App，不读真实用户 DB，不读写真实系统剪贴板，不触发 TCC / provider / Keychain / System Settings / Finder / restart。

### 13.2 deterministic fixture 与 fault injection

P13D 使用 isolated temp database / fixture repository：

- deterministic record id。
- deterministic content revision。
- fake clock / deterministic updatedAt。
- synthetic content。
- 每个 fixture run 前后清理 temp state。
- 输出 temp path 必须脱敏为 `<TMP>` 或 relative category。

fault injection 至少支持：

- search document write fail。
- FTS write fail。
- transaction rollback。
- record deleted before save。
- payload missing。
- expectedContentRevision mismatch。
- late OCR completion。

### 13.3 per-scenario evidence schema

推荐输出：

```json
{
  "gate": "P13D",
  "status": "pass",
  "scenarios": [
    {
      "scenario_id": "detail_text_save_success_004",
      "fixture_id": "detail_text_alpha_004",
      "category": "save_success",
      "result": "pass",
      "mutation_count": 1,
      "content_revision_before": 1,
      "content_revision_after": 2,
      "pasteboard_read_attempts": 0,
      "pasteboard_write_attempts": 0,
      "full_value_read_attempts": 0,
      "full_value_copy_attempts": 0,
      "failure_reason": null,
      "sanitizer": "pass"
    }
  ],
  "state_ownership": {},
  "purpose_matrix": {},
  "call_graph": {},
  "denylist": {},
  "failures": []
}
```

### 13.4 必测 scenario

| scenario | 必须证明 |
| --- | --- |
| `detail_text_save_success_004` | text payload、summary、search document、FTS、updatedAt、detail read model、contentRevision 一致。 |
| `detail_text_empty_save_004` | 空文本口径一致，summary 为 `Empty text` 或 field validation mutation 0。 |
| `detail_url_valid_https_004` | valid https 可保存，kind 保持 URL。 |
| `detail_url_valid_localhost_004` | localhost http 可保存，不发网络。 |
| `detail_url_valid_mailto_004` | mailto 可保存。 |
| `detail_url_invalid_empty_004` | empty 不保存，mutation 0。 |
| `detail_url_invalid_relative_004` | relative 不保存，mutation 0。 |
| `detail_url_invalid_missing_scheme_004` | missing scheme 不自动补全，mutation 0。 |
| `detail_url_invalid_control_char_004` | control char 不保存。 |
| `detail_url_invalid_file_004` | file URL 默认拒绝。 |
| `detail_url_invalid_custom_scheme_004` | custom scheme 默认拒绝。 |
| `detail_rtf_format_004` | link、paragraph、inline style、list、kind、plain text derivation 逐项通过。 |
| `detail_rtf_fidelity_failure_004` | 不能证明保真时失败且无 mutation。 |
| `detail_ocr_user_edited_retry_004` | user-edited 后 retry 不静默覆盖。 |
| `detail_ocr_late_completion_ignored_004` | late Vision completion 被拒绝或记录 ignored。 |
| `detail_save_search_document_fail_004` | search document failure rollback 或进入明确 pending/failed。 |
| `detail_save_fts_fail_004` | FTS failure rollback 或进入明确 pending/failed。 |
| `detail_transaction_rollback_004` | 中途失败后 payload/summary/search/FTS/updatedAt 不部分提交。 |
| `detail_record_deleted_before_save_004` | record-unavailable，draft 不写到其他记录。 |
| `detail_payload_missing_004` | payload missing 返回明确 failure，不自动创建未知 payload。 |
| `detail_revision_advances_004` | 成功保存后 contentRevision 前进。 |
| `detail_stale_revision_conflict_004` | stale expected revision 返回 conflict，mutation 0。 |
| `detail_cache_invalidation_004` | 保存后旧 cache / preview / search result 失效。 |
| `detail_dirty_navigation_004` | continue editing / discard / save and continue failure 路径有低敏证据。 |
| `detail_pasteboard_save_no_read_write_004` | 四类保存 read/write attempts 均为 0。 |
| `detail_full_value_read_004` | full value read 只在显式动作下发生，不进入默认 snapshot。 |
| `detail_full_value_copy_fake_pasteboard_004` | copy full value 使用 fake pasteboard / spy，反馈可见。 |
| `detail_async_reindex_not_applicable_004` | 未启用异步 reindex 时输出 not applicable reason。 |
| `detail_v3_to_v4_migration_004` | v3 fixture DB migration 到 v4，content revision / OCR source 正确。 |

### 13.5 state ownership 输出

P13D 至少输出：

```json
{
  "state_ownership": {
    "appstate_detail_fact_source_clear": true,
    "appmodel_detail_fact_source_clear": true,
    "controller_detail_fact_source_clear": true,
    "detail_store_draft_only": true,
    "repository_persistent_fact_source": true
  }
}
```

负向扫描必须覆盖：

- AppState / AppModel / ClipboardController 未新增 full detail payload fact。
- 未新增 OCR text fact。
- 未新增 search document fact。
- 未新增 save result 持久事实源。

### 13.6 purpose matrix 输出

P13D 至少输出：

```json
{
  "purpose_matrix": {
    "positive": {
      "detailEditRead": true,
      "detailFullValueRead": true,
      "detailEditSave": true
    },
    "negative_reuse_count": {
      "hoverDetail": 0,
      "paste": 0,
      "copyPlainText": 0,
      "translationPreview": 0,
      "ocrInput": 0,
      "searchIndex": 0,
      "provider": 0
    }
  }
}
```

如果实现 `detailCopyFullValue`，也要列为 positive explicit action。

### 13.7 call graph 输出

P13D 至少证明：

- View -> `ClipboardDetailStore.save()`。
- Store -> `ClipboardRepository.saveDetailEdit(command:)`。
- save call graph 不可达 paste / auto-paste / provider / network / automation path。
- AppModel 只做非事实源 facade / status。

## 14. 低敏 Sanitizer 与 Failure Schema

### 14.1 forbidden pattern

P13D stdout、stderr、JSON output、evidence manifest、failure detail、fixture snapshot 均需过 sanitizer。

禁止输出命中原文。至少扫描 pattern label：

- `Authorization`
- `Bearer`
- `Basic`
- `X-API-Key`
- `api_key`
- `access_token`
- `refresh_token`
- `id_token`
- `sk-`
- `sk_proj`
- `sk-proj`
- `password`
- `passwd`
- `pwd`
- `otp`
- `verification code`
- `验证码`
- `2fa`
- `mfa`
- `BEGIN PRIVATE KEY`
- `BEGIN RSA PRIVATE KEY`
- `BEGIN OPENSSH PRIVATE KEY`
- `cookie`
- `session`
- `set-cookie`
- `jwt`
- `webhook`
- token query URL
- `base64`
- `data:image`
- `ocrText` full dump
- `fullOCRText`

### 14.2 failure schema

`failures[]` 只允许：

```json
{
  "rule_id": "string",
  "relative_path": "string",
  "line_or_symbol": "string",
  "pattern_label": "string",
  "count": 1,
  "low_sensitive_reason": "string"
}
```

不允许包含：

- 完整 URL。
- 真实路径。
- OCR 原文。
- rich text body。
- 图片 base64。
- 真实剪贴板正文。
- secret 命中原文。
- 完整 home path。

## 15. 开发批次建议

顶层 Step 仍严格串行；Step 4 内部开发批次可以合并，但建议保留验证层次。

### Batch A：P13D baseline + schema/store skeleton

目标：

- 新增 P13D baseline red。
- 新增 deterministic fixture runner / sanitizer / output schema skeleton。
- 新增 migration v4 skeleton。
- 新增 `contentRevision` / OCR source schema 合同。
- 新增 `ClipboardDetailStore` 空状态机 skeleton。
- 新增 stable editor 入口 placeholder。
- 新增 read model / command / result / failure 类型。
- 新增 detail purpose enum case。

接受：

- P13D 在缺实现时 red，且 failure 低敏。
- Blocks App / BlocksCLI 能编译到 skeleton。

### Batch B：plain text / URL / transaction / pasteboard spy

目标：

- 实现 `saveDetailEdit(command:)` 最小路径。
- plain text save。
- URL validation helper 与 pass/fail fixtures。
- 同步 transaction。
- contentRevision advance / stale conflict。
- pasteboard read/write spy 和 call graph denylist。
- async reindex not applicable 输出。

接受：

- plain text / URL P13D scenarios pass。
- invalid URL mutation 0。
- save path pasteboard read/write 0。

### Batch C：rich text / OCR user-edited / fault injection

目标：

- rich text fidelity helper。
- OCR user-edited source / retry / late completion guard。
- v3 -> v4 OCR source migration fixtures。
- fault injection：search fail、FTS fail、rollback、record missing、payload missing、revision mismatch。

接受：

- rich text 代表 fixture 逐项通过，或 P13D 阻断并要求项目负责人降级接受。
- OCR user-edited 不被 retry / late completion 覆盖。
- transaction failure 不部分提交。

### Batch D：稳定编辑面 / evidence / regression

目标：

- in-panel stable detail editor。
- fixed action bar。
- dirty navigation sheet。
- metadata full value read/copy feedback。
- keyboard / accessibility low-sensitive evidence。
- 多语言、长 URL、长 file path、窄宽度 evidence。
- 回归矩阵。

接受：

- P13D evidence 完整。
- P13A / P13B / P13C / P8 / P8I / P9A / P9B / P11E 回归通过。
- Blocks App / BlocksCLI build 通过。

## 16. 回归矩阵

最终实现接受前建议串行运行：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

规则：

- P13D 是 Step 4 专属 gate，必须排在最前。
- P13D fail 时，不应把后续回归 PASS 写成 Step 4 已通过。
- P13A / P13B / P13C / P8 / P8I / P9A / P9B / P11E 是回归边界，不替代 P13D。

## 17. 风险与取舍

### P1 已收敛

本版已把项目负责人收敛文档列出的 P1 改为可执行合同，未保留进入开发前必须再改的 P1。

### P2 / 残余风险

1. Rich text fidelity 仍是实现风险。P13D 能阻断静默降级，但不能保证复杂富文本编辑体验完整。
2. 真实 VoiceOver、真实 UI、多语言极端布局仍需后续低敏 evidence 或专项验收，技术方案阶段不声称已实测。
3. metadata copy full value 如果实现系统复制，需要 fake pasteboard / spy；不能用真实剪贴板证明。
4. custom scheme、file URL、富文本降级如果后续要放开，必须由项目负责人另行接受。
5. OCR user-edited 与 Vision late completion 的并发路径必须靠持久化 source / content revision 判断，不能退回 View-local 标记。

## 18. 给项目负责人 / 开发派发的建议

- 可以基于本 v1 进入项目负责人复核；复核通过后再派发开发。
- 开发派发建议要求 P13D-first，先证明 baseline red 和 fixture runner，再写保存实现。
- 不建议把 Batch D UI evidence 前置到 blocking 实现，但 stable editor skeleton 和 Store skeleton 应在 Batch A 前置。
- 若 rich text helper 首批无法通过代表 fixture，建议先关闭 rich text 编辑能力，保留只读和 copy full value，不允许静默转 plain text。
- 若同步 search/FTS transaction 被证明不可行，必须先回项目负责人接受异步 reindex 用户态，再继续实现。

## 19. 本轮吸收来源

- 吸收 UI/交互设计师建议：稳定编辑面、fixed action bar、dirty navigation 默认焦点、metadata copy full value feedback、keyboard / accessibility 低敏 evidence、空文本语义。
- 吸收开发建议：mutable content revision、schema v4、OCR source 默认 none、rich text helper、URL validator、Batch A skeleton、异步 reindex not applicable。
- 吸收测试/质量建议：per-scenario evidence、deterministic fixtures、fault injection、pasteboard 间接路径、rich text 逐项结果、低敏输出。
- 吸收代码审查建议：state ownership、purpose matrix、call graph negative scan、AppState/AppModel/ClipboardController 不扩权。
- 吸收安全合规建议：pasteboard read/write 同查、full value read/copy 分离、provider/network/automation denylist、failure schema 低敏。
