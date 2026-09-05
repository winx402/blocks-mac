# 测试/质量 PRD 复审：Step 1 明文展示、搜索底座与系统 Vision OCR

日期：2026-07-07
角色：测试/质量
复审对象：`产品经理-PRD-v0.md`、`项目负责人-PRD预审-v0.md`，并对照 `step.md` 与 `需求覆盖矩阵-v0.md`

## 结论

`approve-with-changes`

PRD 的 Step 1 范围基本清楚：明文展示、搜索底座、系统 Vision OCR、设置页冲突项移除、输出边界原则均已覆盖，并且明确排除了标签/收藏、详情编辑、隐私应用管理、筛选交互打磨、旧 Pinboard 迁移等 Step 2-6 内容。

当前不足主要不是方向错误，而是部分验收样例仍偏“描述性”，自动化与实物验收在时间搜索、OCR 失败/排队/重试、设置项移除、输出边界和性能回归上还缺少可判定的通过条件。建议在进入实现前回写这些最小验收契约。

## 已覆盖且可作为验收基础的点

1. 明文展示路径已覆盖主要类型：
   - text 显示真实可读正文。
   - URL 显示可识别 URL。
   - rich text 显示 plain text。
   - image 显示缩略图或可识别图片状态。
   - file / file URL 显示文件名或路径摘要。

2. 搜索字段覆盖方向基本完整：
   - 正文、来源应用、URL、时间、类型、富文本 plain text、文件名、OCR 文本均在 PRD 表格中列出。
   - 类型同义词已给出英文和中文样例，尤其 image 的 `pic`、`picture`、`image`、`ima`、`图片`、`图` 已覆盖需求重点。
   - 排名原则已有初稿：正文/URL/文件/OCR 优先，其次来源应用、类型、时间。

3. OCR 方向与边界合理：
   - 使用 macOS Vision，不引入外部 OCR provider。
   - 只处理已有 image payload。
   - OCR 异步执行，搜索不等待 OCR 完成。
   - 状态模型包括 pending / running / done / failed / retry。
   - 失败应局部隔离，不影响其他记录。

4. 设置页移除方向明确：
   - 与明文展示冲突且不可调的内容保护/存储设置需要隐藏或移除。
   - 容量、保留时间、性能类设置可保留，但必须仍然真实有效。

5. 输出边界已有原则：
   - 面板和搜索使用真实内容。
   - 日志、CLI、provider、automation 输出默认受控。
   - 不允许 provider 静默上传内容或图片。
   - 不应把真实剪贴板内容、secret、API key 写入文档或验证输出。

## 必须补清的问题

1. 时间搜索仍不可判定。
   PRD 目前写成“合理搜索或筛选入口；输入格式由技术方案定”。从测试角度，这会导致 Step 1 验收时无法判断时间字段是否通过。需要在 PRD 或开发前验收契约中至少明确一种可测形式：
   - 支持哪些最小查询样例，例如 `today`、`2026-07-07`、`07-07`、`最近` 中的哪些。
   - 如果 Step 1 不做自然语言时间搜索，则明确时间只通过可见 filter 或排序入口验收。
   - 对不支持的时间输入，应如何显示无结果或不匹配，避免测试把模糊能力误判为缺陷。

2. OCR 排队、失败和重试缺少确定性夹具或测试钩子。
   OCR 状态枚举齐全，但验收样例还需要可复现的输入和判定方式：
   - 成功 fixture：含 `VISION-004` 的低敏图片，完成后搜索 `VISION-004` 命中。
   - 排队/运行 fixture：可以稳定观察 pending/running，不要求依赖机器速度碰运气。
   - 失败 fixture：无效图片或受控 mock 失败，状态为 failed，错误输出低敏。
   - 重试 fixture：失败后触发 retry，状态重新进入 pending/running 或完成 done。
   - 搜索在 OCR pending 时不冻结、不阻塞，并能明确显示 partial / pending。

3. 设置页移除需要列出负向验收 token。
   “内容保护/存储设置”范围目前足够表达产品意图，但测试需要具体到 UI 文案、设置 key 或视图段落，否则无法区分“未移除”“改名保留”和“合理保留”。建议补充：
   - 必须消失的设置项名称或 key。
   - 必须保留的设置项名称或 key，例如容量、保留时间、性能相关项。
   - 若旧设置仍存在于存储层但 UI 不展示，也应说明是否允许。

4. 输出边界需要分成“未触碰路径”和“触碰路径”的验收规则。
   PRD 已有原则，但最终验收需要更具体的 pass/fail：
   - 若 Step 1 不改 CLI/provider/automation，则验收应确认没有新增默认输出真实内容的路径。
   - 若改动 CLI 或日志，则必须定义默认截断、分页、结构化字段或显式参数规则。
   - 自动化验证输出只能使用低敏 fixture，不得包含完整本地 home 路径、真实剪贴板正文、secret、Authorization header、图片 base64、OCR 原文中的敏感内容。

5. 性能回归缺少最低可测门槛。
   PRD 正确要求异步和缓存，但还需要最低验收口径，否则“不卡顿”不可判定。建议至少写清：
   - 打开面板不等待 OCR 完成。
   - 输入搜索不触发同步 OCR 或大量 payload 同步读取。
   - 大图/多图 OCR 进入队列或批处理，不阻塞列表渲染。
   - 若具体毫秒阈值由技术方案确定，PRD 应要求开发记录和验收记录补充最终阈值与测量方式。

## 建议补充的验收矩阵

1. 展示矩阵：
   - text：正文含 `Alpha roadmap item 004 search baseline`，面板默认可见可读片段。
   - URL：`https://example.com/blocks/clipboard-step1` 可见并可搜索 host/path。
   - rich text：富文本 fixture 的 plain text 可见并可搜索。
   - image：显示缩略图或明确图片状态，OCR 状态可见。
   - file：文件名可见并可搜索；路径展示若截断，应保留文件名。
   - long text：允许摘要/截断，但要能识别内容，不得退回只显示类型壳。

2. 搜索矩阵：
   - body 命中、source app 命中、URL 命中、file name 命中、rich text plain 命中、OCR text 命中。
   - type synonym 命中：至少覆盖 image 的 `pic`、`picture`、`image`、`ima`、`图片`、`图`，以及 text/url/file/rich text 的代表词。
   - ranking：同一查询下直接内容命中应排在 source/type/time 弱命中之前；同分按最近记录排序。
   - negative：Step 1 不要求 tag/favorite/detail-edit 字段参与搜索，不能因为标签不可搜判失败。

3. OCR 矩阵：
   - pending：记录进入 OCR 队列但搜索仍可用。
   - running：可观察运行态或等价进度态。
   - done：`VISION-004` 可被搜索命中。
   - failed：失败状态可见，错误低敏，不影响其他记录。
   - retry：失败后可重试，状态转换可验证。
   - cache：已完成 OCR 不应在普通搜索中重复同步识别。

4. 设置页矩阵：
   - 冲突的内容保护/存储 UI 不再可见。
   - 仍有效的容量/保留时间/性能设置保留。
   - 若旧 key 仍存在，只要 UI 不暴露且行为不冲突，应在开发记录中说明。

5. 输出与低敏 fixture 矩阵：
   - 所有自动化 fixture 使用合成数据。
   - 验证 JSON、日志、开发记录、验收记录不包含真实剪贴板正文、完整本地路径、home、邮箱、secret、Authorization header、图片 base64。
   - provider 路径无静默上传；OCR 不调用外部 provider。
   - CLI 若被触碰，默认输出有边界，完整 payload 需要显式参数或分页。

## 测试不可判定项

1. Vision 支持语言范围。
   PRD 已把语言支持交给 App 架构确认，这是合理的。测试侧只能验收最终声明的支持范围，不能默认要求中英文以外的 OCR 能力。

2. 具体性能阈值。
   目前只能判断“不得同步阻塞 OCR / 大 payload”，无法判定具体耗时是否达标。需要技术方案或开发记录补足测试环境、样本规模和阈值。

3. 时间字段搜索形态。
   在格式或入口明确前，测试无法判断时间搜索通过与否。

4. 设置项移除范围。
   在负向 token / setting key 明确前，测试无法稳定判断 UI 是否完全移除了冲突项。

5. OCR retry 的用户入口。
   PRD 允许 UI 或技术方案决定入口，这可以接受，但开发前必须落成可验收的具体入口或等价触发方式。

## 回归风险

1. 从 Step 4D clipboard hardening 回到“面板展示真实内容”时，容易误伤此前的默认低敏输出边界。测试需要区分 UI 面板可读内容与日志/CLI/自动化输出受控，不应混为一个开关。

2. 搜索底座若为提高命中率直接预加载所有 payload，可能带来性能和隐私输出回归。Step 1 可以读取真实内容，但仍需要避免无界输出和同步阻塞。

3. OCR 异步队列若缺少失败隔离，单张坏图可能拖慢或阻断整个搜索索引。

4. 设置页移除如果只隐藏文案、不处理行为入口，用户仍可能看到与明文展示冲突的旧状态或旧设置。

5. 类型同义词如果只覆盖英文完整词，用户提出的 `ima`、`pic`、`图片`、`图` 会继续失败，必须纳入自动化样例。

## 建议的开发前质量门禁

1. 新增或更新 Step 1 专用验证脚本，至少覆盖：
   - 明文展示 fixture。
   - 搜索字段和类型同义词。
   - OCR 状态与 retry。
   - 设置页冲突项负向检查。
   - 输出低敏检查。

2. 保留现有 clipboard storage / appstate / UI fixture 回归门禁，但只把与 Step 1 当前事实源相关的检查作为阻断。旧归档、旧 story、旧 acceptance 只能作为 baseline reference，不能参与 `ok`。

3. 最终验收建议串行运行：
   - Step 1 新增门禁脚本。
   - Clipboard repository / AppState 相关回归脚本。
   - Settings 相关静态/UI 检查。
   - Blocks App build。
   - BlocksCLI build 与 `blocks --help`，仅当 Step 1 触碰 CLI 或项目固定门禁要求时阻断。
   - `git diff --check`。

4. 实物验收建议最小覆盖：
   - 合成 text/url/rich text/image/file 记录在面板默认可读。
   - 搜索 `Alpha`、source app、URL path、文件名、`pic`、`图片`、`VISION-004`。
   - OCR pending/running/done/failed/retry 视觉状态。
   - 设置页冲突项不可见。
   - 不触发外部 provider 上传、不读取真实敏感剪贴板样本。

## 是否需要向用户继续澄清

从测试/质量角度，当前没有必须回到用户层面澄清的 Step 1 范围问题。需要补清的是 PRD / 技术方案内部验收契约：时间搜索格式、OCR 可复现状态、设置项负向清单、输出边界 pass/fail、性能阈值或测量方式。
