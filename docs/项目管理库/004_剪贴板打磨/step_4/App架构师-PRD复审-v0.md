# Step 4 App 架构师 PRD 复审 v0

日期：2026-07-07
角色：App 架构师
对象：`step_4/产品经理-PRD-v0.md`
范围：004_剪贴板打磨 Step 4 详情编辑与元数据组织
结论：`approve-with-changes`

## 1. 总体结论

PRD v0 的阶段范围成立：聚焦详情编辑与元数据组织，没有提前拉入 Step 5 隐私页真实 App 清单 / CLI 广义对象管理，也没有重开 Step 1 搜索/OCR、Step 2 标签事实源或 Step 3 面板布局专项。

但从 App 架构角度看，当前 PRD v0 仍把若干关键点留在“技术方案待确认”层面。对于 Step 4，这些点不是普通实现细节，而是会决定数据模型、保存事务、可验收行为和 P13D 门禁形态。建议结论为 `approve-with-changes`：可进入 PRD 收敛，但 PRD v1 需要先补齐 P1 口径，再进入技术方案。

## 2. 事实依据

### 2.1 文档依据

- `step.md` 将 Step 4 定义为“详情编辑与元数据组织”，必须覆盖 plain text、URL、富文本文本内容、图片 OCR 文本，且不更新系统剪贴板。
- `项目负责人-PRD派发-Step4-v0.md` 要求 PRD 明确保存、取消、失败回滚、搜索索引更新、更新时间更新、富文本降级风险和 OCR 状态边界。
- `产品经理-PRD-v0.md` 已覆盖可编辑类型矩阵、状态矩阵、保存后数据更新矩阵、低敏 fixture、P13D 建议方向。
- `项目负责人-PRD预审-v0.md` 已判定可进入角色复审，并要求 App 架构师重点检查富文本、URL、保存事务、OCR 冲突、更新时间和 repository / read model 边界。

### 2.2 代码抽样事实

只读静态抽样，不代表完整实现复审：

- `ClipboardRecorderItemKind` 已包含 `.text`、`.richText`、`.image`、`.url`、`.fileURL` 等类型。
- `ClipboardRecorderPayload` 当前有 `text`、`rtfDataBase64`、`pngDataBase64`、`urlString` 字段。
- `ClipboardRepository.insert` 当前在一个数据库 transaction 内插入 record、payload 和 search document。
- `ClipboardRepository.storePayload` 可写 `text`、RTF data、PNG data / sidecar、`url_string`。
- `ClipboardSearchDocument` 已有 `contentText`、`richTextPlainText`、`urlTokens`、`fileTokens`、`tagTokens`、`ocrText`、`ocrState` 等派生字段。
- `updateOCRResult` 当前基于 search document revision 更新 OCR 结果，但它是 OCR pipeline 语义，不等同于用户编辑 OCR 文本语义。
- App 层已有 purpose-scoped `ClipboardPayloadReadPurpose` 和 `ClipboardPayloadCacheKey`，但目前没有 Step 4 详情编辑专用 read / write purpose 与 mutation contract。

这些事实说明：Step 4 不宜用临时 UI 字符串更新绕过 repository；需要定义一个明确的 edit mutation 边界，把 payload、派生字段、摘要、搜索索引、更新时间和 read model 统一起来。

## 3. P0 / P1 / P2

### P0

无。

### P1：富文本格式保留与降级口径仍需在 PRD v1 明确

当前 PRD 写法正确地避免了“静默丢格式”，但还不足以支撑技术方案拆解。问题在于：如果富文本编辑进入同一 Step 4 交付范围，PRD v1 需要明确最低可接受语义，否则开发无法判断是保留 RTF payload、只更新纯文本派生字段，还是暂缓富文本编辑。

阻塞原因：

- `ClipboardRecorderPayload` 中富文本 payload 同时可能包含 `text` 和 `rtfDataBase64`，保存文本内容时是否要重写 RTF data 会直接决定数据模型和失败回滚。
- 如果只更新 `text` / `richTextPlainText` 而不更新 `rtfDataBase64`，详情展示、paste/copy、搜索索引可能出现“看见的新文本”和“还原/粘贴的旧富文本”不一致。
- 如果把 RTF 静默纯文本化，会违背 PRD 已写的产品目标。

建议 PRD v1 推荐口径：

- 富文本首选语义：编辑富文本文本内容时，必须保持 record kind 为 `rich_text`，并保持用户可见格式不被静默降级。
- 最低格式保留范围由技术方案验证，但 PRD v1 至少要求链接、段落、基础 inline style 的保留能力要么通过，要么形成项目负责人取舍记录。
- 若技术方案确认无法可靠保留 RTF payload，则富文本编辑不得作为普通可编辑类型进入开发；应降级为“只读 + 可复制纯文本”或单独决策，不在实现中隐式改成纯文本编辑。
- P13D 必须包含“富文本不能静默丢格式”的 evidence；如果降级，必须检查存在项目负责人接受记录。

### P1：保存事务语义需要从“更新多个对象”收敛为单一 mutation contract

PRD v0 已列出 payload / 派生字段 / 摘要 / 搜索索引 / 更新时间的更新矩阵，但还需要把它改写成用户可见的一致性合同。

阻塞原因：

- Step 4 保存不是单字段写入；plain text、URL、rich text、OCR text 都可能影响 payload、search document、preview summary、FTS projection、record `updated_at`。
- 如果 payload 保存成功但索引失败，用户会看到详情已变但搜索搜不到；如果索引成功但 payload 失败，搜索和详情可能不一致。
- 当前已有 `upsertSearchDocument` 会更新 `clipboard_items.search_text` 和 `updated_at`，但 PRD 还未规定 Step 4 edit mutation 是同步事务、异步事务，还是保存成功后进入 pending index 状态。

建议 PRD v1 推荐口径：

- 定义 `detail edit save` 为单一用户级 mutation：保存成功后，详情正文、面板摘要、搜索命中、更新时间必须进入同一版本语义。
- 首选：payload / record summary / search document / FTS / updatedAt 在同一 repository transaction 内提交。
- 如技术方案必须采用异步 reindex，则保存成功状态不得宣称搜索已更新；PRD v1 需定义 `saved-index-pending` 或等价状态、重试/恢复机制和用户可见反馈。
- 保存失败时必须保留草稿，且持久化事实源不得进入用户可见的部分提交状态。
- P13D 应断言保存成功、保存失败和索引失败三类证据，而不只检查 UI 提示。

### P1：OCR 用户编辑文本与 OCR retry 冲突策略必须前置

PRD v0 已指出“后续 OCR retry 不得静默覆盖用户已编辑 OCR 文本”，但尚未给出推荐冲突策略。这个点会影响 search document 字段、OCR 状态、retry 行为和 verifier。

阻塞原因：

- 当前 OCR pipeline 使用 `updateOCRResult(recordID:revision:text:state:)` 更新 search document 中的 `ocrText` 和 `ocrState`。
- 用户编辑 OCR 文本后，如果仍复用同一 `ocrText` 字段而没有 user-edited 标记，retry 很容易覆盖用户文本，或导致 OCR state 与用户文本来源混淆。
- 是否允许“无 OCR 文本时手动新增 OCR 文本”也会改变状态机和测试 fixture。

建议 PRD v1 推荐口径：

- Step 4 默认只允许 `ocrState == succeeded` 且已有 OCR 文本的图片记录编辑 OCR 文本。
- 用户保存编辑后的 OCR 文本后，该文本应标记为 user-edited / user override / locked source 的等价语义。
- OCR retry 对 user-edited OCR 文本不得静默覆盖；首版推荐策略是 retry 生成候选结果或提示覆盖确认，若没有 UI 承载则 retry 对该条目 disabled 或需要先撤销用户编辑。
- OCR pending / running / failed 不进入编辑态；failed 只保留 retry，不把失败文本当成可编辑正文。
- P13D 应覆盖 user-edited OCR 后 retry 不覆盖的低敏 fixture。

### P1：URL record kind、合法性和标准化规则需要更硬的 PRD 口径

PRD v0 已写“不因输入普通文本自动改 record kind”，并建议绝对 URL。但对于技术方案，仍需明确保存前后如何标准化和如何失败。

阻塞原因：

- URL payload 可能同时有 `text` 与 `urlString`；如果两者更新不一致，会影响详情展示、搜索 token 和 paste/copy。
- 非法 URL 是保存按钮 disabled、inline validation，还是保存失败，决定了状态机和 P13D。
- 是否自动补 scheme、是否允许 `mailto:` / `file:` / custom scheme，会影响 record kind 与 Step 4 “不编辑文件本体”的边界。

建议 PRD v1 推荐口径：

- URL record 保存后仍保持 `url` kind；Step 4 不支持 URL record 转 text record。
- 首版只接受可由 `URLComponents` 或等价规则解析的 absolute URL，并保留 scheme。
- 不自动补 `https://`，避免把用户输入猜测成新 URL。
- `file:` URL 不作为 URL 文本编辑的普通成功路径；file URL 仍按不可编辑文件本体边界处理。
- 非法 URL 优先 inline validation，保存按钮 disabled；如果实现选择保存后校验失败，也必须停留 dirty 状态并保留草稿。
- 保存成功时 `payload.urlString`、payload text / 派生纯文本、URL tokens、preview summary 必须同源。

### P1：Repository / read model 边界和 P13D 应从“建议”升为 PRD v1 明确要求

PRD v0 第 16 节把 Step 4 专属门禁写为“建议”。从 App 架构角度，Step 4 修改的是核心剪贴板数据事实源，P13D 不应只是建议。

阻塞原因：

- 详情编辑会触达完整 payload 与派生 read model，若没有 fail-closed gate，容易回退到直接读写 payload、绕过 Step 4D purpose-scoped access 和 Step 1/2 的 search/tag 边界。
- 元数据组织若直接读取大 payload 做布局，会破坏 bounded read model 原则。
- 没有 P13D，就很难证明“保存不更新系统剪贴板”“失败不部分提交”“富文本不静默降级”“OCR retry 不覆盖用户编辑”。

建议 PRD v1 推荐口径：

- 明确 Step 4 技术方案必须提供 P13D 或等价 fail-closed verifier。
- 明确详情页默认展示和元数据布局基于 bounded detail read model，不为布局一次性读取不必要大 payload。
- 完整 payload read / edit draft / save mutation 必须通过明确 purpose，例如 `detailEditRead`、`detailEditSave` 或等价命名；不要复用 hover / paste / copy purpose。
- AppState / Store 只提供 facade 与协调，不成为编辑后 payload / OCR / search document 的事实源。

## 4. 非阻塞但建议吸收的优化点

- `updatedAt` 字段建议拆清：PRD v1 可不决定最终字段名，但应写明用户可见更新时间是“内容更新时间”，createdAt / capture time / source App 保持不变。OCR 文本编辑是否也更新 record updatedAt，应作为技术方案必答项。
- dirty-navigation 的 UI 形态可留给 UI/交互，但 PRD v1 应明确保存中切换条目不允许并发提交；用户删除同一记录或外部更新同一记录时，进入冲突 / 记录不可用状态。
- 元数据长项建议补“复制完整值”的安全边界：UI 可以复制 URL / file URL 摘要或完整值，但低敏 evidence 不得记录真实本机完整路径。
- 富文本 fixture 建议至少包含纯 RTF、RTF + link、RTF + list；若技术方案只支持其中一类，应形成明确降级表。
- P13D fixture 建议保留 PRD 中的 `detail_*_004` 命名，并补充 `detail_ocr_user_edited_retry_004`、`detail_rich_text_degrade_blocked_004`、`detail_url_custom_scheme_004`。

## 5. 推荐 PRD v1 写法

### 5.1 保存事务推荐写法

建议将保存模型补成：

> Step 4 的保存是用户级原子 mutation。保存成功时，同一记录的可编辑内容、对应 payload 或派生字段、可见摘要、搜索索引、更新时间和当前详情 read model 必须进入一致版本；保存失败时草稿保留，已保存事实源不得出现用户可见部分提交。若技术方案采用异步索引，PRD v1 必须引入 saved-index-pending / reindex-failed 等可见状态，不能把搜索更新写成已完成。

### 5.2 富文本推荐写法

建议将富文本补成：

> 富文本编辑的首选目标是保留 `rich_text` kind 和原富文本 payload 格式。技术方案需要证明编辑后的 RTF payload 与派生纯文本一致；如果无法可靠保留格式，富文本编辑不进入默认可编辑类型，需项目负责人单独接受降级，不允许静默转换为 plain text。

### 5.3 OCR 冲突推荐写法

建议将 OCR 补成：

> 用户编辑并保存 OCR 文本后，该 OCR 文本成为 user-edited override。后续 OCR retry 不得静默覆盖 user-edited 文本；首版如无候选对比 UI，则对 user-edited OCR 文本禁用 retry 或要求用户先确认覆盖。OCR pending / running / failed 不提供文本编辑。

### 5.4 URL 推荐写法

建议将 URL 补成：

> URL 编辑只编辑 URL record 的 URL 字符串，不改变 record kind。首版只接受 absolute URL，非法 URL inline 阻止保存并保留草稿；保存成功后 `urlString`、派生纯文本、URL tokens、summary 和 search document 必须同源。file URL 不作为 URL 编辑成功路径，仍按文件本体不可编辑边界处理。

### 5.5 P13D 推荐最低职责

P13D 应至少 fail closed 检查：

- PRD / 技术方案 / 开发记录引用当前 Step 4。
- 可编辑 / 不可编辑类型 fixture 完整。
- detail read model 默认不读取不必要完整 payload。
- detail edit read / save 使用明确 purpose，不复用 paste / hover / translation 等 purpose。
- plain text / URL / rich text / OCR text 保存成功后，payload 或派生字段、summary、search document、updatedAt 一致。
- 保存失败保留草稿，不产生用户可见部分提交。
- 系统剪贴板未被保存动作更新。
- 富文本不能静默丢格式；降级必须有项目负责人接受记录。
- user-edited OCR retry 不静默覆盖。
- URL 非法输入不能保存，URL kind 不被自动改为 text。
- 编辑区 2 行默认 / 4 行上限 / 内部滚动和元数据长项不挤压正文有低敏 evidence。
- 输出不包含真实剪贴板、真实 home path、真实文件路径、secret、二维码、验证码、Authorization header。

## 6. 是否建议继续推进

建议项目负责人要求产品经理产出 PRD v1，吸收上述 P1 后再进入技术方案。当前不建议直接进入技术方案，因为富文本降级、编辑保存原子性、OCR retry 冲突、URL 合法性和 P13D 是否必需都会影响技术方案边界。

如果 PRD v1 明确上述口径，本阶段可继续推进；未发现需要回到用户澄清的 P0。
