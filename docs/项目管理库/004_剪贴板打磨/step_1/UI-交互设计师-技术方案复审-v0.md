# Step 1 UI/交互设计师技术方案复审 v0

状态：reviewed
日期：2026-07-07
角色：UI/交互设计师
对象：`App架构师-技术方案-v0.md`
结论：`approve-with-changes`

## 1. 复审范围

本轮只复审 Step 1 技术方案：明文展示、搜索底座与系统 Vision OCR。

不进入以下范围：

- 标签 / 收藏模型、标签筛选和设置页标签管理。
- 面板 hover 安全区、搜索框宽度、选中反馈、单 / 双击设置、卡片密度等 Step 3 专项打磨。
- 详情编辑、保存 / 取消、富文本编辑和 OCR 文本编辑。
- 隐私页真实 App 清单和 CLI 广义对象管理。
- 真实 App 运行、真实剪贴板读取、真实 OCR、系统权限、provider 或自动化动作。

已读：

- `docs/项目管理库/004_剪贴板打磨/step_1/App架构师-技术方案-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_1/项目负责人-技术方案预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_1/产品经理-PRD-v1.md`

本复审是文档级方案复审，没有截图或运行时 UI 证据。后续开发验收仍需低敏 fixture、截图或录屏补证。

## 2. 总体判断

技术方案主线成立：`有界明文预览 + 可重建搜索文档 + 本地 Vision OCR 队列 + 低敏输出门禁` 能支撑 Step 1 的第一阶段体验目标，也没有把 Step 2-5 的能力提前并入。

当前方案对 UI/交互最有价值的部分：

- 没有让 View 层在高频路径批量读取完整 payload，而是把默认体验收敛到 bounded preview snapshot。
- 搜索状态区分 `empty`、`emptyIndexing`、`partialIndexing`、`failed`，比单一无结果状态更接近用户真实预期。
- OCR 状态有 `pending`、`running`、`succeeded`、`failed`，并要求 retry 可稳定测试。
- 明确 OCR 不上传 provider、不新增权限、不读 file URL 本体，降低用户对“图片识别是否外发”的误解风险。
- 接受 URL query 和多语言 OCR 准确率不作为 Step 1 必验，符合第一阶段收口。

需要回写的不是架构方向，而是“这些技术状态怎样落到用户可见界面”。如果只保留技术字段和 verifier 断言，开发仍可能出现：预览 500 字符把面板撑开、OCR 失败只在搜索状态里出现导致用户找不到重试、`failed` 被误解为整页搜索失败、搜索占位文案暗示支持完整 URL query 或所有语言 OCR。

## 3. 必须改

### 3.1 Bounded preview 需要区分“派生数据阈值”和“界面可见阈值”

技术方案建议 `title` 最长 120 characters、`body` 最长 500 characters。这作为派生 snapshot 的上限可以接受，但还不足以成为面板 UI 的可见规则。Step 1 不做卡片密度重设计，所以更需要明确：数据可以有界到 500 字符，界面不能因此显示 500 字符正文。

必须补充：

- `title/body` 的存储或 snapshot 阈值，不等于 row/card/tray 的可见行数。
- 面板列表默认可见区域需要 line clamp 或等价约束，避免长文本挤压来源、时间、OCR 状态和操作区。
- `isTruncated` 需要是内部状态或轻量提示，不应变成高频列表里的显眼错误。
- URL、file URL、富文本、图片状态需要各自的 preview 组成规则，不能统一截取前 500 字符后直接展示。

建议技术方案可吸收口径：

> `ClipboardContentPreviewSnapshot` 的 `title <= 120 characters`、`body <= 500 characters` 是派生数据边界；面板 UI 仍按现有 row/card/tray 尺寸做可见行数约束。首版建议 title 1 行，body 2-3 行或等价 clamp；超出时截断但保留可识别开头。URL preview 优先展示 host + path 摘要，file URL preview 优先展示文件名 + 有界路径摘要，图片 preview 优先展示缩略图或图片状态 + OCR 状态。`isTruncated` 只表示内容被有界处理，不是错误状态。

验收样例：

- 长文本 fixture 超过 500 字符时，snapshot 有界，面板仍不因正文变高而挤压其他记录。
- URL fixture 带很长 query 时，面板显示 host/path 摘要，不把 query 撑满列表。
- file URL fixture 带长 home path 时，面板显示文件名和有界路径摘要，不保存完整 home path 到验收证据。

### 3.2 OCR 状态需要明确在图片条目内的最低可见表达

技术方案有状态模型，但还需要更明确的用户可见位置。PRD v1 已要求 OCR 失败和重试入口至少出现在图片条目状态中；技术方案不能只把 retry 作为 repository / queue 状态或搜索状态行。

必须补充：

- 图片条目内必须有 OCR 状态位，至少覆盖待处理、处理中、完成、失败。
- 失败状态的 retry 入口必须在图片条目内或与图片条目强关联的位置，不可只放在搜索空状态。
- 点击 retry 后要立即有反馈，例如按钮进入 disabled/running 或状态从 failed 变为 pending/running。
- OCR 状态不得造成全局 blocking；失败是局部降级。

建议技术方案可吸收口径：

> 图片记录的 preview 区或状态行需要显示 OCR 状态：`待识别`、`正在识别图片文字`、`图片文字已可搜索`、`图片文字识别失败`。失败时在同一条目提供 `重试` 操作；点击后状态立即变为 pending/running，重试期间按钮不可重复触发。搜索状态行可以同步提示 OCR 处理中或失败数量，但不能替代条目内 retry 入口。

验收样例：

- OCR failed fixture 的图片条目显示失败文案和 retry 操作。
- 点击 retry 后，条目状态进入处理中或待处理，不出现无反馈的静默点击。
- OCR failed 不影响同一条记录按来源 App、类型或时间字段被搜索命中。

### 3.3 搜索状态需要区分“全局搜索失败”和“局部 OCR / 索引失败”

技术方案定义了 `ClipboardSearchResultSet.state: idle / results / empty / emptyIndexing / partialIndexing / failed`，并同时有 `failedOCRCount`。UI 侧必须避免把单条 OCR 失败渲染成整页搜索失败。

必须补充：

- `failed` 应保留给搜索服务、索引读取或查询路径整体失败。
- 单条 OCR 失败应作为 row-level state 和 search status 的辅助信息，不应覆盖已有结果或确定无结果。
- `emptyIndexing` 与 `partialIndexing` 是非阻塞提示，用户仍可继续输入、清空搜索和滚动。
- 如果既有部分结果又有 OCR 失败，应优先展示结果，并用轻量提示说明部分图片文字未识别。

建议技术方案可吸收口径：

> 搜索结果区状态优先级：`failed` 只表示查询路径整体不可用；`partialIndexing` 和 `emptyIndexing` 是非阻塞状态；单条 OCR failed 不触发全局 failed。已有结果时始终展示结果列表，状态行仅提示“部分图片文字仍在处理”或“部分图片文字识别失败，可在对应条目重试”。

验收样例：

- 搜索 `VISION-004` 时 OCR 尚未完成，显示 `emptyIndexing` 或等价“仍在识别图片文字”。
- 搜索正文命中 2 条记录，同时仍有 OCR pending，显示结果 + `partialIndexing` 提示。
- 一条图片 OCR failed 时，搜索正文仍能显示结果，不进入全局 failed 空页。
- 模拟 repository search 抛错时，才显示全局搜索失败文案和可重试 / 重新加载路径。

### 3.4 URL query 和多语言 OCR 降级需要有用户预期管理

不把完整 URL query 作为 Step 1 必验、不把多语言 OCR 准确率作为 Step 1 必验，是可接受的阶段取舍。但 UI 文案和验收证据必须避免让用户误以为已经支持“搜完整 URL 任意部分”和“所有语言 OCR 都准确”。

必须补充：

- 搜索说明、占位文案或 release note 不应承诺 query 参数完整可搜。
- URL 搜索验收重点应写成 host/path/可读 URL 文本。
- OCR 文案应表达“图片文字识别结果可搜索”，避免承诺语言、准确率或完整识别。
- 多语言 OCR 可以作为探索或后续优化，不作为 Step 1 pass/fail。

建议技术方案可吸收口径：

> Step 1 搜索对 URL 的用户承诺是 host、path 片段和可读 URL 文本可命中；完整 query 是否索引属于有界技术实现，不写入用户可见承诺。OCR 的用户承诺是“使用本机系统能力识别图片文字并进入搜索”，不承诺所有语言和所有图片都准确识别。验收 fixture 以 `VISION-004` 低敏短 token 为准。

验收样例：

- URL `https://example.com/blocks/clipboard-step1?token=fixture` 可通过 `example.com` 或 `clipboard-step1` 命中；不要求 `token=fixture` 作为必验。
- 中文 / 日文图片 OCR 可进入探索记录，但 Step 1 必验只使用稳定低敏 token，不因多语言识别波动阻断。

### 3.5 可访问性 label 和键盘路径需要进入技术验收口径

技术方案覆盖了状态和数据流，但 UI 状态如果没有可访问性口径，OCR retry 和搜索状态很容易只对视觉用户可见。

必须补充：

- OCR 状态、retry 按钮、搜索空状态、索引中状态、全局失败状态需要 VoiceOver 可读。
- retry 操作可键盘聚焦和触发。
- 状态文案不能只靠颜色、spinner 或图标表达。
- 搜索状态更新不应造成焦点跳走或输入框失焦。

建议技术方案可吸收口径：

> OCR 状态和搜索状态必须有文本 label，图标和 spinner 只作为辅助。`Retry OCR` / `重试识别` 是可聚焦操作，VoiceOver 读出当前状态与操作结果。搜索从 emptyIndexing 到 results 的更新不抢走搜索框焦点。

验收样例：

- VoiceOver 可读出“图片文字识别失败，重试识别”。
- 键盘用户可聚焦 retry 并触发，触发后状态文案更新。
- 搜索输入过程中 OCR 结果完成，搜索框仍保持焦点。

## 4. 可优化

### 4.1 Preview 阈值可在实现后用低敏截图微调

`title 120 / body 500` 作为首版技术值可以先接受。真正影响体验的是 UI 可见行数、截断位置和各内容类型的摘要策略。建议开发完成后用 text、URL、file URL、rich text、image 五类低敏 fixture 截图做一次微调。

### 4.2 搜索状态可以后续增加命中来源解释

Step 1 不必要求完整高亮或命中解释。后续可在 Step 3 或搜索 polish 中补充“命中正文 / OCR / URL / 来源 App / 类型”的轻量标识。

### 4.3 OCR 进度数量可以先不显示

技术方案有 `pendingIndexCount`、`runningOCRCount`、`failedOCRCount`。UI 首版不一定要展示精确数量，避免状态行过重。可以先使用轻量文案，测试和日志保留数量即可。

### 4.4 多语言 OCR 可作为探索证据而非门禁

如果实现后系统 Vision 对中文或日文表现不错，可以在开发记录或测试记录中补充观察，但不建议把它提前写成 Step 1 必验。

## 5. 可吸收建议

建议在技术方案或开发任务中补充以下 UI 合同：

1. **Preview 合同**：snapshot 阈值和 UI 可见 clamp 分开；title/body 有界但不撑开列表。
2. **OCR 条目状态合同**：图片条目内显示 pending/running/succeeded/failed；failed 有同位 retry；retry 后立即反馈。
3. **搜索状态优先级合同**：全局 failed 只表示查询路径失败；局部 OCR failed 不盖掉结果列表。
4. **降级承诺合同**：URL query 和多语言 OCR 不进入用户可见承诺和 Step 1 必验。
5. **可访问性合同**：状态和 retry 都有文本 label、键盘路径和焦点稳定验收。

可直接吸收的短文案建议：

- OCR pending：`等待识别图片文字`
- OCR running：`正在识别图片文字`
- OCR succeeded：`图片文字已可搜索`
- OCR failed：`图片文字识别失败`
- OCR retry action：`重试识别`
- emptyIndexing：`暂时没有结果，部分图片文字仍在识别`
- partialIndexing：`已显示部分结果，部分图片文字仍在识别`
- global search failed：`搜索暂时不可用，请稍后重试`

这些文案只是首版建议，最终应进入 String Catalog 并由实现按现有文案风格调整。

## 6. 验收样例

### 6.1 Bounded preview

- 文本 fixture：`Alpha roadmap item 004 search baseline` 显示可读预览，不显示字符数壳。
- 长文本 fixture：超过 500 characters，snapshot 有界，UI 最多显示约 2-3 行正文或等价 clamp，不挤压其他条目。
- URL fixture：`https://example.com/blocks/clipboard-step1?token=fixture` 显示 host/path 摘要；不把 query 作为必验。
- file URL fixture：显示文件名和有界路径摘要；验收记录不保存完整 home path。
- 富文本 fixture：显示 plain text 预览；解析失败时条目仍可见并有类型/source/time 等降级字段。

### 6.2 OCR 状态与 retry

- 图片 OCR pending：图片条目可见，显示等待识别，不阻塞搜索输入。
- 图片 OCR running：条目显示正在识别，列表可滚动。
- 图片 OCR succeeded：搜索 `VISION-004` 命中图片记录。
- 图片 OCR failed：条目显示失败和 `重试识别`，其他字段搜索仍可用。
- Retry：点击后状态进入 pending/running，按钮不重复触发，最终 succeeded 或 failed。

### 6.3 搜索状态

- 默认：无查询时展示正常列表。
- 有结果：正文、来源 App、URL host/path、文件名、富文本 plain text、类型同义词可命中。
- empty：索引完成且无命中，显示确定无结果。
- emptyIndexing：搜索 `VISION-004` 时 OCR 尚未完成且无其他命中，显示仍在识别。
- partialIndexing：已有正文命中，同时 OCR 仍 pending，展示结果并提示仍在处理。
- failed：只有 repository search / index query 整体失败时显示全局搜索失败。

### 6.4 降级边界

- 搜索 query 参数不作为 Step 1 必验；可测 host/path 命中。
- 多语言 OCR 准确率不作为 Step 1 必验；可用低敏英文 token 验证链路。
- OCR 不上传 provider、不新增权限、不读 file URL 本体。
- 搜索、OCR、verification JSON、开发记录不保存完整正文、完整 URL、完整路径、完整 OCR 文本或图片 base64。

### 6.5 可访问性

- VoiceOver 能读出 OCR 状态和 retry 操作。
- 键盘能触达 retry。
- 搜索状态变化不抢走搜索框焦点。
- 状态不只依赖颜色、图标或 spinner。

## 7. 对项目负责人的建议

建议结论：`approve-with-changes`。

没有发现需要退回用户澄清或整体否定技术路线的问题。建议进入开发准备前，让 App 架构师或开发任务吸收以下必须改点：

1. 把 bounded preview 的 snapshot 阈值与 UI 可见 clamp 分开写清楚。
2. 明确 OCR retry 入口在图片条目内或强关联位置，并有点击后反馈。
3. 明确搜索状态优先级，避免局部 OCR 失败变成全局搜索失败。
4. 把 URL query 和多语言 OCR 的降级承诺写进技术验收或开发记录。
5. 补充 OCR / 搜索状态的可访问性和焦点稳定验收。

这些修改不改变 Step 1 范围，也不要求提前做 Step 3 的面板视觉打磨；它们只是把技术方案里的状态和阈值转成用户可理解、可测试的界面契约。
