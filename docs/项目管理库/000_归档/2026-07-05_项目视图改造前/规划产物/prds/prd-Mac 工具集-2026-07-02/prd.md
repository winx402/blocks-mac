---
title: 奇点 AI 工具箱 V1 PRD
status: final
created: 2026-07-02
updated: 2026-07-02
---

# PRD: 奇点 AI 工具箱 V1

## 0. Document Purpose

本文是「奇点 AI 工具箱」V1 的正式产品需求基线，面向后续 UX Spec、Architecture、Epics/Stories 和实现计划。它承接 [V1 产品规格](../../../../V1产品规格.md)、[V1 交互规格草案](../../../../../产品知识库/交互整合/V1交互规格草案.md)、[P2 技术验证记录](../../../../../调研与验证库/2026-07-01-P2-技术验证记录.md)、[P2-K 批量技术验证记录](../../../../../调研与验证库/2026-07-02-P2-K批量技术验证记录.md) 和 [P2-L 正式 App Scaffold 架构](../../../../../技术知识库/正式AppScaffold架构-v0.md)。本文定义产品需求和验收边界，不替代 UX 细节设计或正式工程实现。

## 1. Vision

奇点 AI 工具箱 V1 是一个 macOS 原生工具箱，先把截图、剪贴板历史、翻译三类高频内容处理工具做深，再让这些能力通过统一 Action 被 UI、CLI 和本地 agent 稳定调用。

V1 的核心判断是：用户不是缺一个聊天框，而是需要在截图、复制、翻译这些日常动作发生的地方，快速、低打扰、安全地继续处理内容。AI 能力必须嵌入具体工具流程，帮助用户 OCR、翻译、总结、改写或识别敏感内容，但不能静默读取、上传或自动修改用户内容。

产品的长期价值来自两条闭环同时成立：人可以通过 Mac UI 顺手完成任务，agent 可以通过结构化接口调用同一能力并得到可审计结果。V1 不追求工具数量，而追求三类工具达到可日常使用的基础质量。

## 2. Target User

### 2.1 Jobs To Be Done

[ASSUMPTION: 目标用户暂按 Mac 高频内容处理用户、agent power user、开发者/知识工作者描述；具体付费人群仍未锁死。]

- 在沟通、写作、开发、研究时快速截取屏幕局部、窗口或全屏，并立即复制、保存、标注或继续 OCR/翻译。
- 找回刚才复制过的文本、富文本、图片、链接或文件引用，保留格式并复用常用片段。
- 把选中文本、剪贴板内容、截图 OCR 文本快速翻译，并保留原文/译文对照和可复制结果。
- 在明确授权下，让本地 agent 查询工具摘要、调用翻译或处理单条内容，而不是要求用户手工搬运上下文。
- 在处理截图、剪贴板和翻译内容时，清楚知道哪些数据留在本地，哪些会进入外部 provider。

### 2.2 Non-Users (V1)

- 需要团队云端截图库、跨设备同步或多人协作内容库的用户。
- 需要完整录屏、快剪、滚动截图、长文档翻译或文件批处理工作台的用户。
- 期望工具自动监听所有内容并主动发送到云端 AI 的用户。
- 需要密码管理器、DLP 系统或企业审计平台替代品的用户。

### 2.3 Key User Journeys

- **UJ-1. 林在聊天中快速截图并复制。**
  - **Persona + context:** 林是每天高频沟通的 Mac 用户，正在把一个界面状态发给同事。
  - **Entry state:** 任意前台 App，截图快捷键已启用。
  - **Path:** 林按截图快捷键，拖动选择区域，确认后看到截图结果浮层，点击复制，将图片粘贴到聊天窗口。
  - **Climax:** 聊天窗口拿到正确图片，林没有离开当前工作上下文。
  - **Resolution:** 截图历史保存本次操作摘要，后续可找回。
  - **Edge case:** 如果屏幕录制权限缺失，工具不进入选区，直接展示权限原因和系统设置入口。

- **UJ-2. 周把截图里的英文说明翻译成中文。**
  - **Persona + context:** 周正在阅读英文界面或文档截图，不想手动抄文字。
  - **Entry state:** 截图结果浮层已打开。
  - **Path:** 周点击 OCR，检查识别出的原文，再点击翻译；如果使用外部 provider，工具展示外发预览和确认卡片；周确认后得到译文。
  - **Climax:** 周拿到原文/译文对照，并能复制译文。
  - **Resolution:** 本次 OCR、翻译 provider 和确认级别进入审计摘要。

- **UJ-3. 许找回并复用一段刚复制过的富文本。**
  - **Persona + context:** 许在多个文档和网页之间整理资料，需要找回几分钟前复制的内容。
  - **Entry state:** 剪贴板 recorder 已开启，历史面板快捷键可用。
  - **Path:** 许按剪贴板快捷键，搜索关键词，选中目标条目，在详情区确认格式类型，选择复制或粘贴。
  - **Climax:** 内容恢复到可用格式，而不是只剩纯文本。
  - **Resolution:** 面板保持可键盘操作，许继续处理下一条。

- **UJ-4. 陈固定一段常用回复并放入分组。**
  - **Persona + context:** 陈经常复用支持回复、代码片段或 API payload。
  - **Entry state:** 剪贴板历史里已有目标条目。
  - **Path:** 陈打开历史面板，选中条目，点击固定，选择或创建分组。
  - **Climax:** 固定项出现在面板上方，并不会因过期策略被清理。
  - **Resolution:** 陈后续可通过搜索或分组快速复用。

- **UJ-5. 赵对单条剪贴板内容做 AI 改写。**
  - **Persona + context:** 赵复制了一段待发送文字，希望压缩语气但不想上传完整历史。
  - **Entry state:** 目标文本是当前剪贴板或某条历史条目。
  - **Path:** 赵选中单条内容，选择改写；工具展示将处理的内容摘要、provider 和字符数；赵确认后得到改写结果。
  - **Climax:** 只有选中条目被处理，完整历史没有进入 provider。
  - **Resolution:** 赵可以复制结果、替换剪贴板或保留原文。

- **UJ-6. 王划词翻译当前 App 中的一段文字。**
  - **Persona + context:** 王在浏览器或文档里阅读外语内容。
  - **Entry state:** 当前 App 有选中文本，翻译入口已配置。
  - **Path:** 王触发翻译入口，工具读取选中文本，显示翻译面板；provider 失败时显示错误和重试/切换 provider 入口。
  - **Climax:** 王看到原文/译文对照，能复制或替换当前剪贴板。
  - **Resolution:** 翻译历史记录来源和 provider 摘要。

- **UJ-7. Agent 请求读取剪贴板历史摘要。**
  - **Persona + context:** 本地 agent 正在协助用户整理上下文，需要知道最近复制过哪些类型的内容。
  - **Entry state:** 用户允许 agent 调用 `jdtool` CLI。
  - **Path:** Agent 调用剪贴板搜索 Action；工具默认返回条目 ID、类型、时间和摘要，不返回完整内容。
  - **Climax:** Agent 能继续工作，但没有绕过用户授权读取完整剪贴板。
  - **Resolution:** 如果 Agent 请求完整内容，Action 返回确认需求或触发用户确认路径。

- **UJ-8. 用户审查 agent 生成的 hook 草稿。**
  - **Persona + context:** 用户希望在保存剪贴板前识别明显敏感内容，但不接受静默自动化。
  - **Entry state:** Agent 已生成 hook manifest 草稿。
  - **Path:** 用户在设置页 Hook 区看到 hook 名称、触发点、权限、输入范围和可能效果；启用前看到 `destructive_or_hook` 确认。
  - **Climax:** Hook 只有在用户明确确认后才启用。
  - **Resolution:** 启用、禁用和审计记录可在设置页查看。

## 3. Glossary

- **奇点工具** — 「奇点 AI 工具箱」的产品简称，V1 覆盖截图、剪贴板、翻译。
- **工具** — V1 中的一个用户可见能力组：截图、剪贴板、翻译。
- **Action** — 可被 UI、CLI、agent 或 hook 调用的结构化能力，例如 `jdtool.translate.text`。
- **Action Core** — 共享的 Action 执行层，负责输入校验、权限判断、确认需求、统一输出和审计 ID。
- **Main App** — 用户可见的 macOS 主应用，负责菜单栏、浮层、设置页、权限引导、确认卡片、Keychain 和审计展示。
- **Helper** — 通过 SMAppService 注册的 Login Item/helper，V1 首轮只承担剪贴板 recorder、后台心跳和轻量事件采集。
- **Provider** — 翻译、OCR、总结、改写等 AI 能力的执行来源，可以是本地 CLI、API 或本地模型。
- **Confirmation** — 用户确认机制，级别为 `preview`、`external_transfer`、`destructive_or_hook`。
- **Audit Log** — 对 Action、provider、确认级别和 redacted preview 的本地审计摘要。
- **Redacted Preview** — 脱敏预览，只包含数量、来源、类型、provider、条目 ID、字符数或短哈希，不包含完整敏感内容。
- **Clipboard Item** — 剪贴板历史中的单条记录，可以是文本、富文本、图片、链接或文件引用。
- **Pinned Item** — 用户固定的 Clipboard Item，不受普通过期策略影响。
- **Group** — 用户对 Pinned Item 的主题分组。
- **OCR** — 从截图或图片中识别文本的过程。
- **Hook** — 自动化扩展点，V1 只允许草稿和受控启用，不开放无约束脚本系统。
- **`jdtool` CLI** — 奇点工具的技术前缀和命令行入口，用于 agent 结构化调用。
- **UI Localization** — App 面向用户界面的本地化。V1 首批 UI 语言为简体中文、英文、日文；它不同于翻译工具本身的源语言/目标语言能力。
- **Liquid Glass** — macOS 26+ 的系统毛玻璃视觉能力。V1 采用渐进增强：macOS 26+ 使用系统 Liquid Glass；macOS 14-25 使用原生 material / `NSVisualEffectView` 回退。

## 4. Features

### 4.1 Global Shell, Settings, And Permissions

**Description:** Main App 提供菜单栏入口、设置页、快捷键配置、权限状态和数据管理。该层实现 UJ-1、UJ-3、UJ-6、UJ-8 的入口基础。

#### FR-1: Menu Bar Entry

用户可以从菜单栏打开截图、剪贴板、翻译、暂停剪贴板记录、最近状态和设置入口。实现 UJ-1、UJ-3、UJ-6。

**Consequences:**
- 菜单栏状态能显示正常、权限缺失、剪贴板暂停、provider 不可用四类状态。
- 菜单栏入口可打开设置页和三类工具入口。

#### FR-2: Configurable Hotkeys

用户可以配置、禁用、恢复默认截图、剪贴板和翻译快捷键。实现 UJ-1、UJ-3、UJ-6。

**Consequences:**
- 截图默认快捷键为 `Option + A`，剪贴板默认快捷键为 `Option + V`。
- 翻译默认快捷键为未设置；V1 在设置页引导用户录入、禁用或恢复默认。
- 快捷键冲突不能静默保存，必须显示冲突状态并允许重新录入。

#### FR-3: Permission Guidance

用户可以在设置页看到屏幕录制、辅助功能、剪贴板 recorder、文件访问、登录项和 provider 配置状态。

**Consequences:**
- 每个权限提示解释为什么需要权限、会处理什么数据、如何关闭或撤销。
- 权限缺失时，相关工具入口显示可恢复路径，而不是失败后无反馈。

#### FR-4: Data Management

用户可以在设置页清理截图历史、剪贴板历史、翻译历史、AI Action 记录和审计摘要。

**Consequences:**
- 清理操作需要展示影响范围，并区分历史内容和审计摘要。
- 清理操作不得删除 Keychain secret，除非用户进入 provider 凭据管理路径。

#### FR-30: App UI Localization

V1 App UI 支持简体中文、英文和日文，默认跟随 macOS 系统语言，并在设置页提供语言偏好入口。

**Consequences:**
- 当前可见 UI 文案必须进入 String Catalog 或等价本地化资源；首批语言为 `zh-Hans`、`en`、`ja`。
- 设置页提供 Follow System、简体中文、English、日本語 选项；P3-A 可先保存偏好并提示重启生效。
- 品牌名「奇点工具」暂保持中文，英文/日文显示名后续品牌定稿再决策。
- CLI/action JSON 的字段名、action 名称、`error.code` 不做本地化；只本地化面向用户的 UI 文案和可读错误信息。

### 4.2 Screenshot Tool

**Description:** 截图工具提供区域、窗口、全屏截图，截图后展示轻量结果浮层和功能组。实现 UJ-1、UJ-2。

#### FR-5: Screenshot Capture Modes

用户可以通过截图快捷键进入截图选择视图，并选择区域、窗口或全屏截图。实现 UJ-1。

**Consequences:**
- 区域选择显示选区边界和尺寸，支持取消和重选。
- 窗口截图应给出窗口候选或高亮反馈；如果无法捕获窗口，返回结构化失败并保留用户可理解提示。
- 全屏截图进入同一结果浮层。

#### FR-6: Screenshot Result Overlay

截图完成后，用户看到包含图片预览和功能组的轻量浮层。实现 UJ-1、UJ-2。

**Consequences:**
- 浮层至少提供复制、保存、另存为、拖拽、置顶、重新截图入口。
- 浮层不得遮挡用户继续判断下一步；用户可以关闭而不丢失最近结果摘要。

#### FR-7: Basic Screenshot Output Actions

用户可以对截图执行复制、保存、另存为、拖拽和重新截图。

**Consequences:**
- 复制后系统剪贴板可粘贴图片。
- 保存失败必须保留当前截图并提示路径或权限问题。
- 拖拽导出不得要求用户先进入完整主窗口。

#### FR-8: Screenshot AI Actions

用户可以从截图结果浮层进入 OCR、翻译、总结和内容识别。实现 UJ-2。

**Consequences:**
- OCR 后必须先展示原文或识别摘要，再进入翻译或总结。
- 截图内容进入外部 provider 前必须出现 `external_transfer` 确认。
- 使用本地处理时仍需要显示处理状态和失败重试入口。

#### FR-9: Screenshot History

系统保存截图结果摘要和后续 Action 摘要，供用户在历史或审计中找回。

**Consequences:**
- 历史至少记录时间、尺寸、来源模式、后续 Action 类型和 audit_id。
- 历史记录不得保存完整 base64 图片到普通日志。

### 4.3 Clipboard Tool

**Description:** 剪贴板工具提供长期 recorder、历史面板、搜索、格式恢复、固定、分组、隐私排除和单条 AI 处理。实现 UJ-3、UJ-4、UJ-5、UJ-7。

#### FR-10: Clipboard Recorder Controls

用户可以开启、暂停、恢复剪贴板记录，并设置保存时间和数量上限。

**Consequences:**
- 暂停状态在菜单栏和历史面板可见。
- 非固定条目超过保留时间或数量上限后可被清理。
- Recorder 默认不能保存被排除 App 的内容快照。
- 对非排除 App 的支持类型，V1 默认保存在本机 App 数据内的可恢复表示；这不代表上传、不代表进入普通日志，也不代表 agent 默认可读完整内容。

#### FR-11: Clipboard History Panel

用户可以通过剪贴板快捷键打开历史面板，按时间倒序浏览并搜索 Clipboard Item。实现 UJ-3。

**Consequences:**
- 搜索栏打开后自动聚焦，并支持键盘选择。
- 空历史、搜索无结果、暂停记录、权限异常都有明确状态。

#### FR-12: Format Preservation And Restore

系统保存文本、富文本、图片、链接、文件引用的可恢复表示。实现 UJ-3。

**Consequences:**
- 富文本从历史恢复时应保留可用格式，而不是只恢复纯文本。
- 图片条目显示缩略图、尺寸和格式摘要。
- 文件引用显示 basename 和类型摘要，不默认暴露完整真实路径给 agent。
- Agent 默认只能获得条目 ID、类型、时间、来源候选和摘要；读取完整内容必须触发 `preview` 确认。

#### FR-13: Pin, Group, Delete, And Cleanup

用户可以固定、分组、删除单条或批量清理 Clipboard Item。实现 UJ-4。

**Consequences:**
- Pinned Item 不因普通过期策略被清理。
- Group 只作用于 Pinned Item 或用户明确加入的条目。
- 删除和清空历史前必须显示影响范围。

#### FR-14: Privacy Exclusions

用户可以排除指定 App，命中排除时系统不读取内容快照。

**Consequences:**
- 被排除 App 的事件最多记录 skipped 状态、来源候选和时间，不记录内容摘要。
- V1 必须支持用户手动添加和移除隐私排除 App；推荐排除列表可以作为 P3/P7 的设置页内容优化，不作为实现者需要自行决定的核心策略。

#### FR-15: Clipboard Item AI Processing

用户可以对单条 Clipboard Item 执行翻译、改写、总结或敏感信息识别。实现 UJ-5。

**Consequences:**
- AI 处理只针对当前选中条目，不处理完整历史。
- 完整内容进入外部 provider 前必须显示 Redacted Preview 和确认。
- 处理结果可以复制、替换当前剪贴板或保存为历史结果。

### 4.4 Translation Tool

**Description:** 翻译工具复用 Bob 式多入口：选中文本、手动输入、当前剪贴板、剪贴板历史条目、截图 OCR 文本，并共享同一结果面板。实现 UJ-2、UJ-5、UJ-6。

#### FR-16: Translation Input Sources

用户可以从手动输入、选中文本、当前剪贴板、剪贴板历史条目和截图 OCR 文本发起翻译。

**Consequences:**
- 每个翻译任务必须记录来源类型。
- 截图 OCR 和剪贴板来源在外发前必须展示预览。
- 选中文本读取失败时提供复制桥接或手动输入替代路径。

#### FR-17: Translation Result Panel

用户看到原文/译文对照、来源、目标语言、provider、处理状态和操作按钮。实现 UJ-6。

**Consequences:**
- 结果面板至少支持复制译文、替换当前剪贴板、保存历史、重新翻译。
- provider 失败时保留原文和错误摘要，允许重试或切换 provider。

#### FR-18: Language Coverage

V1 至少支持中英互译，并保留自动检测语言入口。

**Consequences:**
- 目标语言可配置，默认目标语言为中文。
- 自动检测失败时用户可以手动选择源语言。

#### FR-19: Screenshot OCR Translation

用户可以从截图 OCR 文本进入翻译。实现 UJ-2。

**Consequences:**
- OCR 文本必须先可见，用户确认后才进入翻译。
- OCR 置信不足或失败时提示用户检查原文或重新选择区域。

#### FR-20: Agent Translation Action

Agent 可以通过 `jdtool.translate.text` 提交结构化翻译任务。实现 UJ-7。

**Consequences:**
- CLI 返回统一 JSON envelope，包含目标语言、译文、warnings 和 audit_id。
- 非 mock provider 或敏感来源必须返回或触发 `requires_confirmation`。

### 4.5 AI Provider, Confirmation, And Audit

**Description:** AI 能力服务具体工具，provider 可替换，外发和 hook 风险必须可见、可取消、可审计。实现 UJ-2、UJ-5、UJ-8。

#### FR-21: Provider Settings

用户可以配置本地 CLI provider 和 API provider 的名称、模型、base URL、Keychain account alias、超时和启用状态。

**Consequences:**
- API secret 默认进入 Keychain，不写入普通配置文件。
- CLI provider 使用自身登录态，工具不得读取或保存 CLI token。
- 测试连接不得记录完整 provider 原始敏感输出。
- V1 默认 provider 策略为 BYOK/API 配置和本地 CLI；不提供内置云额度、账号系统、订阅或 license server。

#### FR-22: External Transfer Confirmation

任何外部 provider、API 或 CLI 可能接收用户内容前，系统必须展示 `external_transfer` 确认。

**Consequences:**
- 确认卡片至少展示 provider、来源、字符数或条目 ID、处理目的。
- 默认不展示完整敏感内容；用户可以展开查看时才显示完整内容。

#### FR-23: Preview Confirmation

读取完整剪贴板内容、真实截图或本地敏感内容预览前，系统必须使用 `preview` 确认或已有显式授权策略。

**Consequences:**
- Agent 默认只能获得剪贴板摘要；请求完整内容必须触发确认。实现 UJ-7。
- 真实截图处理前必须有可理解的用户可见状态。

#### FR-24: Audit Log

系统为敏感 Action 生成 Audit Log，用户可以查看和清理。

**Consequences:**
- Audit Log 至少包含 audit_id、Action、时间、来源、provider、确认级别、Redacted Preview。
- Audit Log 不保存完整 secret、完整截图 base64、完整剪贴板历史或 provider 原始敏感输出。

### 4.6 CLI, Agent, And Action Surface

**Description:** `jdtool` CLI 是 agent 调用工具能力的主路径；UI、CLI、agent 和 hook 共享 Action Core。实现 UJ-7。

#### FR-25: Action Catalog And Schema

CLI 可以列出 Action、查看 schema、执行 Action，并返回统一 JSON envelope。

**Consequences:**
- V1 至少覆盖 `jdtool.screenshot.capture`、`jdtool.clipboard.search`、`jdtool.translate.text`。
- 未知 Action 返回结构化错误，不崩溃。

#### FR-26: Sensitive Agent Requests

Agent 读取完整剪贴板、截图内容、选中文本或外发内容时，不得绕过 Confirmation。

**Consequences:**
- 默认搜索剪贴板只返回摘要、类型、时间和条目 ID。
- `include_content=true` 或等价完整内容请求必须返回确认需求或走 Main App 确认。

#### FR-27: Result Reuse

Action 输出的结果可以被用户复用，也可以被 agent 继续处理。

**Consequences:**
- Action 输出包含 audit_id 和 warnings，便于串联后续任务。
- 失败时输出 error code 和可读 message，且不会丢失用户原始内容。

### 4.7 Hook Drafts

**Description:** Hook 是未来自动化扩展点。V1 只定义草稿、预览、启用确认和审计，不开放无约束脚本系统。实现 UJ-8。

#### FR-28: Hook Draft Review

用户可以在设置页查看 agent 生成的 Hook 草稿。

**Consequences:**
- Hook 草稿显示名称、触发点、权限、输入范围、输出效果和风险级别。
- Agent 生成的 Hook 默认状态只能是 draft。

#### FR-29: Hook Enablement Confirmation

用户启用、阻断、修改、删除或自动外发类 Hook 前，必须通过 `destructive_or_hook` 确认。

**Consequences:**
- Hook 启用前必须展示影响预览和撤销路径。
- Helper 默认不运行 Hook；正式运行位置需要后续架构或实现计划确认。

## 5. Cross-Cutting NFRs

- **Performance:** 截图选择、结果浮层、剪贴板历史面板、翻译面板必须给出快速首屏反馈；具体延迟预算在 P3 scaffold 和 UX Spec 中量化。
- **Privacy:** 默认不静默上传截图、剪贴板、选中文本或文件引用；所有外发都必须经过 Confirmation。
- **Security:** API secret 进入 Keychain；普通配置和日志不得保存 secret、token、完整订阅链接、验证码、私钥或完整支付信息。
- **Reliability:** 权限缺失、provider 失败、OCR 失败、保存失败、CLI 错误必须返回可恢复路径。
- **Accessibility:** 核心面板和设置页必须支持键盘操作；快捷键冲突和权限状态不能只依赖颜色表达。
- **Observability:** 关键 Action 必须有 audit_id 和 warnings，便于用户和 agent 理解失败原因。
- **Localization:** App UI 首批支持 `zh-Hans`、`en`、`ja`；翻译工具的语言覆盖仍由 FR-18 单独约束，不能把 UI 多语言误写成翻译能力扩大。
- **Platform Visuals:** 视觉层采用 macOS 原生材质。macOS 26+ 使用系统 Liquid Glass 渐进增强；macOS 14-25 使用 `.regularMaterial`、`.ultraThinMaterial` 或窄范围 `NSVisualEffectView` 回退；截图选区 overlay 不使用重毛玻璃。

## 6. Non-Goals (Explicit)

- V1 不做录屏、GIF、滚动截图、云端截图库或团队协作。
- V1 不做跨设备剪贴板同步、团队片段库或密码管理器替代。
- V1 不做长文档翻译、术语库、多服务并排比较或原图版式覆盖翻译。
- V1 不做文件图片批处理工作台。
- V1 不接真实支付、订阅、license server 或账号系统。
- V1 不启用无约束 hook 脚本，不做静默自动粘贴、静默外发或静默修改用户内容。
- V1 不把 App Store 或 Direct Download 写成已锁死渠道。
- V1 App UI 多语言不代表翻译工具支持语言范围同步扩大；翻译语言覆盖仍以 FR-18 为准。

## 7. MVP Scope

### 7.1 In Scope

- 截图：区域、窗口、全屏、结果浮层、复制/保存/拖拽、OCR/翻译/总结入口、历史摘要、权限提示。
- 剪贴板：历史 recorder、搜索、格式保留、恢复、固定、分组、清理、暂停、隐私排除、单条 AI 处理。
- 翻译：手动输入、选中文本、当前剪贴板、历史条目、截图 OCR 文本、结果面板、失败重试。
- 设置页：快捷键、权限、剪贴板保存策略、隐私排除 App、AI provider、CLI/agent、Hook 草稿、数据清理。
- App UI：简体中文、英文、日文 String Catalog，本地化设置入口，默认跟随系统语言。
- CLI/agent：Action catalog、schema、run、统一 envelope、敏感请求确认边界。
- 本地安全：Keychain secret、Redacted Preview、Audit Log、Confirmation。

### 7.2 Out of Scope for MVP

- 多屏和权限撤销体验可以作为 P3/P7 复测门槛，不阻塞 PRD 完成。
- 第三方复杂剪贴板样本、长期 helper 功耗、真实 provider 调用在进入 Alpha 前复测。
- MCP server、App Intents / Shortcuts 作为后续扩展候选，不作为 V1 PRD 必需项。
- `swift-json-schema` 是否正式采用仍是技术决策，不进入 PRD 需求承诺。

## 8. Success Metrics

[ASSUMPTION: V1 成功指标以本地可验收质量和日常可用为主，不设置收入或增长指标。]

**Primary**

- **SM-1:** 截图主路径可用率：用户能从快捷键完成区域截图并复制到剪贴板。目标：P3 截图纵切验收中 5/5 次成功。验证 FR-5、FR-6、FR-7。
- **SM-2:** 剪贴板恢复质量：文本、富文本、图片、链接、文件引用从历史恢复可用。目标：P4 前低敏样本 5 类全部通过。验证 FR-10、FR-11、FR-12。
- **SM-3:** 翻译闭环完成率：用户能从手动文本、剪贴板条目、截图 OCR 文本完成翻译并复制结果。目标：V1 验收中 3 类入口全部通过。验证 FR-16、FR-17、FR-19。
- **SM-4:** 敏感路径确认覆盖率：外发 provider、完整剪贴板读取、hook enabled 路径都不能静默执行。目标：相关验收用例 100% 触发确认或明确本地策略。验证 FR-22、FR-23、FR-29。

**Secondary**

- **SM-5:** 设置页排障覆盖：用户能从设置页定位快捷键冲突、权限缺失、provider 不可用、剪贴板暂停四类状态。验证 FR-1、FR-2、FR-3、FR-21。
- **SM-6:** Agent 调用安全性：CLI 默认返回结构化摘要和 audit_id，敏感请求返回 `requires_confirmation`。验证 FR-20、FR-25、FR-26、FR-27。
- **SM-7:** UI 本地化覆盖：P3-A 当前可见 UI 在 `zh-Hans`、`en`、`ja` 下均有文案资源；CLI/action JSON 输出保持未本地化。验证 FR-30。

**Counter-metrics**

- **SM-C1:** 不优化静默自动化次数。自动执行越多不代表产品越好；V1 优先确认、可撤销和审计。
- **SM-C2:** 不优化工具数量。V1 成功不由新增小工具数量衡量，而由三类工具的日常可用深度衡量。

### 8.1 Traceability Closure

- UJ-1 覆盖截图入口、结果浮层、输出动作和截图历史：FR-5、FR-6、FR-7、FR-9。
- UJ-2 覆盖截图后 AI 处理与外发确认：FR-8、FR-22、FR-23、FR-24。
- UJ-3 覆盖剪贴板 recorder、历史、格式恢复和隐私排除：FR-10、FR-11、FR-12、FR-14。
- UJ-4 覆盖剪贴板固定、分组、删除和数据管理：FR-4、FR-11、FR-13。
- UJ-5 覆盖剪贴板单条 AI 处理、外发确认和审计：FR-15、FR-22、FR-23、FR-24。
- UJ-6 覆盖翻译来源、结果面板、语言策略和 provider 设置：FR-16、FR-17、FR-18、FR-21。
- UJ-7 覆盖 agent 翻译 action、Action Schema、敏感 agent 请求、结果复用和完整内容确认：FR-20、FR-23、FR-24、FR-25、FR-26、FR-27。
- UJ-8 覆盖 hook 草稿审阅、启用确认、审计和非静默执行边界：FR-24、FR-28、FR-29。
- FR-30 覆盖 App UI 本地化、语言设置和 CLI/action 机器接口不本地化边界；它是所有 UI surface 的横向约束。

## 9. Resolved Decisions And Deferred Items
无阻塞 P3-A 的开放问题。P2-Q 已关闭 readiness 指出的过期问题：

- 翻译快捷键：V1 默认未设置，由设置页引导录入。
- 剪贴板保存：非排除 App 的支持类型默认本地可恢复；agent 默认只拿摘要，完整内容读取必须 `preview` 确认。
- Provider：V1 默认 BYOK/API 配置和本地 CLI，不做内置云额度、账号、订阅或 license server。
- MCP server、App Intents / Shortcuts：不进入 V1，作为 V1.1+ 候选。
- 分发渠道：Direct Download / App Store 继续不锁死，不阻塞 P3-A 本地 scaffold。
- App UI 多语言：V1 首批支持 `zh-Hans`、`en`、`ja`，默认跟随系统；P3-A 当前 scaffold 可先保存语言偏好并提示重启生效。
- macOS 26 视觉：采用系统 Liquid Glass 渐进增强，最低部署版本仍为 macOS 14，旧系统使用原生 material 回退。

仍需后续计划处理但不阻塞 P3-A 的事项：推荐隐私排除 App 列表、Alpha 分发路线、多屏/权限撤销/第三方复杂剪贴板样本复测。

## 10. Assumptions Index

- §2.1 `[ASSUMPTION: 目标用户暂按 Mac 高频内容处理用户、agent power user、开发者/知识工作者描述；具体付费人群仍未锁死。]`
- §8 `[ASSUMPTION: V1 成功指标以本地可验收质量和日常可用为主，不设置收入或增长指标。]`
