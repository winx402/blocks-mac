# Step 4C-4 Clipboard Hardening Go/No-Go UI/交互评估

日期：2026-07-06
角色：UI/交互设计师
范围：conditional Step 4C-4 Clipboard hardening 启动前 UI/交互 go/no-go 评估。
结论：`go-for-4c4-development`

## 1. 范围与事实源

本轮只做 4C-4 启动前评估，不写业务代码，不创建 branch / commit，不触发真实 UI、真实剪贴板读取、系统权限或 provider call。

已读事实源：

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- 当前提交：`10d7766 feat: complete step 4c settings shell slice`
- `docs/项目管理库/003_架构升级/step_4/PRD-Step4C-剩余Feature收口-v0.md`
- `docs/项目管理库/003_架构升级/step_4/主会Stop-Go-Step4C-3-SettingsShell-v0.md`
- 静态抽查：`ClipboardStore.swift`、`AppState.swift`、`ClipboardFloatingPanelView.swift`、`ClipboardRecordViews.swift`、`ClipboardHoverDetailLayer.swift`、`ClipboardHistoryView.swift`、`ClipboardSettingsPane.swift`、`ClipboardRecordPreview.swift`、`ClipboardController.swift`、`ClipboardRecorderFoundation.swift`、`ClipboardRepository.swift`、`Localizable.xcstrings`

未运行任何会读取真实剪贴板、操作 UI 或触发系统动作的命令。

## 2. Go/No-Go 判断

UI/交互侧建议进入 4C-4 开发，不建议启动前再补一轮 PRD，也不建议立即拆 Step 4D。

理由：

- PRD 已定义足够明确的 UX contract：`repositoryUnavailable`、`redacted list`、`explicit payload read`、`empty / unavailable / filtered / redacted` 四类状态、Clipboard / Settings 用户反馈面、payload allowlist / denylist。
- 当前代码已有可用于 redacted list 的低敏 metadata：kind、source、timestamp、format summary、pin state、restorable/excluded/snapshotSkipped、signature summary、record summary。
- 当前问题是实现尚未把默认展示和 payload 读取切开，不是 UI contract 不足。
- `p11e_clipboard_hardening_checks.py` 当前不存在，但 PRD 已要求 P11E；这应作为 4C-4 开发首要交付物，而不是启动前阻断。

Go 的前提是：4C-4 必须先关闭 read model / P11E / 用户反馈 P1，再进入测试/质量最终接受。若开发发现这些 P1 无法在 4C-4 内闭合，应立即转为 `split-to-step4d` 并写 handoff record。

## 3. 当前事实依据

### 当前风险事实

- `ClipboardStore.loadRepositoryState(limit:)` 当前会调用 `loadPayloads(for:repository:)`，为 recent records 逐条 `repository.readPayload(recordID:)`。
- `ClipboardStore.preview(for:)` 和 `filteredRecords(query:)` 当前把 `payloads` 传入 `ClipboardController`，搜索和 preview 可受 payload 内容影响。
- `ClipboardFloatingPanelView` 当前在 bottom tray、side list、hover overlay 中向 row/card/detail 传入 `appState.clipboardPayload(for:)`。
- `ClipboardDirectContentPreview` 当前优先展示 `payload?.text` / `payload?.urlString`，没有 redacted-list 默认保护层。
- `AppState.copyClipboardRecordAsPlainText`、`pasteClipboardRecord` 是明确用户动作路径，但当前 payload 来源仍来自已预加载的 `clipboardPayloads`。
- Settings Clipboard pane 当前有 policy、privacy exclusion 和 recorder diagnostics，但没有 repository unavailable / storage degraded / redacted list 说明。
- 当前不存在 `tools/verification/p11e_clipboard_hardening_checks.py`。

### 可用低敏基础

- `ClipboardRecorderRecord` 已包含 metadata：kind、formatSummary、sourceApp、signatureSHA256_12、fixtureOwned、pinned、restorable、excluded、snapshotSkipped、summary。
- `ClipboardRepository` 已有 `readPayload(recordID:)`，可作为 explicit payload read 的窄接口候选。
- 现有文案已有 redacted summaries / local-only / restore unavailable 一类表达，可沿用语气，但 4C-4 仍需新增四类状态的明确文案。

## 4. 进入 4C-4 的最小用户可见变化

若留在 Step 4C，最小用户可见变化必须包括：

1. Clipboard panel 默认列表改为 metadata-first / redacted list：
   - row/card 默认不展示 `payload.text`、URL 全值、图片内容或完整 file path。
   - 默认只展示 kind、source、time、pin/restorable/excluded 状态、format summary、低敏 summary。
   - 每项有可见文案或 badge 说明内容被保护，不是内容丢失。

2. Clipboard panel header 或列表上方出现 repository degraded 反馈：
   - repository unavailable 时显示 storage degraded / history unavailable 状态。
   - 文案区分“历史暂不可用/不可写入”和“复制粘贴动作仍可用或受限”。

3. Empty / unavailable / filtered / redacted 四类状态可区分：
   - empty：没有历史摘要。
   - unavailable：存储暂不可用或历史不可读/不可写。
   - filtered：有历史，但当前搜索/过滤无结果。
   - redacted：有记录，但正文被保护，仅显示摘要/metadata。

4. explicit payload read 有可解释状态：
   - paste、copy、hover detail、translation preview 是 allowlist。
   - 触发前后需要用户能理解“正在读取完整内容用于当前动作”或“完整内容不可用”。
   - 失败不能表现为内容丢失，应显示 payload unavailable / content protected / record not restorable 的区别。

5. Settings 至少补一个用户可见反馈面：
   - 推荐在 Clipboard Settings 增加 storage / privacy summary section。
   - 显示 repository 状态、默认列表 redacted 策略、payload allowlist 摘要。
   - 不展示剪贴板正文、不展示完整 payload、不承诺 App Group/helper/CLI 默认完整 payload。

## 5. 最小反馈面建议

### Clipboard Panel

必须覆盖：

- Header 附近的 degraded banner：repository unavailable 时可见。
- Empty state：无记录时显示“没有历史摘要”。
- Filtered state：搜索/过滤无结果时显示“没有匹配摘要”，并提供 clear filters / clear search 的明确路径。
- Redacted list badge：记录存在但正文受保护时显示“正文已保护 / metadata only”类信息。
- Hover detail：默认可以展示 metadata；若 hover detail 被定义为 explicit payload read，则必须在 detail 内显示读取状态和失败说明。
- Paste/copy/translation preview：允许读取完整 payload，但用户动作和状态反馈必须明确，失败时不能静默。

### Settings

必须覆盖：

- Clipboard storage 状态：正常 / degraded / unavailable。
- 默认列表策略：只显示 redacted summaries / metadata。
- 完整 payload allowlist：paste、copy、hover detail、translation preview。
- 当前不启用范围：App Group、helper 生产写库、CLI 默认完整 payload。

若开发决定不新增 Settings UI，则必须在开发记录解释为什么 Clipboard panel 的反馈面已经足够；UI/交互侧不推荐省略 Settings 反馈，因为 Settings 是用户理解隐私策略和降级原因的低压力位置。

## 6. P0/P1/P2

### P0

无启动前 P0。

### P1

以下 P1 必须在 4C-4 开发和验收前关闭；否则应拆 Step 4D：

1. P11E 缺失：必须新增 fail-closed `p11e_clipboard_hardening_checks.py`，覆盖 read model allowlist / denylist、用户反馈状态、敏感输出边界和当前事实源。
2. 默认列表 payload 读取：必须移除默认列表、普通面板渲染、Settings summary、CLI 默认输出对完整 payload 的读取依赖。
3. 状态不可区分：必须让 empty / unavailable / filtered / redacted 四类状态在 UI 或测试证据中可区分。
4. repository unavailable 用户反馈：Clipboard panel 和 Settings 至少一个可见位置必须解释 storage degraded / repository unavailable；UI/交互建议两处都覆盖。
5. explicit payload read 边界：paste / copy / hover detail / translation preview 必须是唯一完整 payload 读取路径；新增读取路径必须先回写 PRD/P11E。
6. 验收输出低敏：开发记录、verification JSON、验收记录不得包含剪贴板正文、完整 payload、图片/base64、完整 file path 或 OCR 文本。

### P2

1. 是否保留 hover detail 作为 explicit payload read 需要实现时明确；若 hover 默认即读完整内容，用户可能误解“只是经过鼠标”也会读取正文。
2. Redacted list 的文案需要避免让用户以为内容丢失或捕获失败。
3. Repository unavailable 与 recorder paused、empty、filtered 的视觉层级需要实物检查，避免多个状态同时出现时互相覆盖。
4. 长 source name、长 bundle ID、长 kind/type list、长 pinboard name、长三语言文案需要窄宽度实测。
5. VoiceOver 需要确认 redacted badge、degraded banner、copy/paste/translation action 和 clear filters 读序清楚。

## 7. 建议开发边界

建议 4C-4 开发保持以下边界：

- 先写 P11E，再改实现；P11E 必须 fail closed。
- 不启用 App Group。
- 不启用 helper 生产写库。
- 不让 CLI 默认读取完整 payload。
- 不改变用户主动 copy / paste 的既有动作目标，只改变默认列表和反馈语义。
- 不把 Clipboard panel 做视觉重设计；沿用现有 header、filter、row/card、hover detail、Settings section 结构。
- 不把真实剪贴板正文、payload text、图片 base64、完整 file path、OCR 文本写入文档、日志或 verifier 输出。
- 若 read model 分离需要较大架构改动，先把 4C-4 拆 Step 4D，不要在 Step 4C 尾部扩大范围。

## 8. 最终验收必须保留的低敏证据

最终验收至少需要记录：

1. P11E 输出：read model allowlist / denylist 摘要，且不含真实 payload。
2. Clipboard panel 正常 redacted list 低敏截图：默认列表不显示正文。
3. Repository unavailable / storage degraded 低敏截图或模拟证据。
4. Empty / filtered / redacted / unavailable 四类状态各自证据。
5. paste / copy / hover detail / translation preview 的 explicit payload read 证据，只记录动作类别和 record id 类低敏标识。
6. Payload unavailable / record not restorable / storage degraded 的失败反馈证据。
7. Settings Clipboard 反馈面证据：storage 状态、redacted 策略、payload allowlist。
8. VoiceOver / keyboard / 窄宽度 / 三语言长句抽查证据。

## 9. 对主 agent 的建议

建议结论：`go-for-4c4-development`。

UI/交互侧认为 UX contract 已足够派开发；不需要启动前再补方案，也不需要现在拆 Step 4D。开发必须以 P11E 和 read model 分离为第一优先级，且 4C-4 最终接受前 P1 必须为 0。若开发无法在本切片内保证默认列表不读完整 payload、四类状态可区分、repository unavailable 可见、验收输出低敏，则应停止 4C-4 并拆到 Step 4D。
