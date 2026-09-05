# Step 2 UI/交互设计师技术方案复审 v0

状态：reviewed
日期：2026-07-07
角色：UI/交互设计师
对象：`App架构师-技术方案-v0.md`
结论：`approve-with-changes`

## 1. 复审范围

本轮只复审 Step 2 技术方案：标签与收藏模型替换。

不进入以下范围：

- Step 1 明文展示、OCR 搜索底座和非标签搜索字段实现。
- Step 3 面板 hover 安全区、搜索框宽度、选中反馈、单 / 双击设置、卡片密度和全量布局打磨。
- Step 4 详情编辑、保存 / 取消、富文本编辑和 OCR 文本编辑。
- Step 5 隐私页真实 App 清单与 CLI 广义对象管理。
- 多标签 OR / AND 组合筛选、批量删除标签、删除前二次确认、自动清理空标签。
- 真实 App 运行、真实剪贴板读取、代码实现或技术方案正文修改。

已读：

- `docs/项目管理库/004_剪贴板打磨/step_2/App架构师-技术方案-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-技术方案预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/产品经理-PRD-v1.md`

本复审是文档级方案复审，没有运行 UI，也没有低敏截图证据。后续开发验收仍需截图或录屏补证。

## 2. 总体判断

技术方案主线成立：`Tag / RecordTag 独立事实源 + Favorite built-in tag + 原子标签事务 + 标签字段搜索契约 + 旧 pinboard/pinned fail-closed 退出门禁` 与 PRD v1 一致，能支撑标签与收藏模型替换。

当前方案做得好的部分：

- 明确不能做 pinboard / pinned 的 UI 改名，必须建立 Tag / RecordTag 当前事实源。
- favorite 有 built-in identity，并拒绝删除、改名、改色、排序和合并 source / target。
- 删除、合并、重命名、添加、移除都落到 repository transaction 或等价一致性边界。
- 单标签筛选、favorite first、右键菜单 checked 状态、Settings tag management 已进入 UI 接入边界。
- Step 1 搜索依赖被拆成字段契约 Gate 与端到端搜索 Gate，避免伪装完成。
- 旧 pinboard / pinned active UI 和 verifier ok evidence 退出方向清楚。

需要补强的是 UI 细节不是模型方向。技术方案目前对 settings row、右键菜单错误反馈、删除/合并影响说明、active filter 的状态迁移和窄宽度布局只写到原则层。进入开发前建议把这些原则补成可实现、可测的最小交互合同。

## 3. 必须改

### 3.1 Settings tag management row 需要固定行结构和禁用原因表达

技术方案写了 favorite row first、ordinary tag rows with color/name/reorder/rename/merge/delete，但还缺稳定行结构和 favorite immutable 的禁用 / 隐藏规则。若开发时有的操作隐藏、有的禁用，用户会难以理解为什么“收藏”看起来像标签却不能编辑。

必须补充：

- 每个 tag row 的固定结构：颜色 swatch、名称、状态 / 内置标识、排序控件、操作入口。
- favorite row 固定第一，普通标签从第二行开始。
- favorite 的不可变更动作是隐藏还是禁用需要统一规则；无论选择哪种，都要有用户可理解原因。
- 操作列宽度和 trailing area 需要稳定，避免普通行和 favorite 行布局跳动。
- 长标签名不能覆盖颜色、排序和操作入口。

建议技术方案可吸收口径：

> Settings tag row 使用稳定行结构：左侧颜色 swatch，中间标签名和可选状态说明，右侧固定操作区。favorite row 固定第一，显示五角星和“内置”或等价状态；删除、改名、改色、排序、合并动作不暴露为可执行操作。若采用禁用控件，tooltip / accessibility label 说明“收藏是内置标签，不能修改”；若采用隐藏动作，row 内仍需有简短状态说明，避免用户误以为功能丢失。

验收样例：

- 只有 favorite 时，Settings 仍显示 favorite row 和新建普通标签入口。
- favorite row 不出现可执行删除 / 改名 / 改色 / 排序 / 合并动作。
- VoiceOver 能读出“收藏，内置标签，不可删除”或等价信息。
- 长标签名不挤压排序控件和操作菜单。

### 3.2 右键菜单的新建失败反馈需要明确落点和关闭行为

技术方案已写 favorite first、checked if attached、new tag entry、duplicate/empty error feedback via Store/AppModel status。这里还需要定义失败反馈出现在哪里，以及菜单是否关闭。否则用户在右键菜单新建失败时可能只看到一个全局 status，不知道刚才输入的问题是什么。

必须补充：

- 已添加和未添加标签的点击语义：checked 表示已添加，点击移除；unchecked 表示未添加，点击添加。
- favorite 在标签菜单第一项，状态与五角星同步。
- 新建标签失败时错误应贴近输入语境，而不是只在远处 status banner 出现。
- 新建失败不应清空输入，也不改变当前记录标签关系。
- 右键菜单关闭策略需要可测：失败后保持可恢复操作，或关闭后必须有明确错误反馈和重新打开路径。

建议技术方案可吸收口径：

> 右键菜单的 tag section 是当前记录的关系编辑入口。favorite first；checked item 表示当前记录已添加该标签，点击移除；unchecked item 点击添加。`New Tag...` 打开轻量输入控件或等价 popover；空名、重名、reserved name 失败时在输入控件附近显示错误并保留输入，当前记录关系不变。若平台限制导致菜单关闭，必须通过同屏可见 status 明确显示失败原因，并允许用户重新进入。

验收样例：

- 已有 `Work` 的记录右键中 `Work` 为 checked，点击后移除。
- 未有 `Draft` 的记录右键中 `Draft` 为 unchecked，点击后添加。
- 右键新建 `work` 命中已有 `Work` 时，显示重名错误，记录标签关系不变。
- 右键 favorite 操作与五角星状态同步。

### 3.3 删除和合并需要补用户可见影响说明

技术方案的事务边界完整，但 UI 侧仍需要把高影响操作翻译给用户。PRD 不要求删除前二次确认，但删除会从所有记录移除标签；合并会转移关联并删除源标签。没有影响说明，用户会误以为只是从当前条目移除。

必须补充：

- 删除普通标签的动作文案必须说明“从所有记录移除此标签”，不能只写“删除”。
- 删除成功 / 失败反馈需要说明结果，不暴露内部事务细节。
- 合并 UI 需要展示源标签、目标标签和结果说明。
- 合并成功后，如果当前筛选是源标签，应切换到目标标签并给出反馈。
- 合并失败不半更新，且 UI 保持原 source / target 状态。

建议技术方案可吸收口径：

> 删除普通标签的操作文案使用“删除标签并从所有记录移除”或等价说明；成功反馈说明标签已移除，失败反馈说明未做更改。合并操作使用 popover / sheet / 等价确认面，明确展示“将 {源标签} 合并到 {目标标签}，相关记录将改为使用 {目标标签}，{源标签} 将被删除”。合并成功后，如当前 active filter 是源标签，切换到目标标签并提示“已切换到 {目标标签}”。

验收样例：

- 删除 `Draft` 时，操作位置能看出会影响所有记录。
- 删除当前筛选 `Draft` 后，筛选回到全部记录。
- `Draft` 合并到 `Work` 后，active filter 从 `Draft` 切到 `Work`。
- 合并失败后，`Draft` 和 `Work` 的设置页、筛选项、条目标签保持原状态。

### 3.4 单标签筛选的 active / clear / delete active / merge active source 需要更具体

技术方案写了 selectedTagID、clear selection path、delete selected clear、merge selected source switch target。UI 侧需要最小视觉和交互规则，否则后续实现可能只有数据变化，没有用户可理解的状态迁移。

必须补充：

- active filter 的视觉状态必须与 hover、focus、普通标签区分。
- 清除筛选 / 回到全部路径始终可见或可达。
- 删除 active tag 后回到全部，且不显示已删除标签残留。
- 合并 active source 后切到目标标签，且结果列表随目标标签刷新。
- 如果目标标签原本也在当前记录上，合并去重不应造成结果闪烁或重复展示。

建议技术方案可吸收口径：

> FilterBar 使用单选标签状态。`All` / `全部` 是未筛选状态，favorite first，普通标签按设置页排序。active filter 使用稳定选中样式，hover / keyboard focus 只作为临时状态，不覆盖 active。删除 active tag 后 selectedTagID 清空并回到全部；合并 active source 后 selectedTagID 切换为 targetTagID。

验收样例：

- 选择 `Work` 后，`Work` active 样式清楚，hover 其他标签不覆盖 active。
- 点击清除或 `全部` 后回到未筛选列表。
- 删除 active `Draft` 后不再显示 `Draft` chip 或失效筛选。
- 合并 active `Draft` 到 `Work` 后，`Work` 成为 active filter。

### 3.5 长标签名、颜色 token、排序控件和窄宽度布局需要补低敏验收门槛

技术方案把这些放在 UI/测试复审细化，但进入开发前至少要有保底验收。否则标签能力可能模型正确，但 Settings 和 panel 在真实内容下重叠。

必须补充：

- 长标签名的截断 / 换行规则，至少保证不覆盖操作列。
- 颜色 token 不能作为唯一识别方式；标签名必须可见。
- 排序控件形态需要在 Step 2 中选择最小方案：拖拽、上下按钮或菜单；不要留给实现随意决定。
- 窄宽度下操作入口可以折叠，但核心动作仍可达。
- favorite colorToken 固定，不进入普通色板。

建议技术方案可吸收口径：

> Step 2 首版排序控件建议采用上下移动按钮或操作菜单中的“上移 / 下移”，避免拖拽在窄宽度和 VoiceOver 下难以验收；若采用拖拽，必须同时提供键盘可用替代路径。长标签名默认单行截断，完整名称通过 tooltip / accessibility label 可读。颜色 swatch 只辅助识别，标签名始终显示。窄宽度下可把 rename / merge / delete 折叠进操作菜单，但新建、favorite 状态和 active filter 不应消失。

验收样例：

- 标签名 `Very long clipboard project tag 004 with suffix` 不覆盖操作菜单。
- 深浅模式下颜色 swatch 和标签名可辨识。
- 键盘或 VoiceOver 用户可完成普通标签排序。
- 窄宽度下仍能看到 favorite first、active filter、清除筛选和 tag row 操作入口。

### 3.6 旧 `preservePinned` / `clearUnpinned` 可见语义必须同步退出或改名

技术方案已指出 `preservePinned` / `clearUnpinned` 可能泄漏旧概念，并推荐改成 preserveFavorite。UI 侧认为这是必须收敛项：只要 active UI 或用户可见策略仍出现 pinned / unpinned / 固定语义，Step 2 的模型替换体验就不完整。

必须补充：

- 如果对应设置或动作仍在 active UI，可见文案必须改成 favorite 语义或隐藏。
- `clearUnpinned` 这类负向概念不能继续用在用户可见路径。
- 如果技术上暂不改 policy，必须确保 UI 不暴露旧 pinned 文案，并在开发记录列为 residual。

建议技术方案可吸收口径：

> Step 2 内所有 active UI 的 pinned / unpinned / pinboard / 固定独立模型文案必须退出。若保留“保护收藏项不被清理”，用户可见命名改为收藏语义，并基于 favorite RecordTag；若暂不实现 preserveFavorite，相关 UI 文案隐藏，不得继续显示旧 pinned 策略。

验收样例：

- Settings 不出现 `preserve pinned`、`clear unpinned`、`固定项`、`pinboard` 等 active 文案。
- 清理或保留策略如仍可见，使用收藏语义，且不读旧 pinned 状态。

## 4. 可优化

### 4.1 标签很多时的右键菜单搜索可以后续做

Step 2 只需要状态正确和排序一致。标签数量很多时的菜单搜索、分组或分页可以后续优化，不应阻塞本阶段。

### 4.2 合并前影响数量可以作为后续增强

如果 repository 很容易返回 affected record count，可以在合并 / 删除说明中展示数量；如果代价较高，Step 2 可先用文字说明影响范围，不强制精确数量。

### 4.3 色板细节可以由实现后截图微调

受控 colorToken 是必须的，但具体色值、数量和深浅模式微调可以在低敏截图验收中确定。只要颜色不是唯一信息，Step 2 不必阻塞在完整色板设计。

### 4.4 Settings row 更完整的批量管理后续再做

批量删除、批量合并、自动清理空标签都不是 Step 2 目标。设置页只需完成单标签管理闭环。

## 5. 可吸收建议

建议技术方案或开发任务吸收以下最小交互合同：

1. **Settings row 合同**：favorite row 固定第一，普通 row 固定结构，右侧操作区稳定；favorite 不可变更原因可读。
2. **Context menu 合同**：checked=已添加并点击移除，unchecked=未添加并点击添加，favorite first；新建失败贴近输入位置反馈。
3. **Destructive / merge 合同**：删除说明影响所有记录；合并说明 source、target 和结果；失败不半更新。
4. **Filter state 合同**：active、hover、focus 分层；delete active 清空；merge active source 切 target。
5. **Layout 合同**：长标签截断不遮挡操作，颜色不单独表达意义，排序控件有键盘可用路径。
6. **Legacy wording 合同**：active UI 中 pinned / unpinned / pinboard / fixed 独立模型文案退出。

可直接吸收的短文案建议：

- favorite immutable：`收藏是内置标签，不能修改`
- delete action：`删除标签并从所有记录移除`
- delete success：`已删除标签`
- delete failed：`标签未删除，请重试`
- merge explanation：`将 {源标签} 合并到 {目标标签}，相关记录将改为使用 {目标标签}`
- merge success：`已合并到 {目标标签}`
- duplicate tag：`标签名称已存在`
- reserved favorite name：`“收藏”是内置标签名称`
- empty tag：`标签名称不能为空`

这些文案只作为首版建议，最终应进入 String Catalog 并按现有语气统一。

## 6. 验收样例

### 6.1 Settings tag management

- favorite row 固定第一，显示五角星和内置状态。
- favorite row 不可执行删除、改名、改色、排序、合并。
- 没有普通标签时，仍显示 favorite row 和新建普通标签入口。
- 普通标签 row 显示颜色、名称、排序控件和操作入口。
- 长标签名和长错误文案不覆盖操作入口。
- VoiceOver 能读出标签名、收藏状态、排序位置和可用操作。

### 6.2 右键菜单

- favorite first，状态与条目五角星同步。
- 已添加标签 checked，点击移除当前记录关系。
- 未添加标签 unchecked，点击添加当前记录关系。
- 新建标签成功后立即添加到当前记录，并在 Settings / 条目展示中可见。
- 新建空名、重名或 reserved favorite name 失败时，当前记录标签关系不变，并显示错误。

### 6.3 删除和合并

- 删除 `Draft` 前，动作文案说明会从所有记录移除此标签。
- 删除 `Draft` 后，设置页、筛选项、右键菜单和条目展示都不再出现 `Draft`。
- 删除 active `Draft` 后，筛选回到全部。
- `Draft` 合并到 `Work` 后，源标签消失，目标标签保留名称、颜色和排序。
- 合并 active `Draft` 后，active filter 切换为 `Work`。
- 合并失败时，源 / 目标标签和所有 record-tag 关系保持原样。

### 6.4 单标签筛选和布局

- `全部` / 未筛选状态可达。
- active filter 与 hover / focus 有不同层级。
- favorite first，普通标签按 Settings 排序。
- 长标签名不遮挡搜索框、右侧操作或条目主要内容。
- 窄宽度下仍能清除筛选，并能访问标签管理动作。

### 6.5 旧概念退出

- active UI 不出现 pinboard / pinned / unpinned / fixed / 固定独立模型文案。
- 收藏按钮读写 favorite RecordTag，不读写旧 pinned 状态。
- 若保留清理策略，用户可见语义是 favorite，不是 pinned。

## 7. 对项目负责人的建议

建议结论：`approve-with-changes`。

没有发现需要否定技术路线的问题。进入开发准备前，建议要求 App 架构师或开发任务吸收以下必须改点：

1. 固定 Settings tag row 结构，并明确 favorite immutable 的禁用 / 隐藏原因表达。
2. 明确右键菜单已添加 / 未添加点击语义、favorite first 和新建失败反馈落点。
3. 补删除普通标签影响说明、合并普通标签结果说明和 active filter 迁移反馈。
4. 补长标签名、颜色 token、排序控件、窄宽度和可访问性验收。
5. 收敛 active UI 中 `preservePinned` / `clearUnpinned` 等旧语义退出或改名为 favorite。

这些修改不改变 Step 2 范围，也不要求提前做 Step 3 面板布局专项打磨；它们只是把 PRD v1 已经收敛的体验规则落成开发可执行的 UI 合同。
