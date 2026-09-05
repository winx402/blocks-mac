# Step 1 App 架构师 PRD 复审 v0

复审日期：2026-07-07
复审角色：App 架构师
复审对象：`step_1/产品经理-PRD-v0.md`
复审范围：Step 1 明文展示、搜索底座与系统 Vision OCR
结论：`approve-with-changes`

## 1. 总体判断

Step 1 PRD 的阶段范围基本正确：它聚焦明文展示、搜索底座和系统 Vision OCR，没有把 Step 2 标签/收藏、Step 3 面板交互打磨、Step 4 详情编辑、Step 5 隐私页全量 App 管理提前塞回 Step 1。PRD 对“真实内容可访问，交互输出可控”的方向也与需求澄清一致。

从 App 架构角度看，当前 PRD 可以继续推进到角色复审收敛，但进入技术方案前必须补清几类边界，否则开发容易在搜索索引、OCR 存储、旧 redacted-only 路径退出和日志/CLI 输出上各自解释，导致实现不可验收。

本复审不要求把 Step 2-6 的功能提前实现；下面所有修改建议都只服务 Step 1 的明文展示、搜索索引和 Vision OCR 底座。

## 2. 结论理由

### 可接受的部分

- Step 1 目标明确：先解决面板看不见真实内容、搜索不可用和图片 OCR 进入搜索的问题。
- 非目标边界清楚：标签/收藏、详情编辑、隐私页全量 App、面板专项 UI 打磨和旧 pinboard 迁移均未进入 Step 1。
- OCR 范围收敛：限定 macOS Vision，不做外部 provider OCR，不上传图片，不做图片本体编辑。
- 性能方向正确：OCR 异步，不阻塞面板打开、搜索输入和滚动。
- 输出边界叙事正确：内容保护取消后，仍保留“输出可控”作为性能、可读性、防误操作和可维护性边界。

### 需要补清的部分

PRD 当前把多项架构关键点写在“进入技术方案前需 App 架构师确认的问题”中，这适合作为问题列表，但不够作为开发输入。项目负责人接受 Step 1 PRD 前，建议把其中的 P1 条目回写成明确产品/架构约束，避免技术方案阶段重新定义需求。

## 3. 进入技术方案前必须补清的问题

### P1-1：搜索索引模型需要从“字段列表”升级为“索引契约”

当前 PRD 已列出搜索字段，但还没有定义索引契约。Step 1 不应只在 UI 层过滤可见文本，也不应让 View 每次搜索时直接读 payload 拼字符串。

进入技术方案前，PRD 至少应明确：

- 搜索有独立 index/read model，不是临时 UI filter。
- 每条剪贴板记录应有可重建的搜索文档，至少包含 recordID、source revision 或 updatedAt、正文纯文本、富文本纯文本、URL tokens、file URL/file name tokens、来源 App tokens、类型别名 tokens、可见时间 tokens、OCR text、OCR status。
- payload 新增、删除、裁剪、OCR 完成/失败、后续 Step 4 编辑都必须有索引更新或删除触发点。
- Step 2 标签字段可作为后续扩展 join，不要求 Step 1 实现标签，但 Step 1 的 index model 不能排斥后续 tags。

建议写法：Step 1 交付搜索索引底座与基础字段；标签、详情编辑产生的新字段在后续阶段接入同一索引服务。

### P1-2：明文预览 read model 与超大 payload 性能边界需要明确

PRD 要求面板明文展示真实可读内容，同时允许摘要、截断、多行预览或延迟加载。这个方向正确，但还需要明确默认列表读取的是“有界预览”，不是无限制同步加载完整 payload。

进入技术方案前，PRD 应明确：

- 面板列表/卡片默认展示 bounded content preview，可来自 payload、派生纯文本或缩略图，但必须有长度、行数或解码成本边界。
- 完整 payload 可被 App 内用户路径访问，但不应在面板打开、滚动、搜索输入时为所有记录同步加载。
- 图片缩略图、富文本纯文本化和大文本预览应允许异步或缓存，不阻塞首屏。
- 验收样例应覆盖长文本、大图、多记录批量入库时面板仍先可见。

这不是恢复 Step 4D 的隐私遮挡，而是定义明文优先下的性能边界。

### P1-3：Vision OCR 结果存储与生命周期需要明确

PRD 已定义 OCR 状态和异步要求，但还没有定义 OCR 结果是只进入索引、还是作为记录派生字段持久化。若只存索引，状态展示、重试、删除一致性、后续 Step 4 OCR 文本编辑都会变得脆弱。

进入技术方案前，PRD 应明确：

- OCR text 和 OCR status 是 per-record 派生数据，建议持久化在 repository 层或可重建的派生表中，再同步进入搜索索引。
- OCR 结果必须随记录删除、清理、裁剪一起删除或失效。
- 同一图片 payload 应避免重复 OCR，可用 record payload signature/hash 或 repository record id + payload revision 去重。
- App 重启后，待处理/处理中/失败/完成状态要有可恢复策略；不能只存在内存队列中。
- 失败重试需要有最小限流或状态转换规则，避免失败图片在后台无限重试。

### P1-4：富文本、URL、file URL 标准化规则需要补到 PRD

PRD 已要求富文本纯文本化、URL、文件名进入搜索，但缺少标准化边界。

进入技术方案前，PRD 应明确：

- 富文本：Step 1 只提取可读 plain text 用于预览和搜索，不承诺格式保留、编辑或 round-trip；失败时降级为类型/来源/时间等字段可搜。
- URL：至少规范化 scheme、host、path 片段和原始字符串；搜索 host/path 应可命中。
- file URL：至少提取 lastPathComponent/文件名和可读路径摘要；是否搜索完整路径需要以性能、可读性和防误操作为边界。
- 时间：如果支持时间搜索，应定义最小可验收输入，例如可见日期字符串、年份、月份或相对时间是否进入 Step 1；否则应改写为“时间字段参与排序/展示，复杂时间查询后续再做”。

### P1-5：日志/CLI 最小输出边界需要更硬

PRD 当前写“是否记录正文片段由技术方案按性能和可排查性决定”。这个句子风险偏高，因为 Step 1 同时取消默认内容保护，容易被误读为日志和 CLI 可以默认吐出大段正文。

进入技术方案前，PRD 应明确：

- Step 1 新增 OCR、索引、搜索日志默认不记录 raw payload、OCR full text、完整 URL query、完整文件路径或 provider secret；默认记录 record id、长度、类型、耗时、状态、错误码、低敏 hash/signature。
- CLI 如果在 Step 1 被触及，默认输出应保持结构化和有界；完整内容输出必须是明确命令、明确参数或明确交互动作触发。
- Provider/自动化不会因为面板打开、搜索或 OCR 索引而静默接收全文或图片，这一点 PRD 已写，建议保留为验收门禁。

这不是重新做复杂权限系统，而是避免新增日志/CLI 路径变成不可控输出。

### P1-6：旧 redacted-only 路径退出需要有可执行门禁

PRD 已要求证明旧 redacted-only 搜索路径、只显示字符数路径和同步 OCR 阻塞路径不再作为主路径，但还没有给出门禁形态。

进入技术方案前，PRD 应明确需要新增或更新 verification：

- 当前面板默认 preview 不再依赖只显示字符数或旧 redacted-only builder。
- 当前搜索不再只搜可见 redacted preview，也不能回退到历史 pinned displayName 这类非真实内容字段充当搜索主体。
- OCR 队列不能在面板 open/search input/scroll 主路径同步执行。
- 新增 Step 1 verifier 应只以当前 PRD、当前实现和 fixture 为事实源，旧 Step 4D 安全门禁只能作为历史参考，不能阻止明文展示目标本身。

## 4. 分项架构复审

### 4.1 搜索索引模型

当前 PRD 对搜索字段覆盖是充分的，但还停留在产品字段层。技术方案需要一个明确的 `ClipboardSearchDocument` 或等价模型，否则正文、富文本、OCR、URL、文件名、类型同义词会散落在 View、Store、Controller 和 verifier 中。

建议 PRD 回写最小模型要求：

- `recordID`：索引与 repository record 的稳定关联。
- `recordRevision` 或 `updatedAt/indexedAt`：用于判断 payload、OCR、后续编辑后是否需要重建。
- `contentText`：文本/URL/富文本纯文本化后的主体文本。
- `urlTokens`：URL 原文、host、path 片段。
- `fileTokens`：文件名、扩展名、可读路径摘要。
- `sourceTokens`：来源 App 名称、bundle id 等低歧义来源字段。
- `typeTokens`：类型同义词、多语言关键词、缩写和部分匹配词。
- `timeTokens`：可见时间 token，或明确 Step 1 只做时间排序不做自由文本时间查询。
- `ocrText` 与 `ocrStatus`：图片 OCR 派生文本和状态。

排序建议可以保留 PRD 当前方向：正文/URL/文件名/OCR 精准命中优先，来源 App 其次，类型同义词再次，时间字段最后。同级按最近记录或更新时间排序。

### 4.2 Vision OCR

OCR 选择 macOS Vision 是正确边界。PRD 已排除外部 provider OCR 和图片上传，符合本地工具定位。

需要补强的是生命周期：

- OCR 应通过后台队列执行，带并发限制。
- OCR 任务来源应是 repository 中图片类记录或新入库图片 payload。
- OCR status 需要持久化或可恢复，不能只存在 UI state。
- 删除、清理、裁剪、重复图片去重、失败重试都需要有数据一致性规则。
- 语言支持和 `fast`/`accurate` 取舍可放到技术方案，但 PRD 应避免承诺“完整多语言 OCR 准确率”。

### 4.3 异步性能

PRD 的“不阻塞面板打开、搜索输入和滚动”是正确的验收目标。建议技术方案前把主线程边界写得更明确：

- 面板打开：先展示 records 和可用 preview，后台补充 OCR/缩略图/派生字段。
- 搜索输入：只查询已存在索引或轻量内存索引，不等待 OCR。
- 滚动：不触发全量 payload decode 或 OCR。
- 大图/长截图：进入低优先级 OCR 队列，可显示待处理状态。
- 大文本：列表预览有界，完整内容留给明确用户动作或后续详情阶段。

### 4.4 OCR 结果存储

建议把 OCR 结果视为图片记录的派生内容，而不是纯临时缓存。原因：

- 搜索需要稳定命中，不应每次打开 App 重跑 OCR。
- OCR 状态需要可展示、可重试。
- Step 4 会涉及 OCR 文本编辑，只靠索引字段会让编辑边界不清。
- 删除/清理一致性需要 repository 层知道 OCR 派生数据。

PRD 不必指定具体表名，但应要求 OCR text/status 与 record 生命周期一致。

### 4.5 富文本纯文本化

Step 1 只应处理富文本纯文本化展示与搜索，不应进入富文本编辑或格式保留。PRD 已这样写，方向正确。

建议补清：

- 纯文本化发生在 ingest/index pipeline 或 repository 派生字段更新中，不应每次 UI 搜索时临时解析。
- 富文本解析失败时应降级为类型/来源/时间可搜，不应导致记录不可见或搜索整体失败。
- Step 4 如果要编辑富文本，需要另行评估格式 round-trip，本阶段不承诺。

### 4.6 URL / file URL 标准化

PRD 已要求 URL、host、路径片段和文件名可搜。建议补清最小标准化：

- URL：原文、host、path segment 都可作为 token；query 是否完整索引应由技术方案按长度和敏感性控制。
- file URL：文件名/扩展名是 Step 1 必须索引字段；完整路径可用于路径摘要展示，但不建议在验收中强制要求全文路径自由搜索。
- URL 和 file URL 显示应避免无界长字符串撑开面板，仍走 bounded preview。

### 4.7 旧 redacted-only 路径退出

Step 1 是对 Step 4D 默认保护策略的显式产品转向。技术方案不能只在旧 redacted preview 外面叠一个 hover/detail full content。

建议门禁：

- 面板默认 preview 当前事实源应是明文/有界内容 preview，而不是 redacted-only body。
- 搜索当前事实源应包含正文/OCR/URL/file/rich text 派生字段，而不是只搜可见 redacted metadata。
- 设置页不再展示与明文目标冲突的内容保护状态。
- 历史 P11E 类检查需要更新或降级为“输出边界检查”，不能继续把默认 payload 不可见作为 pass 条件。

### 4.8 日志 / CLI 最小输出边界

Step 1 不需要完成 CLI/provider/自动化全链路重做，但新增 OCR/索引/搜索逻辑很可能会新增日志和调试输出。因此 PRD 应把默认规则写硬：

- 日志默认 metadata-only，不写 raw payload 或完整 OCR text。
- CLI 默认结构化、有界，完整内容需要明确参数或动作。
- Provider 不因 OCR/search 自动接收 payload。
- 验收 fixture 不使用真实剪贴板和真实敏感内容。

## 5. 可优化但不阻塞 PRD 的点

1. 类型同义词词典可以先写成产品验收表，技术方案再决定是 Swift 常量、资源文件还是可本地化配置。
2. OCR 语言能力可以在技术方案中核验目标 macOS Vision 能力后回填，不建议 PRD 预设完整语言列表。
3. 搜索排序权重可以先保留 PRD 当前建议，后续 UI/测试复审用 fixture 调整。
4. 设置页移除范围可以先以用户可见 UI 为准，内部字段保留或清理由架构方案处理。
5. 面板明文预览的精确截断长度、行数和缩略图尺寸可以交给 UI/技术方案共同定，但 PRD 需要求“有界且不卡顿”。

## 6. 建议回写 PRD 的最小清单

建议项目负责人要求产品经理回写以下内容后，再进入技术方案：

1. 搜索索引契约：不是 UI filter；列出最小索引字段和更新/删除触发点。
2. 明文预览边界：列表/卡片默认使用 bounded preview，不同步加载所有完整 payload。
3. OCR 派生数据生命周期：OCR text/status 持久化或可恢复，随 record 删除/裁剪失效，失败可重试且有限流。
4. 富文本、URL、file URL 标准化：明确 Step 1 的 plain text、URL token、文件名 token 边界。
5. 日志/CLI 最小输出边界：新增日志默认不写 raw payload/full OCR text；CLI 默认结构化有界，完整输出需显式动作。
6. 回归门禁方向：新增 Step 1 verifier，确认旧 redacted-only 主路径退出、同步 OCR 阻塞路径不存在、外部 provider OCR 未接入。

## 7. 最终建议

结论为 `approve-with-changes`。

PRD v0 的阶段切分和产品方向可以接受，但上面的 P1 项需要在项目负责人接受 PRD 前补清。补清后，Step 1 可以进入技术方案拆解；若不补清，技术方案会被迫替 PRD 定义搜索索引、OCR 存储和输出边界，风险过高。
