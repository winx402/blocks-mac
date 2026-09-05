# 004_剪贴板打磨阶段总览

状态：completed-with-p2-residuals
最后审阅：2026-07-07
来源级别：project control

本文由项目负责人基于原始需求、需求澄清、角色澄清回收和用户补充意见拆解。本文不是 PRD；产品经理应基于本文指定的阶段范围分别产出阶段 PRD。

## 使用规则

- 本项目属于大需求，不直接进入全量 PRD。
- 按用户最新要求，004 后续严格串行推进：当前 step 开发和验收完成前，不进入下一 step 的收敛、技术方案修订或开发。
- 同一顶层 step 内的开发批次可以适当合并，不必为了形式拆得过细；项目负责人仍需保证范围、验收和需求覆盖不丢失。
- 产品经理应按阶段接收任务，每次只围绕一个阶段做详细产品设计和阶段 PRD。
- 阶段 PRD 进入开发前，项目负责人必须组织必要角色复审并更新阶段状态。
- `产品经理-PRD-v0.md` 是阶段拆解前产生的全量草稿，仅作为参考材料，不作为开发输入。
- [需求覆盖矩阵 v0](需求覆盖矩阵-v0.md) 是阶段拆解和阶段 PRD 的覆盖追踪入口；任何阶段 PRD 都必须回填覆盖状态。
- 后续如创建阶段目录，使用 `step_1/`、`step_2/` 等目录存放该阶段 PRD、评审、开发、验收和证据。

## 阶段总览

| 阶段 | 状态 | 主题 | 当前动作 |
| --- | --- | --- | --- |
| Step 0 | completed | 需求采集、澄清和角色问题回收 | 已完成 |
| Step 1 | accepted | 明文展示、搜索底座与系统 Vision OCR | 已完成项目负责人验收，进入 Step 2 |
| Step 2 | accepted | 标签与收藏模型替换 | 已完成最终验收，P0/P1 清零，保留 P2 residual |
| Step 3 | accepted | 面板交互与布局打磨 | 已完成最终验收，P0/P1 清零，保留 P2 residual |
| Step 4 | accepted | 详情编辑与元数据组织 | 已完成最终验收，P0/P1 清零，保留 P2 residual |
| Step 5 | accepted | 隐私页真实 App 清单与 CLI 广义对象管理 | 已完成最终验收，P0/P1 清零，保留 P2 residual |
| Step 6 | accepted | 集成验收与收口 | 已完成复审收敛和项目最终验收，P0/P1 清零，保留 P2 residual |

## Step 0：需求采集、澄清和角色问题回收

状态：completed

目标：

- 完整记录用户原始需求。
- 澄清内容保护、搜索、标签、收藏、隐私页、详情编辑、OCR、输出边界和流程协作问题。
- 回收产品、UI/交互、App 架构、开发、测试/质量、安全合规意见。
- 形成阶段拆解输入。

已产出：

- [原始需求记录 v0](原始需求记录-v0.md)
- [需求澄清记录 v0](需求澄清记录-v0.md)
- [角色澄清回收 v0](角色澄清回收-v0.md)
- [需求澄清记录 v1](需求澄清记录-v1.md)

## Step 1：明文展示、搜索底座与系统 Vision OCR

状态：accepted

阶段目标：

- 先解决剪贴板面板“看不见内容、搜不到内容”的基础问题。
- 建立可扩展搜索索引和系统 Vision OCR 的产品边界。
- 明确“真实内容可访问，交互输出可控”的第一阶段表达方式。

必须覆盖：

- 面板默认展示真实可读内容，不再只显示字符数或过度遮挡摘要。
- 设置页移除与明文展示目标冲突、且用户不能有效调整的剪贴板存储/内容保护 UI。
- 搜索覆盖正文、来源 App、URL、时间、类型、富文本纯文本化内容、文件名。
- 类型关键词和同义词，例如 `pic`、`picture`、`image`、`ima`、`图片`、`图` 能命中图片类条目。
- OCR 进入阶段范围，但限定使用 macOS Vision，不做自研 OCR，不使用外部 provider OCR。
- OCR 必须异步，不阻塞面板打开、搜索输入和滚动。
- OCR 状态需要可感知：待处理、处理中、完成、失败、可重试。
- 日志、CLI、provider、自动化在本阶段先明确“可访问真实内容但输出可控”的原则，不做复杂权限开关或过滤系统。

明确不覆盖：

- 标签/收藏数据模型替换。
- 详情编辑保存和富文本编辑。
- 隐私页全量 App 管理。
- 面板筛选组 hover、安全区域、单/双击设置和卡片密度等专项 UI 打磨。
- 旧 pinboard/固定逻辑迁移。

产品经理交付物：

- `step_1/产品经理-PRD-v0.md`，若不创建阶段目录，则先写 `step_1-产品经理-PRD-v0.md`。
- 明确用户可见行为、非目标、验收样例、搜索字段、OCR 状态和输出边界文案。
- 列出进入技术方案前仍需 App 架构师确认的问题。

建议参与复审角色：

- UI/交互设计师。
- App 架构师。
- 安全合规顾问。
- 测试/质量。

当前复审结论：

- UI/交互设计师、App 架构师、安全合规顾问、测试/质量均为 `approve-with-changes`。
- 项目负责人已形成 [PRD 复审收敛 v0](step_1/项目负责人-PRD复审收敛-v0.md)。
- 产品经理已产出 `step_1/产品经理-PRD-v1.md`。
- 项目负责人已完成 [PRD v1 复核 v0](step_1/项目负责人-PRD-v1复核-v0.md)，结论为 `prd-accepted`。
- App 架构师已产出 [技术方案 v0](step_1/App架构师-技术方案-v0.md)。
- 项目负责人已完成 [技术方案预审 v0](step_1/项目负责人-技术方案预审-v0.md)，结论为 `approve-for-role-review`。
- 开发、测试/质量、安全合规和 UI/交互设计师技术方案复审均已完成，结论均为 `approve-with-changes`。
- 项目负责人已形成 [技术方案复审收敛 v0](step_1/项目负责人-技术方案复审收敛-v0.md)，要求 App 架构师补 `step_1/App架构师-技术方案-v1.md`。
- App 架构师已产出 [技术方案 v1](step_1/App架构师-技术方案-v1.md)。
- 项目负责人已完成 [技术方案 v1 复核 v0](step_1/项目负责人-技术方案-v1复核-v0.md)，结论为 `technical-plan-accepted`。
- 项目负责人已完成 [Step 1A-0 开发派发 v0](step_1/项目负责人-开发派发-Step1A-0-v0.md)，只允许先建立 P13A baseline red。
- 开发已完成 Step 1A-0，项目负责人已完成 [Step 1A-0 验收 v0](step_1/项目负责人-Step1A-0验收-v0.md)，结论为 `accepted`。
- 项目负责人已完成 [Step 1A 开发派发 v0](step_1/项目负责人-开发派发-Step1A-v0.md)，进入 search document 与 bounded preview 基础实现。
- 开发已完成 Step 1A，项目负责人已完成 [Step 1A 验收 v0](step_1/项目负责人-Step1A验收-v0.md)，结论为 `accepted`。
- 项目负责人已完成 [Step 1B 开发派发 v0](step_1/项目负责人-开发派发-Step1B-v0.md)，进入搜索状态与 Store/UI 接入开发。
- 开发已完成 Step 1B，项目负责人已完成 [Step 1B 验收 v0](step_1/项目负责人-Step1B验收-v0.md)，结论为 `accepted`。
- 项目负责人已完成 [Step 1C 开发派发 v0](step_1/项目负责人-开发派发-Step1C-v0.md)，进入系统 Vision OCR 队列开发。
- 根据用户补充要求，同一顶层 step 内开发不再拆得过细；项目负责人已完成 [Step 1C/1D 合并开发补充派发 v0](step_1/项目负责人-开发派发-Step1C-1D补充-v0.md)，本轮并入设置页清理、输出边界与门禁迁移，作为 Step 1 收口开发。
- 开发已完成 Step 1C/1D 合并收口；项目负责人发现设置页 repository summary 间接 redacted P1 后要求返工。
- 返工后项目负责人独立复跑 P13A、P8、P8I、P9A、P9B、P11E、Blocks App 构建、BlocksCLI 构建、CLI help 和 `git diff --check`，已完成 [Step 1 验收 v0](step_1/项目负责人-Step1验收-v0.md)，结论为 `accepted`。

Step 1 验收结论：

- 阻塞问题已清零，可以恢复 Step 2。
- 未做真实 App UI、真实剪贴板、真实 Vision OCR、TCC、provider、系统设置或自动化动作；这些不作为 Step 1 本次接受证据。

## Step 2：标签与收藏模型替换

状态：accepted

阶段目标：

- 用标签/收藏替代旧 pinboard/固定概念。
- 建立多标签、收藏、标签管理和标签筛选的稳定模型。

必须覆盖：

- 一个条目可以有多个标签。
- 标签不能重名，默认去首尾空格并大小写不敏感校验。
- 标签支持颜色、排序、重命名、合并。
- 设置页可查看和管理标签。
- 条目右键可添加标签、删除标签、新建标签。
- “收藏”是内置标签，五角星图标、默认第一、不可删除。
- 点击收藏等同于添加或移除“收藏”标签。
- 旧 pinboard/固定逻辑直接移除，不做迁移和兼容。

明确不覆盖：

- 明文展示和 OCR 底座。
- 详情编辑。
- 隐私页 App 管理。
- 全量面板视觉重设计。

产品经理交付物：

- 阶段 PRD。
- 标签管理信息结构、右键菜单行为、合并规则和验收口径。

当前状态：

- 产品经理已产出 `step_2/产品经理-PRD-v0.md`。
- 项目负责人已完成 [PRD 预审 v0](step_2/项目负责人-PRD预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互设计师、App 架构师、开发、测试/质量复审均已完成，结论均为 `approve-with-changes`。
- 项目负责人已形成 [PRD 复审收敛 v0](step_2/项目负责人-PRD复审收敛-v0.md)。
- 产品经理已产出 `step_2/产品经理-PRD-v1.md`。
- 项目负责人已完成 [PRD v1 复核 v0](step_2/项目负责人-PRD-v1复核-v0.md)，结论为 `prd-accepted`。
- App 架构师已产出 [技术方案 v0](step_2/App架构师-技术方案-v0.md)。
- 项目负责人已完成 [技术方案预审 v0](step_2/项目负责人-技术方案预审-v0.md)，结论为 `approve-for-role-review`。
- 开发、测试/质量和 UI/交互设计师技术方案复审已产出，结论均为 `approve-with-changes`。
- 项目负责人已形成 [技术方案复审收敛 v0](step_2/项目负责人-技术方案复审收敛-v0.md)。
- Step 1 已验收接受；项目负责人已完成 [技术方案 v1 修订派发 v0](step_2/项目负责人-技术方案v1修订派发-v0.md)，要求 App 架构师产出 `step_2/App架构师-技术方案-v1.md`。
- App 架构师已产出 [技术方案 v1](step_2/App架构师-技术方案-v1.md)。
- 项目负责人已完成 [技术方案 v1 复核 v0](step_2/项目负责人-技术方案-v1复核-v0.md)，结论为 `technical-plan-accepted`。
- 项目负责人已完成 [Step 2 开发派发 v0](step_2/项目负责人-开发派发-Step2-v0.md)，按一个较大批次实现标签与收藏模型替换，但验证输出必须保留 P13B 分层。
- 开发已完成 [开发记录 Step2 v0](step_2/开发记录-Step2-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 2 开发验收 v0](step_2/项目负责人-Step2开发验收-v0.md)，结论为 `development-verified-pending-review`。
- 代码审查、测试/质量复核和 UI/交互复核均已完成。
- 测试/质量结论为 `approve`，UI/交互设计师结论为 `approve-with-changes` 且无 P0/P1，代码审查结论为 `approve-with-changes` 并发现 tag search 重建 / 缺失文档路径 P1。
- 项目负责人已形成 [Step 2 开发复审收敛 v0](step_2/项目负责人-Step2开发复审收敛-v0.md)，不接受将该 P1 降级为 residual risk，要求开发返工。
- 开发已完成 [返工开发记录 R1 v0](step_2/开发记录-Step2-R1-v0.md)。
- 项目负责人已完成 [Step 2 R1 验收 v0](step_2/项目负责人-Step2-R1验收-v0.md)，结论为 `development-rework-verified-pending-targeted-review`。
- 代码审查、测试/质量和 UI/交互 R1 定向复审已完成。
- 项目负责人已完成 [Step 2 最终验收 v0](step_2/项目负责人-Step2最终验收-v0.md)，结论为 `accepted-with-p2-residuals`。
- Step 2 已接受，可以恢复 Step 3。
- 标签端到端搜索依赖 Step 1 搜索底座，不得在技术方案或验收中伪装为已独立闭合。

Step 2 接受后残余：

- Settings 标签管理的行内反馈仍是 P2 residual。
- 右键菜单新建标签仍是固定默认名快速创建，完整命名输入未在本阶段实现。
- 真实 UI / VoiceOver / 真实剪贴板证据未覆盖；后续 Step 3 或 Step 6 回扫。

## Step 3：面板交互与布局打磨

状态：accepted

阶段目标：

- 聚焦高频面板操作体验和页面质感。
- 让筛选、搜索、选择、单/双击设置和条目密度更稳定。

必须覆盖：

- 筛选组 hover 展开后的安全区域、距离阈值或延迟收起。
- 筛选组横向长度扩大，展开后不遮挡右侧关键操作。
- 搜索框适度缩短，为筛选组让出空间。
- 条目点击后选中反馈即时，不明显滞后于鼠标动作。
- 单击/双击改为显性点击选择控件，而不是下拉菜单。
- 条目上下边框或内边距收窄，核心内容面积变大。
- 宽窄窗口、长文本、长标签、长来源 App 等布局不重叠。

明确不覆盖：

- 标签数据模型本身。
- 搜索索引和 OCR pipeline。
- 详情编辑事务。
- 隐私页 App 扫描。

产品经理交付物：

- 阶段 PRD 或交互规格。
- 关键状态、控件行为、布局验收和低敏截图/录屏验收要求。

当前状态：

- 产品经理已产出 `step_3/产品经理-PRD-v0.md`。
- 项目负责人已完成 [PRD 预审 v0](step_3/项目负责人-PRD预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互设计师和测试/质量 PRD 复审已产出，结论均为 `approve-with-changes`。
- 开发复审因项目切回串行推进而暂停；已产出的材料保留为后续输入。
- Step 2 已最终接受；当前已恢复 Step 3 PRD 复审收敛。
- 项目负责人已完成 [PRD 复审收敛 v0](step_3/项目负责人-PRD复审收敛-v0.md)，要求产品经理产出 `step_3/产品经理-PRD-v1.md`。
- 产品经理已产出 `step_3/产品经理-PRD-v1.md`。
- 项目负责人已完成 [PRD v1 复核 v0](step_3/项目负责人-PRD-v1复核-v0.md)，结论为 `prd-accepted`。
- 项目负责人已完成 [技术方案派发 v0](step_3/项目负责人-技术方案派发-v0.md)，要求 App 架构师产出 `step_3/App架构师-技术方案-v0.md`。
- App 架构师已产出 [技术方案 v0](step_3/App架构师-技术方案-v0.md)。
- 项目负责人已完成 [技术方案预审 v0](step_3/项目负责人-技术方案预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互设计师、开发和测试/质量技术方案复审均已完成，结论均为 `approve-with-changes`。
- 项目负责人已完成 [技术方案复审收敛 v0](step_3/项目负责人-技术方案复审收敛-v0.md)，已要求 App 架构师产出 `step_3/App架构师-技术方案-v1.md`。
- App 架构师已产出 [技术方案 v1](step_3/App架构师-技术方案-v1.md)。
- 项目负责人已完成 [技术方案 v1 复核 v0](step_3/项目负责人-技术方案-v1复核-v0.md)，结论为 `technical-plan-accepted`。
- 项目负责人已完成 [Step 3 开发派发 v0](step_3/项目负责人-开发派发-Step3-v0.md)，开发任务已派发。
- 开发已完成 [开发记录 Step3 v0](step_3/开发记录-Step3-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 3 开发验收 v0](step_3/项目负责人-Step3开发验收-v0.md)，结论为 `development-verified-pending-review`。
- 代码审查、UI/交互设计师和测试/质量开发实现复审已派发。
- 代码审查结论为 `rework-required`，UI/交互设计师结论为 `approve-with-changes` 但存在 P1，测试/质量结论为 `approve`。
- 项目负责人已完成 [Step 3 开发复审收敛 v0](step_3/项目负责人-Step3开发复审收敛-v0.md)，要求开发进行 R1 返工。
- 开发已完成 [开发记录 Step3 R1 v0](step_3/开发记录-Step3-R1-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 3 R1 验收 v0](step_3/项目负责人-Step3-R1验收-v0.md)，结论为 `development-rework-verified-pending-targeted-review`。
- 代码审查、UI/交互设计师、测试/质量 R1 定向复审已完成；P0/P1 清零。
- 项目负责人已完成 [Step 3 最终验收 v0](step_3/项目负责人-Step3最终验收-v0.md)，结论为 `accepted-with-p2-residuals`。
- Step 3 已接受，可以按串行流程启动 Step 4。

建议参与复审角色：

- UI/交互设计师。
- 测试/质量。
- 开发。

## Step 4：详情编辑与元数据组织

状态：accepted

阶段目标：

- 让详情页成为可编辑、可阅读、布局稳定的信息面板。
- 处理 plain text、URL、富文本文本内容和图片 OCR 文本的编辑边界。

必须覆盖：

- 可编辑类型：plain text、URL、富文本文本内容、图片 OCR 文本。
- 不编辑图片本体、文件本体和其他非文本类 payload 本体。
- 显式保存 + 取消。
- 保存/取消控件有稳定布局位，不因出现或消失导致页面跳动。
- 保存后更新内部内容、原始 payload 或派生字段、搜索索引、更新时间和可见摘要。
- 不同步更新系统剪贴板。
- 富文本目标是尽量保留原格式；如技术评估无法可靠保留，必须回到项目负责人做范围取舍，不能静默丢格式。
- OCR 文本编辑只更新 OCR 文本、索引和详情展示，不改写图片 payload 本体。
- 编辑区默认 2 行、最多 4 行，超过滚动。
- 元数据短项两列、长项单行，不挤压编辑区。

明确不覆盖：

- 图片本体编辑。
- 文件本体编辑。
- 全功能富文本编辑器扩展。
- 系统剪贴板同步写回。

产品经理交付物：

- 阶段 PRD。
- 保存/取消交互、dirty state、失败回滚、富文本降级风险和验收口径。

建议参与复审角色：

- UI/交互设计师。
- App 架构师。
- 开发。
- 测试/质量。

当前状态：

- Step 3 已最终接受，允许按串行流程启动 Step 4。
- 项目负责人已完成 [Step 4 PRD 派发 v0](step_4/项目负责人-PRD派发-Step4-v0.md)，要求产品经理产出 `step_4/产品经理-PRD-v0.md`。
- 产品经理已产出 `step_4/产品经理-PRD-v0.md`。
- 项目负责人已完成 [Step 4 PRD 预审 v0](step_4/项目负责人-PRD预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互设计师、App 架构师、开发、测试/质量 PRD v0 角色复审已完成。
- 项目负责人已完成 [Step 4 PRD 复审收敛 v0](step_4/项目负责人-PRD复审收敛-v0.md)，结论为 `prd-revision-required`。
- 产品经理已产出 `step_4/产品经理-PRD-v1.md`。
- 项目负责人已完成 [Step 4 PRD v1 复核 v0](step_4/项目负责人-PRD-v1复核-v0.md)，结论为 `prd-accepted`。
- 项目负责人已完成 [Step 4 技术方案派发 v0](step_4/项目负责人-技术方案派发-v0.md)，等待 App 架构师产出 `step_4/App架构师-技术方案-v0.md`。
- App 架构师已产出 `step_4/App架构师-技术方案-v0.md`。
- 项目负责人已完成 [Step 4 技术方案预审 v0](step_4/项目负责人-技术方案预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互设计师、开发、测试/质量、代码审查、安全合规顾问技术方案 v0 角色复审已完成。
- 项目负责人已完成 [Step 4 技术方案复审收敛 v0](step_4/项目负责人-技术方案复审收敛-v0.md)，结论为 `technical-plan-revision-required`。
- App 架构师已产出 `step_4/App架构师-技术方案-v1.md`。
- 项目负责人已完成 [Step 4 技术方案 v1 复核 v0](step_4/项目负责人-技术方案-v1复核-v0.md)，结论为 `technical-plan-accepted`。
- 项目负责人已完成 [Step 4 开发派发 v0](step_4/项目负责人-开发派发-Step4-v0.md)。
- 开发已完成 [开发记录 Step4 v0](step_4/开发记录-Step4-v0.md)，结论为 `implemented-with-evidence`。
- 项目负责人已完成 [Step 4 开发验收 v0](step_4/项目负责人-Step4开发验收-v0.md)，结论为 `development-verified-pending-review`。
- 代码审查、App 架构、UI/交互、测试/质量和安全合规开发实现复审均已完成，结论均为 `rework-required`。
- 项目负责人已完成 [Step 4 开发复审收敛 v0](step_4/项目负责人-Step4开发复审收敛-v0.md)，结论为 `rework-required`。
- 项目负责人已完成 [Step 4 R1 开发返工派发 v0](step_4/项目负责人-开发派发-Step4-R1-v0.md)。
- 开发已完成 [开发记录 Step4 R1 v0](step_4/开发记录-Step4-R1-v0.md)。
- 开发已完成 [开发记录 Step4 R1a v0](step_4/开发记录-Step4-R1a-v0.md)，只修正 P13D 当前证据指针。
- 项目负责人已完成 [Step 4 R1 开发验收 v0](step_4/项目负责人-Step4-R1验收-v0.md)，结论为 `development-rework-verified-pending-targeted-review`；等待角色定向复审，定向复审完成前不进入 Step 5。
- App 架构师、代码审查、UI/交互、测试/质量和安全合规 R1 定向复审均已完成。
- 项目负责人已完成 [Step 4 R1 复审收敛 v0](step_4/项目负责人-Step4-R1复审收敛-v0.md)，结论为 `rework-required`，原因是面板级关闭路径仍可绕过 dirty navigation guard。
- 项目负责人已完成 [Step 4 R2 开发返工派发 v0](step_4/项目负责人-开发派发-Step4-R2-v0.md)；R2 验收前不进入 Step 5。
- 开发已完成 [开发记录 Step4 R2 v0](step_4/开发记录-Step4-R2-v0.md)。
- 项目负责人已完成 [Step 4 R2 开发验收 v0](step_4/项目负责人-Step4-R2验收-v0.md)，结论为 `development-rework-verified-pending-targeted-review`；等待 UI/交互、代码审查和测试/质量定向复审，复审完成前不进入 Step 5。
- UI/交互、代码审查和测试/质量 R2 定向复审均已完成。
- 项目负责人已完成 [Step 4 R2 复审收敛 v0](step_4/项目负责人-Step4-R2复审收敛-v0.md)，结论为 `rework-required`，原因是 AppModel 调用方仍把 guarded close 当同步 close 使用。
- 项目负责人已完成 [Step 4 R3 开发返工派发 v0](step_4/项目负责人-开发派发-Step4-R3-v0.md)；R3 验收前不进入 Step 5。

## Step 5：隐私页真实 App 清单与 CLI 广义对象管理

状态：accepted

当前状态：

- 产品经理已产出 [Step 5 PRD v0](step_5/产品经理-PRD-v0.md)。
- 项目负责人已完成 [Step 5 PRD 预审 v0](step_5/项目负责人-PRD预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互、App 架构师、测试/质量、安全合规顾问均已完成 PRD v0 复审，结论均为 `approve-with-changes`。
- 项目负责人已完成 [Step 5 PRD 复审收敛 v0](step_5/项目负责人-PRD复审收敛-v0.md)，要求产品经理产出 PRD v1。
- 产品经理已产出 [Step 5 PRD v1](step_5/产品经理-PRD-v1.md)。
- 项目负责人已完成 [Step 5 PRD v1 预审 v0](step_5/项目负责人-PRD-v1预审-v0.md)，结论为 `approve-for-targeted-role-review`。
- UI/交互、App 架构师、测试/质量、安全合规顾问均已完成 PRD v1 定向复审，结论均为 `approve`，P0/P1 清零。
- 项目负责人已完成 [Step 5 PRD 最终接受 v0](step_5/项目负责人-PRD最终接受-v0.md)，允许进入技术方案阶段。
- App 架构师已产出 [Step 5 技术方案 v0](step_5/App架构师-技术方案-v0.md)。
- 项目负责人已完成 [Step 5 技术方案预审 v0](step_5/项目负责人-技术方案预审-v0.md)，结论为 `approve-for-role-review`。
- UI/交互、安全合规、测试/质量已完成技术方案 v0 复审；测试/质量提出 2 个 P1。
- 项目负责人已完成 [Step 5 技术方案复审收敛 v0](step_5/项目负责人-技术方案复审收敛-v0.md)，要求 App 架构师产出技术方案 v1。
- App 架构师已产出 [Step 5 技术方案 v1](step_5/App架构师-技术方案-v1.md)。
- 项目负责人已完成 [Step 5 技术方案 v1 预审 v0](step_5/项目负责人-技术方案-v1预审-v0.md)，结论为 `approve-for-targeted-qa-review`，等待测试/质量定向复审。
- 测试/质量已完成 [Step 5 技术方案 v1 定向复审 v0](step_5/测试-质量-技术方案-v1定向复审-v0.md)，结论为 `approve`。
- 项目负责人已完成 [Step 5 技术方案最终接受 v0](step_5/项目负责人-技术方案最终接受-v0.md)，结论为 `technical-plan-accepted`。
- 项目负责人已完成 [Step 5 开发派发 v0](step_5/项目负责人-开发派发-Step5-v0.md)，开发任务已派发；开发完成和验收前不进入 Step 6。
- 开发已完成 [Step 5 开发记录 v0](step_5/开发记录-Step5-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 5 开发验收 v0](step_5/项目负责人-Step5开发验收-v0.md)，结论为 `rework-required`；P13E stdout evidence schema 与 required scenario id 未对齐 accepted contract，R1 返工完成前不进入角色复审或 Step 6。
- 开发已完成 [Step 5 R1 开发记录 v0](step_5/开发记录-Step5-R1-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 5 R1 验收 v0](step_5/项目负责人-Step5-R1验收-v0.md)，结论为 `development-rework-verified-pending-code-review`；等待代码审查，代码审查完成前不进入 Step 6。
- 代码审查已完成 [Step 5 开发复审 v0](step_5/代码审查-Step5开发复审-v0.md)，结论为 `rework-required`，发现 4 个 P1。
- 项目负责人已完成 [Step 5 开发复审收敛 v0](step_5/项目负责人-Step5开发复审收敛-v0.md)，接受代码审查结论。
- 项目负责人已完成 [Step 5 R2 开发派发 v0](step_5/项目负责人-开发派发-Step5-R2-v0.md)，R2 验收前不进入角色复审或 Step 6。
- 开发已完成 [Step 5 R2 开发记录 v0](step_5/开发记录-Step5-R2-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 5 R2 验收 v0](step_5/项目负责人-Step5-R2验收-v0.md)，结论为 `development-rework-verified-pending-code-review`；等待代码审查 R2 定向复审，复审完成并收敛前不进入 Step 6。
- 代码审查已完成 [Step 5 R2 复审 v0](step_5/代码审查-Step5-R2复审-v0.md)，结论为 `rework-required`，发现 1 个 P1：legacy migration 冲突时覆盖已有 current policy rule，且 P13E 未覆盖该冲突分支。
- 项目负责人已完成 [Step 5 R2 复审收敛 v0](step_5/项目负责人-Step5-R2复审收敛-v0.md)，接受代码审查结论。
- 项目负责人已完成 [Step 5 R3 开发派发 v0](step_5/项目负责人-开发派发-Step5-R3-v0.md)，R3 验收前不进入 Step 6。
- 开发已完成 [Step 5 R3 开发记录 v0](step_5/开发记录-Step5-R3-v0.md)，结论为 `DONE_WITH_EVIDENCE`。
- 项目负责人已完成 [Step 5 R3 验收 v0](step_5/项目负责人-Step5-R3验收-v0.md)，结论为 `development-rework-verified-pending-code-review`；等待代码审查 R3 定向复审，复审完成并收敛前不进入 Step 6。
- 代码审查已完成 [Step 5 R3 复审 v0](step_5/代码审查-Step5-R3复审-v0.md)，结论为 `approve`，P0/P1 为 0。
- 项目负责人已完成 [Step 5 最终验收 v0](step_5/项目负责人-Step5最终验收-v0.md)，结论为 `accepted-with-p2-residuals`。
- Step 5 已接受，可以按串行流程启动 Step 6。

阶段目标：

- 让隐私页展示真实系统 App 清单和图标。
- 让 CLI 能以低歧义方式管理 UI 范围外对象。

必须覆盖：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 下真实 `.app`。
- 使用真实系统 App 图标，读取失败时 fallback。
- 列表支持搜索、过滤和稳定排序。
- 真实 App 清单和图标只做本地枚举与展示，不上传 provider。
- CLI 可管理登录项、helper、命令行工具或其他 bundle identifier / path。
- CLI 管理对象需要 typed subject / 标识模型，避免 bundle id、路径、进程名混用。

明确不覆盖：

- 任意系统状态变更执行器。
- 静默请求 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset。
- UI 展示所有 CLI 广义对象，除非后续另行确认。

产品经理交付物：

- 阶段 PRD。
- App 列表体验、图标 fallback、CLI 对象模型、危险动作边界和验收口径。

建议参与复审角色：

- App 架构师。
- 安全合规顾问。
- UI/交互设计师。
- 测试/质量。

## Step 6：集成验收与收口

状态：accepted

阶段目标：

- 在各阶段完成后做整体回归、体验收口和文档状态更新。

必须覆盖：

- 明文展示、搜索、OCR、标签、收藏、面板交互、详情编辑、隐私页和 CLI 边界的综合验收。
- 旧 pinboard/pinned、旧 redacted 默认面板和不可用搜索路径不再作为当前事实源。
- 对照 [需求覆盖矩阵 v0](需求覆盖矩阵-v0.md) 回扫所有原始需求、澄清需求和流程需求，确认没有需求丢失、误降级或被阶段切分遗漏。
- 使用 synthetic / fixture 内容，不复制真实用户剪贴板到验收文档。
- 检查性能、布局稳定、长文本、长标签、长 App 名、OCR 失败和 CLI 长输出等风险。

明确不覆盖：

- 新增未纳入前序阶段的功能。
- 未经项目负责人接受的体验重设计。

产品经理交付物：

- 如果前序阶段需求变化较大，提供收口版需求差异说明。
- 配合项目负责人更新最终覆盖回扫记录。

建议参与复审角色：

- 测试/质量。
- UI/交互设计师。
- App 架构师。
- 安全合规顾问。
- 代码审查。

当前状态：

- Step 1-5 已完成最终验收，允许按串行流程启动 Step 6。
- 项目负责人已完成 [Step 6 收口派发 v0](step_6/项目负责人-收口派发-Step6-v0.md)，要求产品经理产出 `step_6/产品经理-收口覆盖回扫-v0.md`。
- 产品经理已产出 [Step 6 收口覆盖回扫 v0](step_6/产品经理-收口覆盖回扫-v0.md)，结论为 `coverage-ready-for-review`。
- 项目负责人已完成 [Step 6 收口预审 v0](step_6/项目负责人-收口预审-v0.md)，结论为 `approve-for-role-review`。
- 测试/质量、UI/交互设计师、App 架构师、安全合规顾问和代码审查收口复审已派发。
- 测试/质量、UI/交互设计师、App 架构师、安全合规顾问和代码审查收口复审已回收。
- 项目负责人已完成 [Step 6 低敏集成验证 v0](step_6/项目负责人-Step6低敏验证-v0.md)，结论为 `low-sensitive-evidence-pass`。
- 项目负责人已完成 [Step 6 复审收敛 v0](step_6/项目负责人-Step6复审收敛-v0.md)，结论为 `ready-for-final-acceptance-with-p2-residuals`。
- 项目负责人已完成 [004 最终验收 v0](项目负责人-最终验收-v0.md)，结论为 `completed-with-p2-residuals`。
