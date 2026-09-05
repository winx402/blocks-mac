# Step 1 App 架构师技术方案 v1

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-PRD-v1复核-v0.md`、`项目负责人-技术方案复审收敛-v0.md`
范围：明文展示、搜索底座与系统 Vision OCR
状态：technical-plan-v1

## 1. 结论

Step 1 技术方案 v1 按项目负责人收敛意见补齐开发和验收契约。主线保持不变：

- 有界明文 preview snapshot。
- 可重建 `ClipboardSearchDocument` / FTS read model。
- 本地 macOS Vision OCR 队列与 mock recognizer。
- 低敏日志、CLI、verification JSON 输出边界。
- 旧 Step 4D hardening 门禁迁移为历史 baseline 或 output boundary，不再阻断本阶段“明文优先”目标。

本方案仍严格限定在 Step 1，不引入：

- Step 2 标签 / 收藏。
- Step 3 面板专项布局、hover 安全区、搜索框宽度、选中反馈、单 / 双击设置、卡片密度。
- Step 4 详情编辑、保存 / 取消、富文本编辑、OCR 文本编辑。
- Step 5 隐私页真实 App 清单和 CLI 广义对象管理。
- 外部 OCR provider、多模态 provider OCR、图片上传 OCR。
- 新增 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset、系统设置跳转或复杂权限开关。

## 2. 当前事实源目标

Step 1 完成后的当前事实源必须是：

```text
Clipboard payload / record
  -> ClipboardSearchDocumentBuilder
  -> ClipboardSearchDocument
  -> clipboard_fts projection
  -> ClipboardStore preview/search state
  -> View rendering
```

核心规则：

- `ClipboardSearchDocument` 或等价模型是搜索与 bounded preview 派生内容的唯一当前事实源。
- `clipboard_fts` 只是由 search document 生成的查询投影。
- `clipboard_items.search_text` 如保留，只能作为兼容投影，由同一 builder 派生；不得继续由旧 `searchText(for:payload:)` 独立生成。
- `ClipboardStore.preview(for:)` 不再默认调用 `record.redactedPreview(...)`。
- 非空搜索主路径不再基于 visible/redacted preview、旧 pinned metadata、旧 pinboard display name 或 View 层字符串过滤。
- View 只消费 bounded preview snapshot、search result state 和 row-level OCR state，不批量读取完整 payload。

## 3. 文件与模块职责建议

命名允许开发按现有目录微调，但职责边界应保持：

```text
apps/Blocks/BlocksCore/ClipboardSearchDocument.swift
- ClipboardSearchDocument
- ClipboardContentPreviewSnapshot
- ClipboardOCRState
- ClipboardSearchResultState
- Low-sensitive record/search identifiers

apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift
- record + payload + OCR state -> search document
- bounded text / URL / file URL / rich text plain text / type / source / time token generation
- no View dependency

apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift
- schema migration helpers
- insert/delete/prune/policy redaction/search document/FTS transaction APIs
- OCR state/result persistence APIs
- rebuild/backfill APIs

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardContentAccessPurpose.swift
- high-cost content access classification
- previewBuild/searchIndex/ocrInput/paste/copyPlainText/hoverDetail/translationPreview

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardSearchCoordinator.swift
- Store-facing search query state
- maps repository search result + pending index/OCR counts to UI states

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionTextRecognizer.swift
- protocol
- Apple Vision implementation
- deterministic mock recognizer for tests/verifier fixtures

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift
- persistent claim/retry/cancel/recovery rules
- calls repository transaction APIs for OCR results
```

如果开发选择把部分职责合并到既有文件，P13A 仍应检查职责是否等价存在，而不是只检查文件名。

## 4. Search Document 单一事实源

### 4.1 推荐模型

```text
ClipboardSearchDocument
- recordID
- revision
- updatedAt
- preview: ClipboardContentPreviewSnapshot
- contentText
- richTextPlainText
- urlTokens
- fileTokens
- sourceTokens
- typeTokens
- timeTokens
- ocrText
- ocrStatus
- indexTruncated
- payloadDerivationState

ClipboardContentPreviewSnapshot
- recordID
- revision
- title
- body
- badge
- contentKind
- imageState
- ocrStatus
- isTruncated

ClipboardSearchResultSet
- records
- query
- state: idle / results / empty / emptyIndexing / partialIndexing / failed
- pendingIndexCount
- runningOCRCount
- failedOCRCount
```

`ClipboardSearchDocumentBuilder` 是唯一构建入口。旧 `ClipboardRepository.searchText(for:payload:)` 只能：

- 删除；
- 或变成 thin wrapper，内部委托 builder；
- 或保留为 legacy helper，但不参与当前写入和查询路径。

P13A 必须在以下情况 fail closed：

- 搜索主路径只基于 visible/redacted preview。
- 搜索主路径只基于旧 `pinnedMetadata` / pinboard display name。
- search document 类型存在，但 repository search 或 `ClipboardController.filteredRecords` 绕过它。
- `clipboard_items.search_text` 仍由旧拼接逻辑独立生成。

### 4.2 FTS 与兼容字段

推荐：

- `clipboard_search_documents` 保存当前派生内容。
- `clipboard_fts(record_id, search_text)` 由 search document projection 重建。
- `clipboard_items.search_text` 如短期保留，应由同一 projection 写入，且在开发记录标记为 compatibility projection。

`clipboard_fts` 不保存额外事实。重建 FTS 时必须可从 search document 完整生成。

## 5. Schema Migration 与 Backfill

### 5.1 Schema version

Step 1 应 bump SQLite `PRAGMA user_version` 或项目等价 schema version。若当前开发库为 v1，建议迁移到 v2：

```text
v2 migration:
- create clipboard_search_documents or equivalent derived table
- add OCR state columns/table
- ensure FTS table can be regenerated from search documents
- keep clipboard_items and payload storage intact
```

迁移不得删除旧 records/payloads，不做真实用户内容清洗。

### 5.2 派生表建议

```sql
CREATE TABLE clipboard_search_documents (
    record_id TEXT PRIMARY KEY NOT NULL,
    revision TEXT NOT NULL,
    preview_title TEXT NOT NULL,
    preview_body TEXT NOT NULL,
    preview_badge TEXT NOT NULL,
    content_kind TEXT NOT NULL,
    content_text TEXT,
    rich_text_plain_text TEXT,
    url_tokens_json TEXT,
    file_tokens_json TEXT,
    source_tokens_json TEXT,
    type_tokens_json TEXT,
    time_tokens_json TEXT,
    ocr_text TEXT,
    ocr_status TEXT NOT NULL,
    ocr_error_code TEXT,
    ocr_attempt_count INTEGER NOT NULL DEFAULT 0,
    ocr_last_attempt_at REAL,
    ocr_next_retry_after REAL,
    index_truncated INTEGER NOT NULL DEFAULT 0,
    payload_derivation_state TEXT NOT NULL,
    updated_at REAL NOT NULL
);
```

如果实现选择分表：

- preview snapshot 读取路径必须轻量，列表加载不应带出大字段。
- OCR state 必须能和 search document / FTS 一致更新。

### 5.3 Backfill 策略

打开旧开发期数据库时：

1. 创建缺失表/字段。
2. 扫描缺失 search document 的 records。
3. 只标记为 `pendingIndex` 或等价状态，不在 App 启动、面板打开、搜索输入、滚动路径同步重建全部历史。
4. 后台按固定 batch size rebuild，例如每轮 10 或开发记录固定值。
5. rebuild 失败只记录低敏 error category，并保留记录可见。

backfill 不得阻塞：

- App 启动。
- 面板打开。
- 搜索输入。
- 列表滚动。

## 6. Repository 事务与生命周期一致性

### 6.1 必备 repository API 职责

命名不强制，但应覆盖：

```text
upsertSearchDocument(recordID:payload:ocrState:reason:)
deleteSearchDocuments(recordIDs:)
markSearchDocumentRedacted(recordID:revision:)
updateOCRResult(recordID:revision:result:)
rebuildSearchDocuments(limit:)
loadPendingIndexBatch(limit:)
searchDocuments(query:filters:)
```

这些 API 应由 repository 或 repository extension 提供，View 不直接操作派生表或 FTS。

### 6.2 Insert

`ClipboardRepository.insert(record:payload:)` 或等价路径必须在同一 SQLite transaction 内完成：

1. 写 record。
2. 写 payload / payload reference。
3. 由 builder 生成 initial search document 与 bounded preview snapshot。
4. 写 `clipboard_search_documents`。
5. 写或 replace FTS projection。

失败时 transaction 回滚，不允许出现 record 存在但 search document / FTS 半缺失的成功状态。若 payload 太大或解析失败，应写入降级 search document，而不是跳过派生记录。

### 6.3 Duplicate / dedupe

如果 insert 因 signature dedupe 返回既有 record：

- 不创建新的 search document。
- 不误更新旧 record 的 revision。
- 仅在 payload revision/signature 变化或明确 rebuild reason 时重建既有 search document。

P13A / repository smoke 需要覆盖 duplicate 不误建新派生内容。

### 6.4 Delete / prune

删除或裁剪记录时必须同步处理：

- record。
- payload reference。
- search document。
- FTS rows。
- OCR state。

sidecar file 或外部 payload 文件可在 DB transaction 成功后做 best-effort 删除；DB 当前事实不得依赖 sidecar 删除成功。

### 6.5 Policy redaction

若现有 policy redaction 路径仍存在，不能只清旧 `clipboard_items.search_text`。必须同步：

- 清空或失效 payload 派生字段。
- 清空 `ocr_text`。
- 更新 `ocr_status` / derivation state。
- 删除或重建 FTS，使 redacted record 不再通过旧内容命中。

### 6.6 OCR result update

OCR 完成、失败或 retry 更新必须满足：

- record 仍存在。
- revision 匹配。
- record 未被 deleted。
- record 未被当前 policy redacted。
- OCR text/status 与 search document / FTS 更新在同一 transaction，或有等价一致性边界。

如果 revision 不匹配，丢弃结果并记录低敏 stale result category，不写入旧记录。

## 7. Content Access Purpose

推荐引入中性命名：

```text
ClipboardContentAccessPurpose
- previewBuild
- searchIndex
- ocrInput
- paste
- copyPlainText
- hoverDetail
- translationPreview
```

语义：高成本内容访问的性能、生命周期和审计分类，不再是 Step 4D 的默认隐私 allowlist。

如果开发为降低改动保留 `ClipboardPayloadReadPurpose`：

- 必须在开发记录和 P13A 输出中标明它已重释义。
- 必须补齐 `previewBuild`、`searchIndex`、`ocrInput`。
- 旧 Step 4D “默认 UI 不读 payload”不得继续作为 Step 1 pass 条件。

P13A 应检查 preview/search/OCR 的 payload read 都有明确 purpose 分类，且 View 高频路径没有绕过 purpose 直接批量读 payload。

## 8. Bounded Preview 合同

### 8.1 数据阈值

推荐首版派生数据阈值：

- title：最多 120 characters。
- body：最多 500 characters。
- text / rich text 单字段：默认最多 64 KB。
- search document 总量：默认最多 256 KB。
- image thumbnail：最长边不超过 160 px，后台生成。
- URL：App 内 search document 可有界保存 raw URL；日志/verifier 不输出完整 URL。
- file URL：保存文件名、extension、有界路径摘要；日志/verifier 不输出真实 home path。

超过阈值时设置 `isTruncated` / `indexTruncated`。这是内容有界处理状态，不是错误状态。

### 8.2 UI 可见阈值

派生数据阈值不等于面板可见行数。Step 1 不做卡片密度专项改造，但必须避免明文 preview 撑开现有 UI。

最低 UI 合同：

- row/card/tray 均有 line clamp 或等价约束。
- title 建议 1 行。
- body 建议 2-3 行或等价 clamp。
- 长文本、长 URL、长路径、OCR 状态和操作区不能互相挤压。
- `isTruncated` 可显示轻量提示，但不作为高频错误状态。

### 8.3 各类型 preview 组成

- text：展示可读正文开头，折叠异常空白，不显示“只显示长度”壳。
- rich text：展示 plain text；解析失败时降级为 source/type/time。
- URL：优先 host + path 摘要；不把长 query 撑满列表。
- file URL：优先 lastPathComponent + extension + 有界路径摘要。
- image：展示缩略图或图片状态 + OCR 状态。
- long text：preview 有界、UI clamp、`isTruncated=true`。

## 9. Search Document Builder 标准化

`ClipboardSearchDocumentBuilder` 负责：

- text：清理控制字符、折叠异常空白、生成 contentText。
- rich text：提取 plain text；失败降级。
- URL：生成 raw bounded URL、scheme、host、path segment tokens；query 可本地有界索引，但不是 Step 1 必验用户承诺。
- file URL：生成 lastPathComponent、文件名、extension、bounded path summary。
- source：来源 App 名称、bundle id。
- type：类型词典 token，例如 image / 图片 / link / 链接 / file / 文件。
- time：`YYYY-MM-DD`、UI 可见日期片段、`today/yesterday/今天/昨天` 所需 token。
- OCR：合并 persisted OCR text/status。

RTF plain text 提取如需 AppKit，应放在 BlocksApp adapter；BlocksCore 不引入 AppKit。BlocksCore 可接收已提取的低敏 plain text / parse result。

## 10. Search 状态验收

搜索状态语义：

| state | 触发条件 | 失败条件 |
| --- | --- | --- |
| `idle` | 无查询，展示默认列表 | 无查询时仍显示 loading/error |
| `results` | 查询有命中 | 有命中但被 OCR pending/failed 覆盖为空状态 |
| `empty` | 查询无命中，且相关 index/OCR 已完成 | 仍有 pending/running index/OCR 却显示确定无结果 |
| `emptyIndexing` | 当前无命中，但 reindex 或 OCR 仍 pending/running | 等待 OCR 完成才返回状态 |
| `partialIndexing` | 已有命中，同时仍有 reindex/OCR pending/running | 用处理中状态盖掉已有结果 |
| `failed` | 查询路径整体失败，例如 repository search / FTS query 不可用 | 单条 OCR/index 失败导致全局 failed |

局部 OCR/index failure：

- 不覆盖已有结果。
- 不让搜索框不可用。
- 应在 row-level state 或轻量状态行提示。

搜索 `VISION-004` 时，OCR 未完成可为 `emptyIndexing`；OCR 完成后应为 `results`。搜索正文命中且 OCR 仍 pending 时应为 `partialIndexing`。

## 11. Synthetic Fixture 矩阵

开发和测试应使用同一 fixture 矩阵。最低集合：

| fixtureID | 类型 | 关键字段 | 预期 preview | 预期搜索 | 低敏输出规则 |
| --- | --- | --- | --- | --- | --- |
| `txt_alpha_004` | text | `Alpha roadmap item 004 search baseline` | 可读正文片段，不只显示长度 | `Alpha` 命中 | 不输出完整正文 |
| `url_step1_004` | URL | `https://example.com/blocks/clipboard-step1?token=fixture` | host/path 摘要 | `example.com`、`clipboard-step1` 命中 | 不输出完整 query |
| `rtf_plain_004` | rich text | plain text 含 `Rich Plain 004` | plain text 预览 | `Rich Plain 004` 命中 | 不输出 RTF 原文 |
| `file_url_report_004` | file URL | 文件名 `Report-004.pdf` | 文件名 + 有界路径摘要 | `Report-004`、`pdf` 命中 | 不输出真实 `/Users/...` |
| `image_ocr_success_004` | image | mock OCR `VISION-004` | 图片状态 + OCR 状态 | OCR 完成后 `VISION-004` 命中 | 不输出 base64 / 完整 OCR |
| `image_ocr_failure_004` | image | mock failure `vision_unreadable` | failed + retry | 不让全局搜索失败 | 只输出 error code |
| `image_ocr_retry_004` | image | first fail, retry success | failed -> pending/running -> succeeded | retry 后命中 | 只输出状态转换 boolean |
| `long_text_004` | long text | 超过 preview/index 阈值 | preview 截断但可识别 | 阈值内 token 命中 | 不输出完整长文本 |
| `large_image_004` | large image | synthetic large image | 入队但不阻塞列表 | OCR 不阻塞搜索输入 | 输出尺寸/length |

每个 fixture 至少记录：

- `fixtureID`。
- record kind。
- 关键字段摘要。
- 预期 preview。
- 预期搜索。
- 预期低敏输出规则。

## 12. Vision OCR 队列

### 12.1 模块边界

```text
ClipboardVisionTextRecognizer protocol
- recognizeText(from imageData: Data) async throws -> ClipboardOCRTextResult

AppleVisionTextRecognizer
- BlocksApp implementation
- imports Vision
- uses VNRecognizeTextRequest

MockVisionTextRecognizer
- deterministic states for tests/verifier

ClipboardVisionOCRQueue
- actor or isolated service
- claim, retry, cancel, recovery
- calls repository OCR transaction APIs
```

BlocksCore 不直接依赖 Vision。

### 12.2 状态与恢复

推荐状态：

```text
pending
running
succeeded
failed
```

持久化字段：

- `ocr_status`
- `ocr_text`
- `ocr_error_code`
- `ocr_attempt_count`
- `ocr_last_attempt_at`
- `ocr_next_retry_after`
- `ocr_updated_at`

App 启动恢复：

- `running` 且超出合理窗口：重置为 `pending` 或 `failed`。
- `failed` 保留低敏 error category 和 retry 入口。
- `succeeded` 不重复 OCR，除非 payload revision/signature 变化。

### 12.3 队列策略

- 默认并发：1；后续可评估 2。
- 后台入库 OCR 使用 utility/background。
- 用户点击 retry 可提升优先级，但不阻塞 UI。
- 每轮 claim 固定数量，建议 10 或开发记录固定值。
- 大图进入队列但低优先级；decode 和 Vision request 不在 MainActor 上。
- 首版可不做自动重试；用户 retry 必须支持。

## 13. OCR Mock、输入边界与 Retry UI

### 13.1 Mock recognizer

Mock 必须确定性控制：

- pending：任务已入队但未开始。
- running：mock 持有 continuation/latch，测试主动释放。
- failed：返回低敏 error code。
- retry：先失败，再由用户动作或测试 hook 转为 pending/running，最终成功或再次失败。

Mock 不依赖真实 Vision、真实图片质量、机器速度或系统语言。

### 13.2 OCR 输入边界

OCR 只读取已有 image payload：

- 不读 file URL 指向文件本体。
- 不扫描本地目录。
- 不新增 ScreenCapture / Accessibility / Automation / Full Disk Access / TCC reset / 系统设置跳转。
- 不使用 AppleScript、CGEvent 或自动化动作。
- 不调用 provider。
- 不使用 `URLSession` 外发图片。
- 不触发多模态 provider call。
- 不写 Authorization header 或 image upload path。

P13A 应允许项目中既有 provider/permission 代码存在，但 Step 1 新增或 touched OCR/search/preview 文件不得引入上述路径。

### 13.3 图片条目 Retry UI 合同

图片条目内或强关联位置必须显示 OCR 状态：

- `等待识别图片文字`
- `正在识别图片文字`
- `图片文字已可搜索`
- `图片文字识别失败`

失败时在同一条目或强关联位置提供 `重试识别`。点击后：

- 状态立即变为 pending/running。
- retry 按钮 disabled 或防重复触发。
- 搜索状态行可提示处理中，但不能替代条目内 retry。

局部 OCR failed 不触发全局 search failed。

## 14. URL Query 与多语言 OCR 承诺

Step 1 用户承诺：

- URL 搜索以 host、path segment、可读 URL 文本为主。
- 完整 query 是否本地有界索引属于实现细节，不写入用户可见承诺和必验项。
- OCR 承诺是“使用本机系统能力识别图片文字并进入搜索”，不承诺所有语言、所有图片、所有方向都准确识别。
- 必验 OCR fixture 使用低敏稳定 token，例如 `VISION-004`。

多语言 OCR 准确率、复杂图片质量、URL query 精细拆词可作为 P2 观察或后续优化。

## 15. 设置页负向 Token / Key

Step 1 active UI 必须移除或重命名：

- `settings.clipboardHardening.storage`
- `settings.clipboardHardening.redactedPolicy`
- `settings.clipboardHardening.redactedPolicyDetail`
- `settings.clipboardHardening.allowlist`
- `settings.clipboardHardening.allowlistDetail`
- `clipboard.hardening.state.redacted.title`
- `clipboard.hardening.state.redacted.detail`
- active UI 中的 `redacted preview`
- active UI 中的 `payload 不可见`
- active UI 中的 `只显示字符数` / `只显示长度`
- active UI 中的 `隐藏摘要`
- active UI 中的 `metadata-first` 或等价默认遮挡说明

可保留但需重命名的概念：

- repository unavailable / empty / filtered 状态。
- storage normal / item count 状态。
- hover loading / unavailable 状态。

建议 namespace：

- `clipboard.repository.state.*`
- `clipboard.preview.state.*`
- `settings.clipboardStorage.*`

旧 pinned/pinboard 设置不属于 Step 1 主动清理范围，除非它们直接参与明文展示冲突 UI。

## 16. 低敏输出 Schema 与 Forbidden Pattern

### 16.1 默认输出 schema

Verifier、smoke、日志、CLI、开发记录和验收记录默认只输出：

- relative path。
- suite。
- boolean。
- count。
- fixture id。
- record id short hash / suffix。
- length。
- duration。
- error category / error code。
- OCR/search state label。

失败详情也必须走 sanitizer，不能只在 PASS 输出时低敏。

### 16.2 Forbidden token / pattern

P13A / sanitizer 至少扫描：

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
- `/Users/`
- `file:///Users/`
- `base64`
- `data:image`
- full OCR 字段名，例如 `ocrText`、`fullOCRText`
- provider raw request / response
- multipart image upload

P13A 输出 pattern label、字段名、计数和相对路径即可，不输出命中的原文。

### 16.3 CLI 边界

Step 1 不要求新增 CLI 搜索。若实现触及 CLI：

- `--help`、错误输出、默认 list/search 不打印完整 payload。
- 默认返回 preview、length、type、source、timestamp、ocrStatus 等有界字段。
- 完整内容必须通过显式参数或独立 action 触发，并支持 limit / pagination / max characters。

## 17. P13A 与旧门禁迁移

### 17.1 新门禁

新增：

- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`

P13A 是 Step 1 当前事实源门禁。

### 17.2 Baseline red / implementation green

开发顺序要求：

1. Step 1A-0 先新增 P13A baseline red。
2. baseline red 必须因当前旧事实源失败，例如 redacted preview、visible filter、旧 hardening settings、旧 FTS fact source。
3. 实现后 P13A green。
4. P13A 输出 `current_evidence` 只引用 PRD v1、技术方案 v1、当前代码和 fixture。
5. 旧 003 / Step 4D 文档只能进入 `baseline_reference`，不能参与 `ok`。

### 17.3 最低断言

P13A 最低断言：

1. 脚本自身存在且可执行。
2. 新 Swift 文件 target membership 可解析。
3. `ClipboardSearchDocument` / `ClipboardContentPreviewSnapshot` / OCR state 或等价类型存在。
4. `ClipboardSearchDocumentBuilder` 或等价 builder 是唯一 search text / preview snapshot 构建入口。
5. `clipboard_fts` 由 search document projection 生成。
6. `clipboard_items.search_text` 如存在，只作为兼容投影，且由同一 builder 派生。
7. `ClipboardStore.preview(for:)` 不再默认调用 `record.redactedPreview(...)`。
8. 面板 row/card/tray 主路径不批量 `readPayload`、不全量 image decode、不同步 OCR。
9. 非空搜索主路径不只调用 `ClipboardController.filteredRecords(query:)` 做 visible string filter。
10. 搜索主路径绕过 search document / FTS / read model 时 fail。
11. search fields 覆盖 content、rich、url、file、source、type、time、ocr、status。
12. `idle`、`results`、`empty`、`emptyIndexing`、`partialIndexing`、`failed` 有可测状态。
13. repository insert/delete/prune/policy redaction/OCR update 有 search document + FTS 一致性证据。
14. duplicate/dedupe 不误建新 search document。
15. `ClipboardContentAccessPurpose` 或重释义后的 purpose 覆盖 previewBuild/searchIndex/ocrInput/paste/copyPlainText/hoverDetail/translationPreview。
16. OCR recognizer protocol、Apple Vision implementation、mock/test hook 存在。
17. Vision import 不进入 BlocksCore。
18. OCR mock 可稳定控制 pending/running/failed/retry。
19. OCR 输入只来自 image payload，不读 file URL 本体、不扫描目录。
20. Step 1 新增或 touched OCR/search/preview 文件不引入新增权限、provider upload、Authorization header、image upload、多模态 provider call、系统设置跳转或自动化动作。
21. 图片条目内或强关联位置存在 OCR status + retry 合同。
22. Settings active UI 不引用 hardening/redacted 负向 token。
23. low-sensitive output scan 覆盖 PASS 和 FAIL 输出。
24. current evidence only：旧 003 / Step 4D 文档不参与 ok。

### 17.4 旧门禁迁移

| 脚本 | Step 1 定位 | 必改方向 |
| --- | --- | --- |
| `p11e_clipboard_hardening_checks.py` | 历史 baseline 或 output boundary check | 不再要求默认 UI 不读 payload / redacted read model；保留 no provider、no sensitive output、purpose-classified access |
| `p8_clipboard_product_polish_checks.py` | 当前 clipboard 产品展示门禁 | `redacted_card_preview` 改为 bounded plaintext preview；`no_default_payload_or_summary` 改为 no unbounded View payload read |
| `p8i_settings_clipboard_system_checks.py` | Settings clipboard system 门禁 | `clipboard_hardening_settings` 改为 hardening negative token removed + storage/performance retained |
| `p9a_clipboard_repository_storage_smoke.py` | Repository smoke | 补 search document / OCR state / FTS insert-update-delete smoke；保持低敏输出 |
| `p9b_clipboard_appstate_repository_integration_checks.py` | AppState/Repository integration | `record.redactedPreview` / metadata-first 断言迁移为 bounded preview + search document + content access purpose 分类 |

迁移后，如果旧 redacted/hardening 断言仍参与 Step 1 `ok`，应 fail closed。

## 18. 性能验收

### 18.1 结构性门禁

P13A 或相关 verifier 必须确认：

- panel open 主路径没有同步 OCR。
- search input 主路径没有同步 OCR。
- scroll 主路径没有批量 `readPayload`。
- scroll 主路径没有全量 image decode。
- Vision request 不在 MainActor 上执行。
- backfill 不阻塞 App 启动或面板打开。

### 18.2 事件化门禁

Mock OCR running hold 时：

- preview 和 image state 必须先返回。
- search state 必须先返回 `emptyIndexing` 或 `partialIndexing`。
- UI 不能等待 mock release。

### 18.3 最小数值 smoke

开发记录需要固定一次低敏 smoke：

- 样本规模，例如 100 条 mixed fixture、10 张 large image。
- 构建配置。
- 机器环境摘要。
- 首屏可见时间。
- 搜索状态返回时间。
- OCR 队列开始时间。
- OCR running hold 下 preview/search 是否先返回。

具体毫秒阈值由开发记录和测试/质量共同确认；技术方案阶段不预设硬数值。

## 19. 可访问性验收

最低合同：

- OCR 状态有文本 label，不只靠颜色、图标或 spinner。
- Retry 操作可键盘聚焦和触发。
- VoiceOver 可读出 “图片文字识别失败，重试识别” 或等价文案。
- 搜索空状态、索引中状态、局部失败提示、全局失败状态都有文本。
- 搜索从 `emptyIndexing` 到 `results` 更新时不抢走搜索框焦点。
- Retry 后状态文案立即更新。

这些属于 Step 1 状态可用性，不是 Step 3 面板视觉专项打磨。

## 20. 开发子批次建议

### Step 1A-0：P13A baseline red

范围：

- 新增 P13A 骨架。
- 接入低敏 output schema 和 forbidden pattern。
- 证明当前代码因旧 redacted/search/hardening 路径失败。

验收：

- P13A 可执行。
- baseline red 输出低敏。
- 旧 003 / Step 4D 仅列入 `baseline_reference`。

### Step 1A：Search document 与 bounded preview 基础

范围：

- schema migration。
- search document / preview snapshot 类型。
- builder。
- insert/delete/prune/policy redaction transaction。
- bounded preview 替代默认 redacted preview。

验收：

- text、URL、file URL、rich text fixture 入库生成 search document 和 preview。
- FTS 由 search document projection 写入。
- 删除 / prune / redaction 同步清理 search document、OCR state、FTS。
- View 不批量同步读取完整 payload。

### Step 1B：搜索状态与 Store/UI 接入

范围：

- repository search / FTS projection。
- `ClipboardSearchResultSet`。
- `idle/results/empty/emptyIndexing/partialIndexing/failed`。
- Store search state。
- UI 状态文案最小接入。

验收：

- 正文、source、URL host/path、file name、rich plain text、type synonyms、最小时间 token 可命中。
- 非空查询不走 redacted visible string filter。
- 局部 OCR/index failure 不造成全局 failed。

### Step 1C：Vision OCR 队列

范围：

- recognizer protocol。
- Apple Vision implementation。
- Mock recognizer。
- OCR queue。
- OCR result transaction。
- retry UI 合同和 row-level state。

验收：

- `VISION-004` fixture 完成后可搜。
- pending/running/failed/retry 稳定复现。
- retry 后立即反馈。
- 不读 file URL 本体、不扫描目录、不新增权限、不调用 provider。

### Step 1D：设置页清理、输出边界与门禁迁移

范围：

- active hardening/redacted token 清理。
- P8/P8I/P9A/P9B/P11E 迁移。
- P13A implementation green。
- CLI/log/verifier low-sensitive output 回归。
- 性能和可访问性证据收口。

验收：

- P13A PASS。
- 更新后的 P8/P8I/P9A/P9B 不再以旧 hardening 断言作为当前 ok。
- 若保留 P11E，它只作为 output boundary 或 baseline。
- `xcodebuild`、BlocksCLI build、`blocks --help`、`git diff --check` 在最终验收矩阵中执行。

## 21. 最低最终验收矩阵建议

实现完成后建议串行运行并记录：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
```

若保留 P11E：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

但验收记录必须说明其 Step 1 定位，不得作为“默认 UI 不读 payload / redacted read model”阻断。

最终还应运行：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

自动化门禁和技术方案复审不触发真实剪贴板读取、真实 TCC/权限请求、provider call、Keychain、系统设置、Show in Finder、restart 或真实用户截图/OCR。

## 22. 风险

### P1

1. Search document 双事实源：旧 `search_text` / visible filter 与新 search document 共存。缓解：builder 单一入口 + P13A fail closed。
2. Schema/backfill 首次运行卡顿。缓解：pendingIndex + batch rebuild + panel/search/scroll 不等待 backfill。
3. Repository 生命周期不一致：delete/prune/redaction/OCR update 漏清 FTS 或 OCR text。缓解：transaction API + repository smoke。
4. OCR result stale write：revision 变化后旧 OCR 写回。缓解：record exists + revision match + not redacted checks。
5. 旧 hardening verifier 假阳性/假阴性。缓解：P13A 当前事实源；旧 P11E 降级为 baseline/output boundary。
6. 低敏输出污染。缓解：统一 sanitizer，PASS/FAIL 输出、开发记录、验收记录同口径。

### P2

1. Vision OCR 准确率随系统版本、语言、图片质量波动。验收使用 mock 和 `VISION-004`。
2. URL query 和 file path 搜索范围可能和用户预期不一致。Step 1 承诺 host/path/file name，query 不必验。
3. Rich text plain text 提取失败。降级为 type/source/time 可搜并记录低敏 error category。
4. Search ranking 首版粗糙。保持权重集中在 coordinator/repository，后续再调。
5. UI clamp 需要实现后用低敏截图微调。技术方案只要求不撑开、不遮挡、不抢焦点。

## 23. 需要开发 / 测试复审的问题

开发复审：

1. Schema version 和 migration 文件位置。
2. `clipboard_search_documents` 共表还是 preview/search/OCR 分表。
3. Builder 放 Core 还是 App adapter + Core repository 组合。
4. `ClipboardContentAccessPurpose` 是否新命名，或旧 purpose 重释义。
5. OCR queue claim 是否用持久状态字段，是否需要 job 表。
6. P13A target membership 和 forbidden pattern 扫描实现方式。

测试/质量复审：

1. Fixture 矩阵是否覆盖所有 Step 1 必验字段。
2. `emptyIndexing` / `partialIndexing` / `failed` 的 pass/fail fixture。
3. OCR mock running hold 的事件化测试。
4. Performance smoke 的样本规模和记录格式。
5. Low-sensitive output scan 的路径和 pattern。
6. 旧 P8/P8I/P9A/P9B/P11E 迁移后的当前事实源。

UI/交互复审：

1. row/card/tray 可见 clamp。
2. OCR 状态与 retry 文案。
3. 搜索状态行优先级。
4. VoiceOver / 键盘 / 焦点稳定。

安全合规复审：

1. P13A forbidden pattern 覆盖面。
2. OCR 输入边界、无 provider、无新增权限断言。
3. 失败详情 sanitizer。

## 24. 开发前通过条件

项目负责人派发开发前建议确认：

- 本 v1 已吸收收敛文档第 4 节，无 P0/P1 未闭合。
- P13A baseline red / green 规则被接受。
- Search document 单一事实源与旧 `search_text` 兼容策略被接受。
- Schema migration/backfill 不阻塞主路径的策略被接受。
- `ClipboardContentAccessPurpose` 新命名或旧 purpose 重释义二选一被接受。
- Fixture 矩阵、低敏 schema、forbidden pattern、性能和可访问性验收口径被开发 / 测试 / UI / 安全复审。
