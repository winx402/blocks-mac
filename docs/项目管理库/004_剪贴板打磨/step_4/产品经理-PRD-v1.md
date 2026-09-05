# Step 4 产品经理 PRD v1：详情编辑与元数据组织

状态：prd-revision-v1
修订日期：2026-07-07
起草角色：产品经理
所属项目：004_剪贴板打磨
所属阶段：Step 4
来源级别：基于 `产品经理-PRD-v0.md`、`UI-交互设计师-PRD复审-v0.md`、`App架构师-PRD复审-v0.md`、`开发-PRD复审-v0.md`、`测试-质量-PRD复审-v0.md`、`项目负责人-PRD复审收敛-v0.md` 修订。

## 1. 修订结论

Step 4 范围保持不变：只覆盖详情编辑与元数据组织，不进入 Step 5 / Step 6，不写技术方案，不做开发实现。

PRD v1 主要修订点：

- 将富文本格式保留与降级从“技术待确认”收敛为进入开发前必须闭合的产品合同。
- 将保存事务、索引失败和系统剪贴板不更新写成可验收的一致性与低敏证据口径。
- 将 OCR 用户编辑文本与 retry / late completion 的冲突策略写成默认规则。
- 将 URL record kind、合法性、标准化和 custom scheme 首版边界写清。
- 将 Repository / bounded read model / P13D 从建议升为进入开发前硬要求。
- 吸收 UI / 开发推荐：默认阅读态 + 显式 Edit、稳定 detail editor、固定底部 action bar、dirty-navigation 确认 sheet、状态反馈层级、元数据窄宽度降级、键盘和 VoiceOver 验收。

## 2. 阶段目标

Step 4 让剪贴板条目详情页成为可编辑、可阅读、布局稳定的信息面板。用户可以在详情中编辑 plain text、URL、富文本文本内容和图片 OCR 文本；保存后，详情正文、派生字段、摘要、搜索索引和更新时间在用户可见层面保持一致；系统剪贴板不被更新。

## 3. 阶段边界

### 3.1 已接受依赖

- Step 1 已接受：明文展示、搜索底座、系统 Vision OCR、设置页清理和输出边界是当前事实源。
- Step 2 已接受：标签 / 收藏模型是当前事实源。
- Step 3 已接受：面板交互与布局打磨是当前事实源；但 Step 3 的真实 UI / 真实剪贴板 / 真实 VoiceOver / 真实单击双击 P2 residual 不得写成 Step 4 已实测事实。

### 3.2 不覆盖

本阶段不覆盖：

- 图片本体编辑、裁剪、标注、重编码或替换。
- 文件本体编辑、移动、重命名、打开 Finder、同步外部文件或改写真实文件路径。
- 其他非文本类 payload 本体编辑。
- 完整富文本编辑器扩展，例如字体、字号、颜色、表格、图片内嵌、复杂 HTML / RTF 工具栏。
- 系统剪贴板同步写回。
- Step 5 隐私页真实 App 清单、系统 App 图标、CLI 广义对象管理。
- Step 6 集成验收与真实 UI / VoiceOver / 系统环境回扫。
- Step 3 面板 hover、toolbar、单击 / 双击控件和列表密度继续重设计。

## 4. 需求覆盖矩阵对齐

| 矩阵 ID | PRD v1 覆盖口径 |
| --- | --- |
| R12 | 详情内容可编辑；编辑区默认 2 行、最多 4 行、超过内部滚动；详情字体不受列表字体设置影响。 |
| R13 | 元数据短项两列、长项单行，窄宽度降级为单列，长内容不挤压正文编辑区。 |
| C2 | 保存后更新搜索索引中的正文、URL、富文本纯文本、图片 OCR 文本等字段；不重写 Step 1 搜索算法。 |
| C9 | 保存后更新内部 payload 或派生字段、摘要、搜索索引和更新时间；系统剪贴板不更新。 |
| C14 | plain text、URL、富文本文本内容、图片 OCR 文本进入编辑边界；富文本必须满足格式保留合同或有项目负责人降级接受记录。 |
| C15 | 显式保存 + 取消；固定底部 action bar 稳定承载 dirty / saving / failed / read-only 状态。 |
| C16 | 保存事务、read model、OCR override 和索引一致性按可扩展模型约束，不允许 View 层临时拼接写入。 |
| C17 | 默认阅读态、显式 Edit、状态反馈、键盘 / VoiceOver、低敏 fixture 和 P13D 作为体验验收输入。 |

## 5. 首版交互口径

### 5.1 默认阅读态 + 显式 Edit

首版默认采用阅读态：

- 打开详情时优先进入 `view` / `read-only` 阅读态，不默认直接编辑。
- 可编辑类型在固定底部 action bar 中显示 `Edit`。
- 点击 `Edit` 后进入 `edit-clean`；编辑区变为可输入状态。
- 点击 `Edit` 后焦点可以进入编辑区或停留在明确位置，具体由 UI / 技术方案确认；不得在打开详情时自动抢焦点导致误 dirty。
- 不可编辑类型在同一操作区显示只读原因或相关动作，例如 OCR retry。

直接可编辑文本区不作为 Step 4 首版默认方案。若技术方案主张直接编辑，必须证明不会造成误 dirty、焦点抢占和状态解释成本，并回到项目负责人确认。

### 5.2 稳定 detail editor

Step 4 的 dirty state、保存中、失败回滚和 dirty-navigation 必须承载在稳定的 detail editor / sheet / pane 中。

- hover preview 不默认承载编辑状态。
- hover detail 可以保持只读，或提供进入稳定 detail editor 的显式入口。
- 如果后续技术方案决定在 hover detail 中编辑，必须额外定义 hover leave、re-enter、close、panel 切换时的 dirty-navigation 行为，并通过项目负责人确认。

### 5.3 固定底部 action bar

详情页保留固定底部 action bar。所有编辑状态共用同一高度和位置：

| 状态 | action bar 内容 |
| --- | --- |
| view / read-only | `Edit`，或只读原因 / OCR retry 等相关动作。 |
| edit-clean | `Cancel` + disabled `Save`，可显示 `No changes` 或弱状态。 |
| dirty | `Cancel` + enabled `Save` + `Unsaved changes`。 |
| invalid | 字段级错误靠近字段；action bar 中 `Save` disabled 或显示不可保存状态。 |
| saving | `Save` 进入 loading，防重复提交；状态文案固定在 action bar。 |
| save-failed | 同一 action bar 显示失败文案、`Retry Save` / `Save` 和 `Cancel`。 |
| save-success | 可短暂显示 `Saved`，不抢焦点，不改变布局。 |

按钮启用、loading、错误文案变化不得导致正文编辑区、元数据区或详情页整体跳动。

### 5.4 状态反馈层级

状态反馈分三层：

- 字段级错误靠近字段，例如 invalid URL。
- 编辑事务状态固定在 action bar，例如 dirty、saving、saved、save failed。
- 全局 toast / banner 只能作为补充，不能作为失败、dirty、read-only 或 invalid 的唯一反馈。

### 5.5 Dirty Navigation

dirty 状态下，切换条目、关闭详情、关闭面板或执行会离开当前编辑上下文的动作时，使用阻断式确认 sheet。

动作固定为：

- `Save and Continue`：进入 saving，保存成功后执行原动作；保存失败则留在当前记录并显示失败。
- `Discard Changes`：放弃草稿并继续原动作。
- `Continue Editing`：关闭确认 sheet，留在当前记录。

默认焦点应放在 `Continue Editing` 或等价最安全动作。不得用 toast、状态条、隐式自动保存或静默丢弃替代 dirty-navigation sheet。

保存中禁止重复保存和并发切换。记录缺失、payload 缺失、保存冲突或记录被裁剪时，进入低敏错误状态，草稿保留，不静默丢弃。

## 6. 可编辑类型与硬边界

| 类型 | 首版状态 | 编辑对象 | 保存后更新 | 硬边界 |
| --- | --- | --- | --- | --- |
| plain text | 可编辑 | 文本正文。 | 文本 payload、派生纯文本、摘要、搜索索引、更新时间。 | 不更新系统剪贴板；不改 createdAt、source App、标签。 |
| URL | 可编辑 | URL 字符串。 | `urlString`、派生纯文本、URL tokens、summary、search document、更新时间。 | 保持 URL kind；不发网络请求；非法 URL 不提交 mutation。 |
| 富文本文本内容 | 架构门禁通过后可编辑 | 富文本中的文本内容。 | 保持 `rich_text` kind 和可见格式；更新富文本 payload、派生纯文本、摘要、搜索索引、更新时间。 | 不静默降级 plain text；无法保真则需项目负责人接受降级、暂缓或只读。 |
| 图片 OCR 文本 | 仅 OCR succeeded 且已有文本时可编辑 | OCR 派生文本。 | OCR 文本、摘要、搜索索引、详情展示、更新时间。 | 不改图片 payload；user-edited 文本不被 retry / late completion 静默覆盖。 |
| 图片本体 | 不可编辑 | 不适用。 | 不适用。 | 不编辑图片像素、尺寸、格式或 payload。 |
| file URL / 文件本体 | 不可编辑 | 不适用。 | 不适用。 | 不编辑外部文件，不移动、不重命名、不改真实路径。 |
| 其他非文本类 payload | 不可编辑 | 不适用。 | 不适用。 | 只展示元数据或只读内容，不提供本体编辑入口。 |

## 7. 富文本格式保留与降级

富文本编辑的首选语义：

- 保存后 record kind 仍为 `rich_text`。
- 用户可见格式不被静默降级。
- 编辑后的富文本 payload 与派生纯文本、摘要、搜索索引保持一致。
- 未编辑区段的格式属性应保留；被编辑区段的格式保留或降级规则必须可解释、可验收。

最低格式保留验证范围：

- 链接。
- 段落 / 换行。
- 基础 inline style，例如粗体、斜体、强调。
- 列表或等价结构中的代表项。

进入开发前硬要求：

- 技术方案必须说明以上代表项哪些可保留、哪些不可保留。
- 如果无法可靠保留富文本格式，富文本编辑不得作为普通可编辑类型直接进入开发。
- 降级选项只能是项目负责人明确接受后的产品取舍，例如暂缓富文本编辑、只读 + 可复制纯文本、或只编辑派生纯文本。
- 不允许实现中隐式把富文本 payload 转成 plain text payload。

P13D 或等价门禁必须证明“富文本未静默丢格式”，或证明存在当前项目负责人接受的降级 / 暂缓 / 只读记录。

## 8. URL 编辑规则

URL 编辑只编辑 URL record 的 URL 字符串，不改变 record kind。

首版规则：

- 保存后仍保持 URL kind；Step 4 不支持 URL record 转 text record。
- 校验只做本地解析，不发网络请求，不验证远端可达性。
- 首版只接受 absolute URL，并保留 scheme。
- 不自动补 `https://`。
- `file:` URL 不作为 URL 文本编辑的普通成功路径；file URL 仍按文件本体不可编辑边界处理。
- 首版默认成功路径为 `http`、`https`、`mailto`。
- custom scheme 不作为默认成功路径；如技术方案要支持特定 custom scheme，必须给出 allowlist / denylist 和低敏 fixture，并由项目负责人接受。
- 非法 URL 优先 inline validation 并阻止保存；如实现选择保存后校验失败，也必须停留 dirty 状态并保留草稿。

保存成功时，`urlString`、派生纯文本、URL tokens、summary、search document 和详情 read model 必须同源。

URL 编辑不得触发远端访问、App launch、Finder 打开或系统权限请求。

## 9. OCR 文本编辑与 retry 冲突

首版状态规则：

| OCR 状态 | 编辑规则 |
| --- | --- |
| pending | 不提供普通文本编辑入口；展示等待状态。 |
| running | 不提供普通文本编辑入口；展示处理中状态。 |
| failed | 不提供普通文本编辑入口；只展示失败和 retry 状态。 |
| succeeded with text | 允许编辑 OCR 文本。 |
| succeeded empty | 首版为只读空态，显示 `No text recognized` 或等价文案；不允许手动新增 OCR 文本。 |

用户保存编辑后的 OCR 文本后，该文本成为 `user-edited` / `override` / `locked source` 等价语义。

冲突规则：

- OCR retry 或 late completion 不得静默覆盖 user-edited OCR 文本。
- 如果用户主动发起 retry，且该记录已有 user-edited OCR 文本，必须先确认覆盖，或展示候选结果路径。
- 如果首版没有候选对比 UI，则对 user-edited OCR 文本禁用 retry，或要求用户先明确撤销 / 确认覆盖。
- late completion 到达时，如果当前记录已有 user-edited OCR 文本，保留用户编辑文本，并把 OCR 新结果作为被忽略 / 可恢复的低敏状态处理；不得直接替换。
- 保存 OCR 文本只更新 OCR 文本、摘要、搜索索引、详情展示和更新时间，不改图片 payload。

P13D 必须覆盖 `detail_ocr_user_edited_retry_004`，证明 user-edited OCR 后 retry / late completion 不静默覆盖。

## 10. 保存事务与索引一致性合同

Step 4 保存是用户级单一 mutation。

### 10.1 成功语义

保存成功后，同一记录的以下对象必须进入同一版本语义：

- 详情正文或对应可编辑字段。
- payload 或对应派生字段。
- 当前详情 bounded read model。
- 面板摘要 / preview summary。
- search document。
- FTS / 搜索投影。
- 更新时间。

保存成功后：

- 搜索新 token 可命中当前记录。
- 旧 token 不继续作为当前记录的命中依据，除非技术方案明确定义旧 token 的历史索引策略并经项目负责人接受。
- `createdAt` / capture time、source App、标签、收藏状态保持不变。
- 系统剪贴板不更新。

### 10.2 首选事务口径

首选口径：payload、record summary、search document、FTS、updatedAt 在同一 repository transaction 内提交。

技术方案如果选择其他模型，必须保证用户可见一致性不弱于首选口径。

### 10.3 异步 reindex 例外

如技术方案必须采用异步 reindex，PRD v1 要求引入可见状态：

- `saved-index-pending`：内容已保存，但搜索索引待更新。
- `reindex-failed`：内容已保存，但索引更新失败，需要可恢复机制。

异步 reindex 下：

- 保存成功反馈不得宣称搜索已经更新，除非索引已完成。
- 用户必须能看到索引待更新或失败的可理解状态。
- 需要有重试、后台恢复或重新构建索引的产品 / 技术路径。
- 验收必须覆盖 pending 和 failed，不允许把索引失败静默吞掉。

### 10.4 失败语义

保存失败时：

- 草稿保留在编辑区。
- 已保存事实源不得出现用户可见的部分提交。
- payload、summary、search document、FTS、updatedAt 应保持最近一次一致状态，或进入明确的 `saved-index-pending` / `reindex-failed` 状态。
- 保存失败反馈固定在 action bar 或字段附近，不遮挡主要内容。
- 用户可以重试保存、取消回到已保存内容或继续编辑。

如果记录在保存期间被删除、裁剪、外部刷新或 payload 不可用，进入 `record-unavailable` / `save-failed` 等低敏错误状态，草稿不写入其他记录。

## 11. 系统剪贴板不更新的证据口径

Step 4 保存动作不得调用系统 pasteboard 写入路径。

验收只能使用低敏证据：

- fake pasteboard。
- adapter spy。
- static call-site scan。
- 等价低敏 instrumentation。

不得读取真实系统剪贴板内容，不得写真实系统剪贴板。

P13D 或等价门禁必须输出 `pasteboard_write_attempts=0` 或等价字段，并覆盖四类保存：

- plain text。
- URL。
- 富文本文本内容。
- 图片 OCR 文本。

证据不得包含真实剪贴板正文、真实 home path、真实文件路径、邮箱、secret、Authorization header、二维码、验证码、图片/base64 或真实 OCR 原文。

## 12. Repository / Read Model / Purpose 边界

进入开发前硬要求：

- Step 4 技术方案必须提供 bounded detail read model。
- 详情默认展示和元数据布局基于 bounded detail read model，不为布局一次性读取不必要的大 payload。
- metadata 默认展示 bounded metadata snapshot。
- 完整正文、完整 URL、完整 file path、OCR 原文、rich text body 的展开、复制或编辑必须是显式用户动作。
- 完整 payload read、edit draft、save mutation 必须通过明确 purpose，例如 `detailEditRead`、`detailEditSave` 或等价命名。
- 不得复用 hover、paste、copy、translation、provider 等 purpose 承载详情编辑读写。
- 编辑保存必须通过单一 Store / Repository command 或等价窄 API。
- View 不直接分散写 payload、summary、search document、FTS 或 OCR 状态。
- AppState / Store 可以做 facade 和协调，但不得成为编辑后 payload / OCR / search document 的事实源。

## 13. 编辑状态矩阵

| 状态 | 进入条件 | 用户可见行为 | 可用操作 | 退出条件 |
| --- | --- | --- | --- | --- |
| view | 打开可编辑记录详情。 | 内容只读，action bar 显示 Edit。 | Edit、复制 / 展开元数据、关闭。 | 点击 Edit 进入 edit-clean。 |
| read-only | 记录不可编辑，或 OCR pending / running / failed / succeeded empty。 | 显示只读原因；如 OCR failed 则显示 retry。 | 查看、复制 / 展开元数据、retry。 | 切换记录，或 OCR 状态满足可编辑条件。 |
| edit-clean | 点击 Edit 后，草稿等于已保存内容。 | 编辑区可输入；Save disabled；Cancel 可用。 | 输入、取消、关闭 / 切换。 | 修改内容进入 dirty。 |
| dirty | 草稿与已保存内容不同。 | action bar 显示 Unsaved changes；Save enabled。 | Save、Cancel、继续编辑、dirty-navigation。 | 保存、取消、放弃。 |
| invalid | URL 或字段校验失败。 | 字段级错误靠近字段；Save disabled 或保存失败后停留 dirty。 | 修改字段、取消。 | 字段有效后回 dirty / edit-clean。 |
| saving | 点击 Save。 | Save loading，防重复提交；不允许并发切换。 | 等待保存结果。 | save-success、saved-index-pending、reindex-failed、save-failed。 |
| save-success | 保存和索引均完成。 | 显示 Saved；dirty 清除；更新时间更新。 | 继续编辑、关闭、切换。 | 回到 view 或 edit-clean，由 UI 方案确认。 |
| saved-index-pending | 内容已保存，索引待更新。 | 显示索引待更新状态，不宣称搜索已更新。 | 查看、继续编辑；重试路径由技术方案定义。 | 索引完成或失败。 |
| reindex-failed | 内容已保存，索引更新失败。 | 显示可恢复失败状态。 | 重试 reindex、继续查看；具体动作由技术方案定义。 | reindex 成功或记录进入可恢复失败。 |
| save-failed | 保存 mutation 失败。 | 草稿保留；失败反馈固定显示；事实源不部分提交。 | Retry Save、Cancel、继续编辑。 | 重试成功、取消、继续编辑。 |
| record-unavailable | 保存或编辑中记录被删除 / 裁剪 / payload 不可用。 | 低敏错误说明；草稿不写入其他记录。 | 关闭、复制草稿文本如安全可行、返回列表。 | 关闭或切换。 |
| cancel | 用户取消。 | 草稿恢复到最近一次已保存内容；dirty 清除。 | 继续查看、Edit、关闭。 | 回 view / edit-clean。 |
| dirty-navigation | dirty 状态下离开。 | 确认 sheet：Save and Continue / Discard Changes / Continue Editing。 | 三选一。 | 按选择执行。 |

## 14. 编辑区布局

必须满足：

- 编辑区最小可见高度为 2 行。
- 编辑区最大可见高度为 4 行。
- “行”按详情编辑字体和 line height 计算，不随列表字体设置变化。
- read-only、edit-clean、dirty、invalid、saving、save-failed 状态下编辑区外框高度稳定。
- 错误文案和 action bar 不把编辑区挤到低于 2 行。
- 超过 4 行时编辑区内部滚动，详情页整体滚动仍可用。
- URL、长英文单词、中文长句、日文长句需要明确换行、截断或横向滚动策略。

## 15. 元数据组织

### 15.1 布局规则

- 常规宽度：短项两列，长项单行。
- 窄宽度：全部元数据降级为单列，避免两列互相挤压。
- 正文编辑区优先级高于元数据区。
- 元数据区不得挤压编辑区高度。
- metadata 默认使用 bounded metadata snapshot。

### 15.2 完整值路径

长项至少提供 `copy full value` 或等价完整值路径：

- tooltip 可以作为桌面补充，但不能是唯一完整语义路径。
- 视觉截断时，VoiceOver label 保留完整语义，或明确说明可复制完整值。
- file URL 和真实路径相关证据必须低敏化，不把真实 home path 写进截图、JSON、日志或 verifier 输出。
- 完整 URL、完整 file path、OCR 原文和 rich text body 的展开 / 复制是显式用户动作，并使用明确 purpose 与 sanitizer 边界。

### 15.3 元数据分类

| 元数据类别 | 默认布局 | 示例 |
| --- | --- | --- |
| 短项 | 常规宽度两列，窄宽度单列 | 类型、创建时间、更新时间、大小 / 字符数、OCR 状态、标签数量。 |
| 条件短项 | 两列；过长时降级长项 | 来源 App、来源窗口、bundle id 摘要。 |
| 长项 | 单行；窄宽度单列 | URL、file URL 摘要、长文件名、长来源 App、长标签列表、错误详情。 |
| 标签 / 收藏 | 单行或可换行区域 | 收藏、普通标签、多标签列表。 |

## 16. 保存后数据更新矩阵

| 更新对象 | plain text | URL | 富文本文本内容 | 图片 OCR 文本 |
| --- | --- | --- | --- | --- |
| payload / 内容字段 | 更新文本 payload。 | 更新 `urlString` 或等价 URL 字段。 | 架构门禁通过后更新富文本 payload；否则按项目负责人接受的降级方案处理。 | 不更新图片 payload。 |
| 派生纯文本 | 更新。 | 更新 URL 对应纯文本。 | 更新富文本纯文本化内容。 | 更新 OCR 派生文本。 |
| summary / preview | 更新有界摘要。 | 更新 URL 有界摘要。 | 更新富文本纯文本摘要。 | 更新 OCR 文本摘要或 OCR 区域展示。 |
| search document / FTS | 更新正文字段。 | 更新 URL tokens / 正文字段。 | 更新富文本纯文本字段。 | 更新图片 OCR 字段。 |
| 当前 detail read model | 更新。 | 更新。 | 更新或按降级方案更新。 | 更新。 |
| updatedAt / 内容更新时间 | 更新。 | 更新。 | 更新。 | 更新记录更新时间或 OCR 文本更新时间，字段名由技术方案确认。 |
| createdAt / capture time | 保留。 | 保留。 | 保留。 | 保留。 |
| source App | 保留。 | 保留。 | 保留。 | 保留。 |
| 标签 / 收藏 | 保留。 | 保留。 | 保留。 | 保留。 |
| 系统剪贴板 | 不更新。 | 不更新。 | 不更新。 | 不更新。 |

## 17. 低敏 fixture 与验收矩阵

验收证据必须使用 synthetic / fixture 内容，不复制真实用户剪贴板正文，不包含真实 home path、邮箱、secret、Authorization header、二维码、验证码、真实文件路径、图片/base64 或真实 OCR 原文。

保留 v0 fixture：

| fixtureID | 类型 | 用途 |
| --- | --- | --- |
| `detail_text_alpha_004` | plain text | view -> Edit -> dirty -> save success；摘要、搜索、更新时间更新。 |
| `detail_text_long_004` | plain text | 2 行默认、4 行上限、内部滚动。 |
| `detail_url_valid_004` | URL | absolute URL 编辑、summary 和 search document 更新。 |
| `detail_url_invalid_004` | URL | inline validation、Save disabled 或保存失败后保留草稿。 |
| `detail_rtf_format_004` | rich text | 链接、段落 / 换行、inline style、列表代表项的格式保留。 |
| `detail_image_ocr_done_004` | image OCR | OCR 文本编辑和索引更新，示例 token `VISION-004`。 |
| `detail_image_ocr_pending_004` | image OCR | pending 不可编辑。 |
| `detail_image_ocr_failed_004` | image OCR | failed / retry 状态与不可编辑边界。 |
| `detail_file_readonly_004` | file URL | 文件本体不可编辑，仅展示 bounded 元数据。 |
| `detail_metadata_long_004` | metadata | 长 URL、长文件名、长来源 App、长标签、多语言长句。 |
| `detail_save_failure_004` | save failure | 保存失败、草稿保留、回滚和重试。 |

新增 / 调整 fixture：

| fixtureID | 用途 |
| --- | --- |
| `detail_save_atomic_failure_004` | 模拟 search document 或 FTS 写入失败，断言 payload / summary / updatedAt 不部分提交，或进入已定义 pending / failed 状态。 |
| `detail_record_missing_during_save_004` | 编辑期间记录被删除或裁剪，断言进入 record unavailable / save failed，draft 不写入其他记录。 |
| `detail_ocr_user_edited_retry_004` | 用户编辑 OCR 文本后 retry / late completion 不静默覆盖。 |
| `detail_rich_text_degrade_blocked_004` | 富文本无法保真时必须有项目负责人降级接受记录，否则 fail。 |
| `detail_url_custom_scheme_004` | custom scheme 默认不作为成功路径；如支持特定 scheme，需要 allowlist / denylist 和项目负责人接受记录。 |
| `detail_pasteboard_spy_004` | 四类保存后系统剪贴板写入次数为 0。 |
| `detail_dirty_navigation_004` | dirty 下切换记录 / 关闭详情触发三动作确认 sheet。 |
| `detail_a11y_004` | 键盘和 VoiceOver 覆盖 Edit、编辑区、Save、Cancel、错误反馈、dirty-navigation、metadata copy、OCR 状态。 |

最低验收矩阵：

- 可编辑类型：plain text、URL、富文本、图片 OCR 文本。
- 不可编辑类型：图片本体、文件本体、其他非文本类 payload。
- 状态：view、read-only、edit-clean、dirty、invalid、saving、save-success、saved-index-pending、reindex-failed、save-failed、record-unavailable、cancel、dirty-navigation。
- 数据：payload / 派生字段 / summary / search document / FTS / updatedAt / detail read model / 系统剪贴板不更新。
- 布局：默认宽度、窄宽度、长内容、多语言、2 行 / 4 行编辑区、固定 action bar、元数据长项。
- 可访问性：Edit、编辑区、Save、Cancel、错误反馈、dirty-navigation sheet、metadata copy、OCR 状态均可键盘访问或可读。

## 18. P13D 硬门禁

Step 4 技术方案必须提供 P13D 或等价 fail-closed verifier。P13D 是进入开发前硬要求，不再是建议。

P13D 最低断言：

1. 当前事实源引用 Step 4 PRD v1、技术方案和开发记录；旧 story / archive 只能作为 baseline reference。
2. 可编辑 / 不可编辑类型 fixture 完整。
3. 默认 metadata / detail snapshot 不读取不必要完整 payload。
4. 完整 payload read、edit draft、save mutation 使用明确 purpose，不复用 hover / paste / copy / translation / provider purpose。
5. 详情编辑保存路径可追踪到单一 Store / Repository command 或等价窄 API。
6. View 不直接分散写 payload、summary、search document、FTS 或 OCR 状态。
7. plain text 保存后 payload、summary、search document、FTS、updatedAt、detail read model 一致。
8. URL valid save 不访问网络、不改 kind；invalid URL 不产生 mutation。
9. rich text 不静默丢格式；若降级为只读、暂缓或派生纯文本编辑，必须有当前项目负责人接受记录。
10. image OCR text edit 不修改图片 payload，不输出 OCR 原文，不被 retry / late completion 静默覆盖。
11. 保存失败保留草稿，不产生用户可见部分提交。
12. cancel / dirty-navigation discard 不提交 mutation。
13. 系统剪贴板未被保存动作更新；输出 `pasteboard_write_attempts=0` 或等价字段。
14. 编辑区默认 2 行、最多 4 行、超过内部滚动，不被列表字号设置影响。
15. 元数据短项两列、长项单行，窄宽度单列，长值不挤压编辑器。
16. 低敏输出扫描通过，不含真实剪贴板、真实 home path、真实文件路径、OCR 原文、URL 全文、图片/base64、邮箱、secret、Authorization header、二维码或验证码。

P13D 可由静态检查、fixture repository smoke、fake pasteboard / adapter spy、bounded JSON evidence、低敏截图 / snapshot 组合完成。仅输出“已检查”不能作为通过证据。

## 19. 键盘与 VoiceOver 验收

键盘路径必须覆盖：

- 打开详情后焦点不自动跳入编辑区导致误 dirty。
- `Edit` 可聚焦并触发。
- 编辑区可输入和滚动。
- Save / Cancel / Retry Save 可聚焦。
- dirty-navigation sheet 三个动作可键盘选择。
- metadata copy / expand 可聚焦。
- OCR retry 或 OCR 状态控件可聚焦。

VoiceOver 必须能读出：

- 当前记录是否只读、可编辑、dirty、saving、save failed。
- invalid URL 字段级错误。
- Save / Cancel / Retry Save 当前可用状态。
- dirty-navigation sheet 的三个动作和危险动作含义。
- 元数据标签和值；视觉截断时有完整语义或 copy full value 说明。
- OCR pending / running / failed / succeeded empty / user-edited 状态。

颜色、图标、toast 或 hover 状态不能成为唯一信息来源。

## 20. 技术方案必须回答的问题

以下不是 PRD 自行指定实现，但必须在技术方案中闭合，否则不得进入开发：

1. 富文本 payload 当前格式，以及链接、段落 / 换行、inline style、列表代表项的保留能力。
2. 富文本无法保真时采用降级、暂缓还是只读，并提供项目负责人接受记录。
3. 单一 detail edit save command 的 Store / Repository 边界。
4. payload、summary、search document、FTS、updatedAt、detail read model 的事务或异步 reindex 方案。
5. `saved-index-pending` / `reindex-failed` 的触发、恢复和验收方式。
6. 系统 pasteboard 写入路径如何通过 fake pasteboard / spy / static scan 证明未调用。
7. URL 校验和标准化规则，包括 absolute URL、scheme 保留、custom scheme 默认阻断或 allowlist。
8. OCR user-edited / override / locked source 标记位置，以及 retry / late completion 冲突处理。
9. bounded detail read model 与 metadata snapshot 包含哪些字段，哪些完整值必须显式读取。
10. detail edit read / save purpose 命名和与 hover / paste / copy / translation purpose 的隔离。
11. record missing、payload missing、save conflict、外部更新同一记录时的用户可见错误状态。
12. P13D 的具体脚本 / verifier 组合和 bounded JSON evidence 字段。

## 21. 角色复审关注点

### UI / 交互设计师

- 默认阅读态 + Edit 是否清楚。
- 固定底部 action bar 在各状态下是否稳定。
- dirty-navigation sheet 文案和默认焦点是否安全。
- 状态反馈层级、invalid URL、save failed、OCR 状态是否清楚。
- 元数据窄宽度单列降级和 copy full value 路径是否易用。

### App 架构师

- 富文本格式保留、降级 gate 和 P13D 证据是否足够硬。
- 单一 mutation、transaction / async reindex、bounded read model、purpose 隔离是否可落地。
- OCR user-edited 与 retry / late completion 冲突是否能在模型中表达。
- URL kind、validation、normalization 和 custom scheme 边界是否一致。

### 开发

- stable detail editor 承载 dirty state 的落点。
- 保存中禁止并发操作、record unavailable、save conflict 的状态流。
- View 不分散写 repository 字段的实现边界。
- P13D fixture 与 fake pasteboard / adapter spy 可行性。

### 测试 / 质量

- P13D 是否覆盖六个 P1。
- 保存事务、索引失败、系统剪贴板不更新、rich text 降级、OCR retry 和 URL invalid 的 pass/fail 是否可复跑。
- 低敏证据是否避免真实剪贴板、真实路径、URL 全文、OCR 原文和 secret。
- 键盘 / VoiceOver / 多语言 / 窄宽度是否形成可执行矩阵。
