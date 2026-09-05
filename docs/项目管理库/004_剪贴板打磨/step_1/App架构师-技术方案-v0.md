# Step 1 App 架构师技术方案 v0

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-PRD-v1复核-v0.md`
范围：明文展示、搜索底座与系统 Vision OCR
状态：technical-plan-v0

## 1. 结论

Step 1 可以按“有界明文预览 + 可重建搜索文档 + 本地 Vision OCR 队列 + 低敏输出门禁”拆解进入技术方案复审。当前代码已经有 `ClipboardStore`、`ClipboardRepository`、payload 持久化、`search_text`/FTS、`ClipboardRecordPreview` 和 Step 4D hardening verifier 基础，但事实源仍明显偏向旧的 redacted/default-deny 模式：

- `ClipboardStore.preview(for:)` 当前走 `record.redactedPreview(...)`。
- `ClipboardController.filteredRecords(...)` 当前基于 redacted preview / pinboard name 做 UI filter。
- `ClipboardRepository.searchText(...)` 当前是单一拼接字符串，缺少结构化 search document、OCR 状态和标准化 token。
- `ClipboardSettingsPane` 当前仍有 `settings.clipboardHardening.*` 段落。
- `p11e_clipboard_hardening_checks.py` / P8 / P8I / P9B 当前仍把默认不读 payload、redacted preview、hardening setting 当作通过条件。

本方案建议不在 View 层直接恢复无界 payload 读取，而是在 repository / store 层建立有界派生内容。这样既满足 PRD 的明文优先，也避免面板打开、滚动、搜索输入和 OCR 状态更新变成不可控同步工作。

## 2. 非目标

本技术方案不覆盖：

- 标签 / 收藏数据模型、标签筛选和设置页标签管理。
- 详情编辑、保存 / 取消、富文本格式保留和 OCR 文本编辑。
- 隐私页真实 App 清单与 CLI 广义对象管理。
- 筛选 hover 安全区、搜索框宽度、选中反馈、单 / 双击显性控件、卡片密度等 Step 3 专项打磨。
- 外部 OCR provider、多模态 provider OCR、图片上传 OCR。
- 新增 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset、系统设置跳转或复杂权限开关。

## 3. 总体架构

推荐分层：

```text
BlocksCore
- ClipboardRepository
- ClipboardSearchDocument / ClipboardContentPreviewSnapshot / ClipboardOCRState
- Search document persistence and FTS update
- Record delete / prune / payload lifecycle consistency

BlocksApp Features/Clipboard
- ClipboardStore
- ClipboardContentPreviewBuilder
- ClipboardSearchCoordinator
- ClipboardVisionOCRQueue
- ClipboardVisionTextRecognizer protocol + Apple Vision implementation

BlocksApp Views/Settings/CLI
- ClipboardFloatingPanelView consumes preview/search state only
- ClipboardSettingsPane removes hardening UI and shows allowed storage/performance settings
- BlocksCLI keeps default output structured and bounded if touched

tools/verification
- New Step 1 verifier replaces old hardening acceptance logic
- Old Step 4D P11E becomes baseline/output-boundary reference only
```

Core rule：payload 可以被 App 内明确路径读取，但面板默认展示、搜索和 OCR 状态展示必须通过可重建、有界的 read model，不允许 View 在高频路径中直接批量读取完整 payload。

## 4. Search Index / Read Model

### 4.1 推荐实体

在 `BlocksCore` 增加或等价表达以下模型：

```text
ClipboardSearchDocument
- recordID
- revision
- updatedAt
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

ClipboardContentPreviewSnapshot
- recordID
- revision
- title
- body
- badge
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

这些名称不是强制代码名，但技术方案应保留这三个职责：搜索文档、面板预览快照、搜索结果状态。

### 4.2 存储位置

推荐在 repository 层新增派生内容表，而不是继续把所有搜索字段塞进 `clipboard_items.search_text`：

```text
clipboard_search_documents
- record_id TEXT PRIMARY KEY
- revision TEXT NOT NULL
- preview_title TEXT NOT NULL
- preview_body TEXT NOT NULL
- preview_badge TEXT NOT NULL
- content_text TEXT
- rich_text_plain_text TEXT
- url_tokens_json TEXT
- file_tokens_json TEXT
- source_tokens_json TEXT
- type_tokens_json TEXT
- time_tokens_json TEXT
- ocr_text TEXT
- ocr_status TEXT NOT NULL
- ocr_error_code TEXT
- ocr_attempt_count INTEGER NOT NULL DEFAULT 0
- index_truncated INTEGER NOT NULL DEFAULT 0
- updated_at REAL NOT NULL
```

FTS 可继续使用现有 `clipboard_fts(record_id, search_text)`，但 `search_text` 应由 `ClipboardSearchDocument` 生成，而不是由 `ClipboardRepository.searchText(for:payload:)` 临时拼接。现有 `clipboard_items.search_text` 可以保留为兼容字段或迁移后停止作为当前事实源；PRD 验收应以新 search document / FTS 为准。

### 4.3 更新事务

以下路径必须更新或删除 search document 与 FTS：

- `ClipboardRepository.insert(record:payload:)`：同一 transaction 内写 record、payload、初始 search document、FTS。
- `deleteRecords(_:)`：删除 record 时同步删除 search document、FTS、OCR 派生状态。
- `applyPolicy(...)` / 裁剪 / 清理：被删除记录同步清理；被 policy redacted 的记录应失效 payload 派生字段和 FTS。
- OCR 完成：更新 `ocr_text`、`ocr_status`、FTS。
- OCR 失败 / retry：更新 OCR 状态和低敏错误；不影响其他字段搜索。
- 后续 Step 4 编辑保存：通过同一 repository API 重建 search document，不在 Step 1 实现编辑。
- 后续 Step 2 标签变更：通过同一 search document 扩展点接入，不在 Step 1 实现标签。

### 4.4 查询路径

推荐替换当前 `ClipboardController.filteredRecords(query:...)` 的搜索职责：

- 空查询：`ClipboardStore` 仍可展示 recent records + preview snapshots。
- 非空查询：`ClipboardStore.search(query:filterState:)` 调用 repository search document / FTS，并返回 `ClipboardSearchResultSet`。
- 现有 format / time / source filter 可以作为 repository 查询条件或搜索后 record filter，但搜索主体不能再是 redacted preview 字符串。
- View 只消费 `records`、`preview(for:)` 和 `searchState`，不直接读 payload 拼搜索文本。

## 5. Bounded Preview

### 5.1 Preview 来源

`ClipboardStore.preview(for:)` 应从 `ClipboardContentPreviewSnapshot` 读取，不再默认调用 `record.redactedPreview(...)`。

生成顺序：

1. 插入记录时，如果 payload 可用，立即生成 bounded preview 和 search document。
2. 旧记录或缺失派生内容时，后台 reindex 任务补齐。
3. UI 请求 preview 时，如果派生内容缺失，返回低成本 fallback，并排队 reindex；fallback 不能是“只显示字符数”或旧 redacted 文案。

### 5.2 Preview 阈值建议

建议首版技术阈值：

- title：最长 120 characters。
- body：最长 500 characters，保留换行但折叠过多空白。
- text / rich text 索引：单字段默认最多 64 KB，search document 总量默认最多 256 KB；超过时设置 `indexTruncated = true`。
- image thumbnail：最长边不超过 160 px；生成在后台完成；列表滚动不做同步 decode。
- file URL 展示：文件名 + 有界路径摘要，不把完整 home path 写入 verification JSON 或验收文档。
- URL 展示：优先 host + path 摘要；完整 URL 仅用于 App 内本地搜索文档，不进入日志和 verifier 输出。

阈值可以由 UI/测试复审微调，但需要在开发记录中固定首版数值，便于性能验收。

### 5.3 Payload 访问边界

保留 `ClipboardPayloadReadPurpose` 的价值，但把语义从“隐私 allowlist”调整为“高成本内容访问分类”。建议扩展或改名为更中性的 `ClipboardContentAccessPurpose`，至少包含：

- `previewBuild`
- `searchIndex`
- `ocrInput`
- `paste`
- `copyPlainText`
- `hoverDetail`
- `translationPreview`

如果开发阶段为了降低改动量暂不改名，也应在文档和 verifier 中说明：purpose 是性能 / 审计分类，不再表示默认 payload 保护。

## 6. Vision OCR 队列与生命周期

### 6.1 模块边界

推荐新增：

```text
ClipboardVisionTextRecognizer protocol
- recognizeText(from imageData: Data) async throws -> ClipboardOCRTextResult

AppleVisionTextRecognizer
- BlocksApp implementation
- imports Vision
- uses VNRecognizeTextRequest

ClipboardVisionOCRQueue
- actor or isolated service
- owns queue, concurrency, retry, cancellation
- calls repository to claim work and persist result
```

`BlocksCore` 不直接依赖 Vision。Core 只定义 OCR 状态、repository 方法和存储模型；真正调用 Vision 的实现放在 BlocksApp。

### 6.2 状态模型

推荐状态：

```text
pending
running
succeeded
failed
```

UI 可把 `failed` 显示为“可重试”。持久化字段建议包含：

- `ocr_status`
- `ocr_text`
- `ocr_error_code`
- `ocr_attempt_count`
- `ocr_last_attempt_at`
- `ocr_next_retry_after`
- `ocr_updated_at`

App 启动恢复规则：

- `running` 且超出合理时间窗口的任务重置为 `pending` 或 `failed`，避免永久处理中。
- `failed` 保留错误类别和 retry 入口。
- `succeeded` 不重复 OCR，除非 payload revision/signature 变化。

### 6.3 队列策略

首版建议：

- 默认并发：1；后续可评估 2，但不要让 OCR 抢占 UI。
- 优先级：userInitiated 只用于用户点击 retry；后台入库 OCR 用 utility/background。
- 批量：每轮最多 claim 固定数量，例如 10 条，避免一次性扫描全部历史。
- 大图 / 长截图：进入队列但允许降级为低优先级；图片 decode 和 Vision request 不在 MainActor 上执行。
- 重试：用户触发 retry 立即把 failed -> pending/running；自动重试需要限流，首版可不做自动重试。

### 6.4 输入边界

OCR 只读取剪贴板历史中已有 image payload：

- 不读 file URL 指向的文件本体。
- 不扫描本地目录。
- 不调用 provider。
- 不请求新的系统权限。
- 不把图片 base64 或 OCR full text 写入日志 / verification JSON。

### 6.5 测试钩子

为避免 OCR 状态测试依赖机器速度，必须引入可注入 recognizer：

- Production：`AppleVisionTextRecognizer`。
- Test / fixture：`MockVisionTextRecognizer`，可返回 success、pending delay、running hold、failure。

Verifier 和测试使用 fixture 图片或 mock，不使用真实用户截图。

## 7. 富文本 / URL / File URL 标准化

### 7.1 标准化入口

推荐新增 `ClipboardSearchDocumentBuilder` 或等价服务，负责从 record + payload + OCR state 生成 search document。不要把标准化逻辑分散在 View、Store 和 Repository 多处。

职责：

- text：清理控制字符、折叠异常空白、生成 contentText。
- rich text：从 RTF 提取 plain text，失败时降级为类型/source/time。
- URL：生成 raw、scheme、host、path segment tokens。
- file URL：生成 lastPathComponent、file name、extension、bounded path summary。
- source：来源 App 名称、bundle id。
- type：类型词典 token。
- time：`YYYY-MM-DD`、UI 可见日期片段、`today/yesterday/今天/昨天` 所需 token。
- OCR：合并 persisted OCR text/status。

### 7.2 Rich Text

技术边界：

- Step 1 只提取 plain text；不保留格式、不编辑、不 round-trip。
- RTF 解析失败不阻断记录显示和搜索。
- RTF plain text 提取可以在 App 层实现后传给 repository，也可以在 Core 中用 Foundation 能力实现；若引入 AppKit 依赖，应留在 BlocksApp，不污染 BlocksCore。

### 7.3 URL

推荐索引：

- 原始 URL 字符串，按长度上限进入 search document。
- scheme。
- host。
- path segments。
- query：首版建议默认不把完整 query 拆成独立 verification 输出；本地搜索文档可保留有界 raw URL，以满足 App 内搜索。技术方案应避免把完整 query 打到日志。

### 7.4 File URL

推荐索引：

- lastPathComponent。
- 文件名。
- extension。
- bounded path summary。

不把完整路径搜索作为 Step 1 必验能力；不在 verification JSON 输出真实 home path。

## 8. 设置页负向 Token / Key 清单

Step 1 需要从当前用户可见 UI 中移除或重命名以下 active token / key：

### 8.1 必须从 active UI 退出

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

### 8.2 可重命名保留

以下概念可以保留，但 namespace 和文案不能继续表达 hardening/redaction：

- repository unavailable / empty / filtered 状态。
- storage normal / item count 状态。
- hover loading / unavailable 状态。

建议重命名到类似：

- `clipboard.repository.state.*`
- `clipboard.preview.state.*`
- `settings.clipboardStorage.*`

### 8.3 不在 Step 1 处理

- `settings.clipboardPolicyPreservePinned` 等旧 pinned / pinboard 相关设置：属于 Step 2 或后续清理，不在 Step 1 强行处理，除非它们直接出现在明文展示冲突 UI 中。
- 历史文档、归档 verifier 或未激活 legacy 字符串：不作为 Step 1 UI 验收事实源，但 active source 不应继续引用它们。

## 9. 日志 / CLI / Verification JSON 低敏输出

### 9.1 日志

新增 OCR / search / index 日志默认只记录：

- recordID 的短 hash 或 suffix。
- kind。
- payload length / OCR text length。
- image pixel size。
- queue state。
- duration_ms。
- error_code / error_category。
- retry_count。

默认禁止记录：

- raw payload。
- full OCR text。
- full URL。
- full file path。
- image base64。
- provider request / response。
- Authorization header、API key、secret、验证码。

### 9.2 CLI

Step 1 不要求新增 CLI 搜索。如果开发为了验证或 agent 调用新增 CLI：

- 默认输出必须结构化、有界。
- 列表 / 搜索默认返回 preview、length、type、source、timestamps、ocrStatus 等字段。
- 完整内容必须通过显式参数触发，例如 `--include-content` 或独立 action。
- 完整内容输出也应支持 `--limit`、分页或最大字符数。
- `--help`、错误输出、默认 list/search 不打印完整 payload。

### 9.3 Verification JSON

新 verifier 输出形态建议：

```json
{
  "ok": true,
  "suite": "p13a_clipboard_plaintext_search_ocr_checks",
  "current_evidence": {
    "prd": ".../产品经理-PRD-v1.md",
    "code_files": []
  },
  "checks": {
    "bounded_preview_default": true,
    "search_uses_index_read_model": true,
    "ocr_queue_async": true
  },
  "counts": {
    "fixtures": 8,
    "ocrPending": 1,
    "ocrFailed": 1
  },
  "sensitive_output_scan": {
    "ok": true,
    "scanned_file_count": 0
  },
  "failures": []
}
```

不要输出 fixture 正文、完整 URL、完整 OCR 文本、完整路径、图片 base64 或真实 home path。需要证明搜索命中时，用 fixture id、record id、length、hash、boolean 表达。

## 10. Step 1 Verifier 与旧 Step 4D 门禁迁移

### 10.1 新增 verifier

建议新增：

- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`

最低断言集合：

1. `ClipboardStore.preview(for:)` 不再默认调用 `record.redactedPreview(...)`。
2. 面板 row/card/tray 使用 bounded preview，不直接在 View 中批量 `readPayload`。
3. 搜索主路径调用 search index/read model，不再只搜 `redactedSearchableText` 或 visible redacted preview。
4. `ClipboardSearchDocument` 或等价模型存在，字段覆盖 content/rich/url/file/source/type/time/ocr/status。
5. repository insert / delete / prune / OCR result update 会更新或删除 search document / FTS。
6. OCR service 使用 macOS Vision 的本地 implementation，且 provider/cloud OCR/token 上传相关路径未接入 Step 1。
7. OCR queue 不在 panel open、search input、scroll 的 MainActor 主路径同步执行。
8. OCR pending/running/succeeded/failed/retry fixture 或 mock hook 可被测试稳定观察。
9. Settings active UI 不引用 `settings.clipboardHardening.*` 或 `clipboard.hardening.state.redacted.*`。
10. CLI / logs / verifier JSON 默认不输出 raw payload、full OCR text、full URL、full file path、image base64。
11. 当前证据只使用 PRD v1、当前代码和 fixture；旧 003 / Step 4D 文档只能进入 `baseline_reference`。

### 10.2 更新现有 verifier

需要更新或降级以下门禁：

- `p11e_clipboard_hardening_checks.py`：不能继续要求 default UI 不读 payload / redacted read model；建议退役为历史 baseline，或改为“output boundary checks”。
- `p8_clipboard_product_polish_checks.py`：`redacted_card_preview`、`no_default_payload_or_summary` 等断言需要改为 bounded plaintext preview 和 no unbounded View payload read。
- `p8i_settings_clipboard_system_checks.py`：`clipboard_hardening_settings`、`panel_hardening_states` 需要改成 storage/performance settings 和 repository state checks。
- `p9b_clipboard_appstate_repository_integration_checks.py`：`record.redactedPreview`、metadata-first read model 断言需要迁移为 search document / bounded preview / purpose-classified high-cost content access。
- `p9a_clipboard_repository_storage_smoke.py`：保留 repository smoke，但补充 search document / OCR state / FTS 更新 smoke。

迁移原则：旧 Step 4D 的“默认 payload 不可见”不再作为 Step 1 pass 条件；保留的只有低敏输出、无 provider 外发、无真实敏感 fixture 的门禁精神。

## 11. 开发拆分建议

### 11.1 4 个子批次

建议拆成 4 个开发子批次，避免一次性改 UI、repository、OCR 和门禁。

#### Step 1A：Search document 与 bounded preview 基础

范围：

- 新增 search document / preview snapshot 类型和 repository 存储。
- 插入、删除、裁剪路径维护 search document / FTS。
- 新 bounded preview builder 替代默认 redacted preview。
- 面板仍用现有 layout，只替换 preview 来源。

验收：

- 文本、URL、富文本 plain text、file name、类型同义词 fixture 可入 search document。
- 长文本 preview 有界但可识别。
- View 不批量同步读取完整 payload。

#### Step 1B：搜索状态与 Store/UI 接入

范围：

- `ClipboardStore` 暴露 search result state。
- 搜索主路径切到 repository / search index。
- 实现 empty / emptyIndexing / partialIndexing / failed 状态。
- 时间 token 最小格式接入。

验收：

- 正文、source、URL host/path、file name、rich text plain text、类型同义词、最小时间查询可命中。
- 搜索不再只搜 redacted preview。

#### Step 1C：Vision OCR 队列

范围：

- OCR state 持久化或可恢复。
- `ClipboardVisionOCRQueue` 和 Vision recognizer protocol。
- Mock recognizer/test hook。
- OCR text 写入 search document / FTS。
- retry 状态转换和低敏失败错误。

验收：

- `VISION-004` fixture 完成后可搜。
- pending/running/failed/retry 可稳定复现。
- 面板打开、搜索输入、滚动不等待 OCR。
- 不调用 provider、不读 file URL 本体、不新增权限请求。

#### Step 1D：设置页清理、输出边界和 verifier 迁移

范围：

- 移除 / 重命名 active hardening settings UI。
- 更新 Localizable active tokens。
- 更新 P8/P8I/P9A/P9B/P11E 或新增 P13A。
- 确保 CLI/log/verifier 默认低敏输出。

验收：

- 设置页负向 token 不在 active UI。
- 新 Step 1 verifier PASS。
- 旧 Step 4D hardening gate 不再阻止明文目标。

### 11.2 可并行与不可并行

可并行：

- OCR recognizer protocol/mock 与 search document schema 可以并行设计。
- Settings token 清理可以在 preview/search 事实源稳定后并行。

不建议并行：

- View 明文展示不应早于 bounded preview / search document 基础。
- OCR UI 状态不应早于 OCR state persistence 或可恢复策略。
- verifier 迁移不应早于主要事实源命名稳定。

## 12. 风险

### P1 风险

1. Schema migration 风险：现有 `clipboard_items.search_text` / `clipboard_fts` 与新 search document 共存期间可能双事实源。缓解：明确新 search document 为当前事实源，旧字段只兼容或迁移。
2. 性能风险：明文预览如果直接在 View 中读 payload，会造成面板打开和滚动卡顿。缓解：bounded preview snapshot + 后台 reindex。
3. OCR 状态不稳定：如果只用内存队列，App 重启后 running/pending 状态会丢。缓解：repository 持久化或可恢复状态。
4. Verifier 冲突：旧 P11E/P8/P9B 会把 Step 1 正确明文目标判失败。缓解：先迁移 verifier 再最终验收。
5. 输出污染风险：取消默认遮挡后，日志/verification JSON 可能误写 fixture 正文或完整 OCR 文本。缓解：统一 sanitizer 和低敏 schema。

### P2 风险

1. Vision 识别结果因 macOS 版本、语言、图片质量不同而波动。缓解：验收 fixture 使用稳定短 token 和 mock hook。
2. URL query / file path 搜索范围可能引发可读性和输出风险。缓解：App 内本地 search document 可有界索引，日志/verifier 不输出完整值。
3. Rich text plain text 提取失败可能出现个别不可搜记录。缓解：失败降级为 type/source/time 可搜，并记录低敏 error code。
4. Search ranking 首版可能需要 UI/测试微调。缓解：保持排序权重集中在 search coordinator，不散落在 View。

## 13. 需要产品 / 测试补充确认

产品负责人 / UI 建议确认：

1. 首版 preview 行数和截断体验是否接受技术建议值，或由 UI 给最终值。
2. OCR 状态文案：pending/running/failed/retry 的用户可见短文案。
3. URL query 是否需要作为 Step 1 必验搜索字段；本方案建议不把完整 query 设为必验。
4. OCR 语言验收范围：本方案建议只用 `VISION-004` 低敏英文 token 做必验，多语言准确率不作为 Step 1 必验。

测试/质量建议补充：

1. Synthetic fixture 设计：text、URL、rich text、file URL、image OCR success、OCR failure、OCR retry、long text、large image。
2. Performance fixture：多记录、大图、多图批量入库下打开面板和搜索输入不等待 OCR。
3. Low-sensitive output scan：日志、CLI、verification JSON、开发记录、验收记录的 forbidden token / pattern 清单。
4. Verifier 分层：静态门禁、repository smoke、OCR mock smoke、UI 手工验收如何分工。

## 14. 建议参与技术方案复审角色

进入开发前建议复审角色：

- 项目负责人：确认方案没有扩大 Step 1 范围，并接受开发拆分。
- 开发：确认 repository migration、search document、OCR queue 和 verifier 拆分可落地。
- 测试/质量：确认 fixture、OCR mock、性能门槛和低敏输出验收可执行。
- 安全合规顾问：确认日志/CLI/provider/automation 边界没有被误读为无限制外发。
- UI/交互设计师：确认 bounded preview、OCR 状态和搜索状态的最低呈现不会造成体验断层。

代码审查可在实现完成后参与，不要求在技术方案阶段阻塞。

## 15. 建议开发前通过条件

开发派发前建议项目负责人确认：

- 本技术方案已由开发和测试/质量复审，无 P0/P1 未闭合。
- 新 Step 1 verifier 命名、最低断言和旧门禁迁移口径已接受。
- Preview 阈值、OCR mock/test hook、低敏输出 schema 有明确负责人。
- Step 1A-1D 子批次顺序被接受，且每个子批次有独立验收点。
