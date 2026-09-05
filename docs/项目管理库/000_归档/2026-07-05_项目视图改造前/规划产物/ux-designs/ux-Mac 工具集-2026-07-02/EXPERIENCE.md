---
name: 奇点 AI 工具箱 V1
status: final
sources:
  - {planning_artifacts}/prds/prd-Mac 工具集-2026-07-02/prd.md
  - {planning_artifacts}/prds/prd-Mac 工具集-2026-07-02/addendum.md
  - ../../../../../产品知识库/交互整合/V1交互规格草案.md
  - ../../../../../技术知识库/正式AppScaffold架构-v0.md
updated: 2026-07-02
---

# 奇点 AI 工具箱 V1 — Experience Spine

本文定义 V1 的信息架构、行为、状态、交互和可访问性基线。视觉 token 与组件外观以 [DESIGN.md](DESIGN.md) 为准；mock 只做低保真参考。实现、mock、旧草案与本文冲突时，以 `DESIGN.md` 和本文为准。

## Foundation

V1 是 macOS 原生桌面工具箱，工程约束继承 P2-L：`SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`。主 App 负责菜单栏、浮层、设置页、权限引导、确认卡片、Keychain 和审计展示；helper 优先承载剪贴板 recorder；`jdtool` CLI 是 agent 的结构化入口。

UI 系统以 macOS 原生控件和 Apple 桌面交互习惯为基础。`DESIGN.md` 是视觉身份参考：浮层使用 `{components.floating-panel}`，设置页使用 `{components.sidebar}`，风险确认使用 `{components.confirmation-card}` 或 `{components.danger-card}`。

V1 UX 的核心约束：

- AI 不作为独立聊天入口，只嵌入截图、剪贴板、翻译和确认流程。
- 剪贴板对非排除 App 默认本地可恢复保存；这只发生在本机 App 数据内，不代表云同步、普通日志记录或 agent 默认可读完整内容。Agent 默认只能获得摘要。
- Provider 默认 BYOK / 本地 CLI；不设计内置云额度、账号、订阅、license server 或真实支付。
- 翻译快捷键默认未设置，在设置页引导用户录入。
- Hook 只做草稿、预览、启用确认和审计，不设计静默自动化。
- App UI 首批支持 `zh-Hans`、`en`、`ja`，默认跟随 macOS 系统语言；CLI/action JSON 的字段名、action 名称、`error.code` 保持机器稳定，不随 UI 语言本地化。
- 视觉材质采用渐进增强：macOS 26+ 使用系统 Liquid Glass；macOS 14-25 使用原生 material / `NSVisualEffectView` 回退；截图选区 overlay 不使用重毛玻璃。

## Information Architecture

| Surface | Reached from | Purpose | PRD coverage |
| --- | --- | --- | --- |
| Menu Bar | 菜单栏图标、登录项状态 | 工具入口、暂停剪贴板记录、最近状态、设置入口 | FR-1、FR-3、FR-10 |
| Screenshot Selection | 截图快捷键 `Option + A` 或用户自定义 | 区域、窗口、全屏截图；权限缺失时引导 | FR-2、FR-5 |
| Screenshot Result Overlay | 截图完成后 | 图片预览、复制/保存/拖拽、OCR/翻译/总结、审计摘要 | FR-6、FR-7、FR-8、FR-9 |
| Clipboard History Panel | 剪贴板快捷键 `Option + V` 或菜单栏 | 搜索、恢复、固定、分组、详情、单条 AI 处理 | FR-10 到 FR-15 |
| Translation Panel | 划词、手动输入、剪贴板、截图 OCR、agent action | 原文/译文对照、provider 状态、复制/替换/重试 | FR-16 到 FR-20 |
| Confirmation Card | 嵌入当前工具面板 | `preview`、`external_transfer`、`destructive_or_hook` 确认 | FR-22、FR-23、FR-29 |
| Settings | 菜单栏、权限提示、主窗口入口 | 快捷键、语言、权限、剪贴板、隐私排除、provider、CLI/agent、hook、数据管理 | FR-2、FR-3、FR-4、FR-21、FR-28、FR-30 |
| Audit View | 设置页 Data / Audit 分区 | 查看和清理 action、provider、确认级别和 redacted preview | FR-24、FR-27 |

→ Composition reference: [mockups/v1-low-fi.html](mockups/v1-low-fi.html). Spine wins on conflict.

## Voice and Tone

微文案直接、具体、可恢复。品牌气质由 `DESIGN.md` 定义；这里规定行为文案。

| Do | Don't |
| --- | --- |
| “需要屏幕录制权限才能选择截图区域。” | “权限异常。” |
| “将发送 428 个字符到 Codex CLI。” | “继续 AI 处理？” |
| “已暂停记录。历史仍可搜索。” | “剪贴板已关闭。” |
| “只返回摘要；完整内容需要你确认。” | “Agent 无权访问。” |
| “Hook 仍是草稿，启用前不会运行。” | “自动化已准备就绪。” |

失败文案必须包含原因、当前数据是否保留、下一步动作。不要使用庆祝语、营销语、emoji 或拟人化 AI 语气。

## Component Patterns

| Component | Use | Behavioral rules |
| --- | --- | --- |
| Floating Panel | 截图结果、剪贴板历史、翻译结果 | `Esc` 关闭；关闭不丢失最近摘要；主行动唯一；风险操作嵌入确认卡片。 |
| Glass Panel | 截图结果、确认卡片、设置页重点面板 | macOS 26+ 使用系统 Liquid Glass；旧系统使用原生 material 回退；不用于截图选区 overlay。 |
| Tool Button | 复制、保存、OCR、翻译、总结、固定、分组 | 图标优先，文本用于风险或低频动作；禁用态必须解释原因。 |
| Search Field | 剪贴板历史、设置页筛选 | 打开面板自动聚焦；`Esc` 先清搜索，再关闭面板。 |
| Segmented Control | 截图模式、provider 类型、语言方向 | 切换只改变当前上下文，不重置其他设置。 |
| Confirmation Card | 外发、完整内容预览、hook 生效 | 展示 level、reason、redacted preview、继续/取消；默认焦点在取消或关闭。 |
| Permission Row | 设置页 Permissions | 显示状态、原因、数据范围、打开系统设置、撤销说明。 |
| Clipboard Item Row | 剪贴板历史 | 展示类型、时间、来源候选、摘要；选中后详情区可恢复或处理。 |
| Translation Result Pair | 翻译面板 | 原文和译文并列或上下排列；保留来源、provider、耗时/错误和重试。 |
| Audit Row | 审计列表 | 展示 audit_id、action、时间、provider、确认级别、redacted preview；不展示完整敏感内容。 |

## State Patterns

| State | Surface | Treatment |
| --- | --- | --- |
| Default ready | 四工具入口 | 菜单栏可展开；快捷键可触发；状态 badge 使用 `{components.info-badge}`。 |
| Empty | 剪贴板、截图历史、翻译历史、审计 | 说明没有记录，提供开启 recorder、执行截图或返回设置的单一下一步。 |
| Permission missing | 截图、选中文本、登录项、文件访问 | 不进入半成品流程；展示原因、处理数据、打开系统设置和稍后再说。 |
| Processing | OCR、翻译、AI 改写、保存 | 保留原内容；显示 provider/本地处理状态；可取消长任务。 |
| Success | 截图、剪贴板恢复、翻译 | 展示结果和可复用动作；不自动关闭，除非用户已配置。 |
| Failure | OCR、provider、保存、恢复格式 | 保留原内容；显示错误摘要、重试、切换 provider 或手动路径。 |
| Paused | 剪贴板 recorder | 菜单栏和历史面板顶部可见；旧历史仍可搜索；恢复记录为主行动。 |
| Excluded app | 剪贴板 recorder | 只记录 skipped 状态、来源候选和时间；不读取内容快照。 |
| Preview confirmation | 截图、完整剪贴板、敏感本地内容 | 使用 `{components.confirmation-card}`，默认只显示摘要，可展开查看完整内容。 |
| External transfer confirmation | provider / CLI / API | 显示 provider、来源、字符数或条目 ID、处理目的；确认后才外发。 |
| Destructive or hook confirmation | Hook、删除、清空 | 使用 `{components.danger-card}` 或高风险确认；展示影响范围和撤销路径。 |
| Audit available | 敏感 action 后 | 结果面板或设置页展示 audit_id 摘要入口。 |

## Interaction Primitives

**Global shortcuts**

- Screenshot：默认 `Option + A`，可更换、禁用、恢复默认。
- Clipboard：默认 `Option + V`，可更换、禁用、恢复默认。
- Translation：默认未设置；设置页提供录入入口、冲突提示、禁用和恢复默认。

**UI language**

- 默认跟随 macOS 系统语言。
- 设置页提供 Follow System、简体中文、English、日本語；P3-A 可先保存偏好并提示重启生效。
- App UI 文案和用户可读错误信息本地化；action 名称、JSON 字段、schema、`error.code`、audit_id、短哈希和 CLI 机器输出不本地化。

**Keyboard behavior**

- `Esc`：关闭最上层浮层；在搜索框中先清空搜索；在截图选区中取消。
- `Enter`：执行当前高亮的主行动；在确认卡片中不得默认执行高风险继续。
- `Tab` / `Shift+Tab`：按视觉阅读顺序移动焦点，确认卡片不能跳过取消按钮。
- `ArrowUp` / `ArrowDown`：剪贴板历史和审计列表中移动选中项。
- `/`：在剪贴板历史中聚焦搜索；设置页不抢系统输入。

**Pointer behavior**

- 截图区域拖拽显示尺寸；过小选区提示并要求重选。
- 窗口截图悬停高亮候选窗口；不可捕获时给出结构化提示。
- 剪贴板列表单击选中，双击执行默认复制或粘贴动作，具体默认在 P3 story 中实现前复核。

**Banned in V1**

- AI 独立聊天入口。
- 自动处理完整剪贴板历史。
- 静默外发 provider。
- 静默启用 hook。
- 依赖 hover-only 才能发现核心动作。
- 卡片套卡片、营销式 hero、装饰渐变背景。

## Accessibility Floor

行为可访问性以 WCAG 2.2 AA 和 macOS 原生辅助功能习惯为下限；视觉对比由 `DESIGN.md` token 保证。

- 所有工具按钮、图标按钮、状态 badge 和确认卡片必须有可读 accessibility label。
- 屏幕录制、辅助功能、剪贴板 recorder、登录项和 provider 状态必须能被 VoiceOver 朗读为“权限名、状态、下一步”。
- 选区 overlay 需要键盘取消路径；后续 P3 若支持键盘微调选区，必须在 UX update 中补充。
- 确认卡片必须先读出风险 level 和 reason，再读 preview。
- 列表选中项、搜索结果数量、翻译完成、保存失败等动态状态需要可感知公告。
- 所有可点击目标不小于 28px 高；设置页和确认卡片中的关键按钮不小于 32px 高。
- Reduce Motion 下禁用浮层弹性动效和过度位移动效，只保留淡入/淡出或即时切换。

## Responsive & Platform

V1 主要面向 macOS 桌面和笔记本，不设计移动端。支持单屏和多屏策略，但跨屏截图选区在 P2 未覆盖，V1 UX 先以结构化失败和后续复测项处理。

| Context | Behavior |
| --- | --- |
| Laptop / single display | 浮层靠近触发上下文；设置页默认双栏。 |
| External display | 截图 overlay 覆盖当前可见屏幕集合；跨屏选区若未实现，提示不支持并允许重选单屏区域。 |
| Narrow window | 设置页侧边栏可压缩为顶部分区列表；内容保持单列。 |
| Full keyboard use | 剪贴板、翻译、设置页必须可完整键盘操作。 |

## Tool Experience Details

### Screenshot

- Screenshot Selection 包含 Region、Window、Fullscreen 三种模式。区域模式显示边界、尺寸、重选和取消；窗口模式显示候选高亮；全屏模式进入同一结果浮层。
- Screenshot Result Overlay 展示图片预览、复制、保存、另存为、拖拽、置顶、重新截图。OCR、Translate、Summarize、Detect Content 进入确认或处理状态。
- 截图历史只展示时间、尺寸、模式、后续 action 和 audit_id 摘要；不展示 base64 或普通日志中的完整图片。

### Clipboard

- Clipboard History Panel 打开后搜索自动聚焦，列表按时间倒序。Pinned 分区在普通历史上方；Group 只作用于 pinned 或用户明确加入的条目。
- V1 默认对非排除 App 保存本机可恢复内容：text、RTF、image、URL、file URL；保留时间和数量上限在设置页配置，Pinned Item 不过期。可恢复内容不得进入普通日志、agent 默认结果或外部 provider。
- 隐私排除 App 命中时不读取内容快照，只展示 skipped、source candidate 和时间。
- Agent 或 CLI 默认只拿 id、类型、时间、来源候选和摘要；完整内容需要 `preview` 确认。

### Translation

- Translation Panel 支持手动输入、选中文本、当前剪贴板、剪贴板历史条目、截图 OCR 文本和 `jdtool.translate.text`。
- 面板必须展示来源、源语言、目标语言、provider、原文、译文、复制、替换剪贴板、保存历史、重试。
- Provider 不可用时保留原文；用户可切换 provider、打开设置或改用手动输入。

### Settings

设置页左侧分区固定为：

1. Shortcuts
2. Language
3. Permissions & Privacy
4. Clipboard
5. Privacy Exclusions
6. AI Providers
7. CLI / Agent
8. Hooks
9. Data & Audit

每个设置项必须说明当前状态、影响范围和恢复路径。快捷键冲突不静默保存；恢复默认只影响单个工具。

### AI / Agent / Hook

- AI 操作嵌入具体工具面板：截图结果、剪贴板详情、翻译面板或确认卡片。
- Provider 设置只展示 BYOK/API 和本地 CLI；不出现内置额度、订阅或账号入口。
- Hook 区只展示 draft / enabled / disabled，agent 生成 hook 默认为 draft。启用、阻断、修改、删除、自动外发必须触发 `destructive_or_hook`。

## Key Flows

### UJ-1 — 林在聊天中快速截图并复制

1. 林在聊天窗口旁按 `Option + A`。
2. Screenshot Selection 进入区域模式，林拖拽一个低敏区域。
3. 选区显示尺寸，林松开鼠标确认。
4. Screenshot Result Overlay 出现，Copy 是主行动。
5. **Climax:** 林点击 Copy，聊天窗口可直接粘贴图片；林没有进入主窗口。
6. Resolution：截图摘要进入历史，包含尺寸、模式和 audit_id。
7. Failure：屏幕录制权限缺失时不进入 overlay，直接显示权限说明和打开系统设置。

### UJ-2 — 周把截图里的英文说明翻译成中文

1. 周截图后在结果浮层点击 OCR。
2. OCR 原文先显示在结果浮层内。
3. 周点击 Translate；如果 provider 是外部 CLI/API，出现 `external_transfer` 确认卡片。
4. 卡片显示 provider、来源 screenshot、字符数和处理目的。
5. **Climax:** 周确认后获得原文/译文对照，并复制译文。
6. Resolution：OCR、翻译 provider、确认级别和 audit_id 进入审计摘要。

### UJ-3 — 许找回并复用一段刚复制过的富文本

1. 许按 `Option + V` 打开 Clipboard History Panel。
2. 搜索栏自动聚焦，许输入关键词。
3. 历史列表显示 RTF 条目，详情区展示格式类型和简化预览。
4. **Climax:** 许选择 Copy 或 Paste，恢复内容保留富文本格式。
5. Failure：格式恢复失败时保留纯文本 fallback，并提示格式无法完整恢复。

### UJ-4 — 陈固定一段常用回复并放入分组

1. 陈在剪贴板历史中选中常用回复。
2. 点击 Pin，条目移动到 Pinned 分区。
3. 点击 Group，选择已有分组或创建新分组。
4. **Climax:** 固定项显示在 Pinned 分区，不受普通过期策略清理。
5. Failure：删除或清空前展示影响范围，避免误删 pinned 内容。

### UJ-5 — 赵对单条剪贴板内容做 AI 改写

1. 赵选中一条 Clipboard Item。
2. 点击 Rewrite。
3. Confirmation Card 显示当前条目 ID、字符数、provider 和“只处理此条”。
4. **Climax:** 赵确认后得到改写结果，可复制、替换剪贴板或保存为历史结果。
5. Failure：provider 超时，保留原文并允许重试或切换 provider。

### UJ-6 — 王划词翻译当前 App 中的一段文字

1. 王在当前 App 选中文本。
2. 触发翻译入口；若快捷键未配置，设置页引导录入。
3. Translation Panel 显示来源 selection、原文和目标语言中文。
4. **Climax:** 王得到译文并复制或替换当前剪贴板。
5. Failure：选中文本读取失败时，提供复制桥接和手动输入替代。

### UJ-7 — Agent 请求读取剪贴板历史摘要

1. 本地 agent 调用 `jdtool.clipboard.search`。
2. 工具默认只返回条目 ID、类型、时间、来源候选和摘要。
3. Agent 请求完整内容时，Main App 显示 `preview` 确认。
4. **Climax:** 用户确认前，agent 不能拿到完整内容；确认后 action 结果带 audit_id。
5. Resolution：Audit View 可查看本次 agent 请求摘要。

### UJ-8 — 用户审查 agent 生成的 hook 草稿

1. Agent 生成 hook manifest，状态默认为 draft。
2. 用户在 Settings → Hooks 查看名称、触发点、权限、输入范围、输出效果和风险级别。
3. 点击 Enable 时出现 `destructive_or_hook` 确认。
4. **Climax:** 用户明确确认后 hook 才能进入 enabled；否则保持 draft。
5. Resolution：启用、禁用和审计记录可在 Data & Audit 查看。

## Traceability

| PRD item | UX surface / behavior |
| --- | --- |
| FR-1 | Menu Bar surface and default state patterns |
| FR-2 | Global shortcuts and Settings → Shortcuts |
| FR-3 | Permission Row and permission missing states |
| FR-4 | Settings → Data & Audit and destructive confirmation |
| FR-5 | Screenshot Selection modes |
| FR-6 | Screenshot Result Overlay |
| FR-7 | Screenshot basic output actions |
| FR-8 | Screenshot AI actions and confirmation cards |
| FR-9 | Screenshot history and audit summary |
| FR-10 | Clipboard recorder controls and paused state |
| FR-11 | Clipboard History Panel |
| FR-12 | Clipboard detail preview and restore behavior |
| FR-13 | Pin, group, delete and cleanup behavior |
| FR-14 | Privacy Exclusions and excluded app state |
| FR-15 | Clipboard item AI processing |
| FR-16 | Translation input sources |
| FR-17 | Translation Result Pair |
| FR-18 | Language controls and default target language |
| FR-19 | Screenshot OCR translation flow |
| FR-20 | Agent translation/action behavior |
| FR-21 | Settings → AI Providers |
| FR-22 | External transfer confirmation |
| FR-23 | Preview confirmation |
| FR-24 | Audit Row and Audit View |
| FR-25 | CLI/action schema entry points |
| FR-26 | Sensitive agent request confirmation |
| FR-27 | Result reuse and structured failure behavior |
| FR-28 | Settings → Hooks draft review |
| FR-29 | Hook enablement confirmation |
| FR-30 | UI language setting, String Catalog coverage, and non-localized CLI/action machine interface |

Success metrics SM-1 to SM-7 map directly to these flows and state patterns; SM-C1 and SM-C2 are enforced through the banned patterns list.
