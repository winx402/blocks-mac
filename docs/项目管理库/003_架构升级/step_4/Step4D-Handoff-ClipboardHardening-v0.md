# Step 4D Clipboard hardening handoff v0

状态：handoff-ready
日期：2026-07-06
来源级别：main agent handoff record

## 1. 交接结论

Clipboard hardening 从 conditional Step 4C-4 拆出，作为 Step 4D 独立阶段推进。

Step 4D 的目标不是新增剪贴板能力，而是收紧默认读取边界：默认列表、普通面板渲染、Settings summary 和 CLI 默认输出不得读取完整 payload；完整 payload 只允许在明确用户动作或明确业务用例中读取，并且所有开发记录、verification JSON、验收记录和日志必须低敏。

## 2. 拆分原因

Step 4C core 已完成并具备接受条件。Clipboard hardening 的实际范围超出 Step 4C core 收口尾项，原因包括：

- 当前 `ClipboardStore.loadRepositoryState(limit:)` 默认批量读取 recent records 的 payload。
- 当前普通 Clipboard 面板列表、卡片和 hover overlay 能拿到完整 payload。
- 当前 preview / direct content preview 会用 payload text、URL、fileURL 或 image base64 生成默认展示。
- `summary` 可能包含正文短摘要，需要单独定义是否允许用于 redacted list。
- P11E 缺失，旧 P8/P9 门禁不能 fail-closed 地证明 hardening 目标。
- repository unavailable、empty、unavailable、filtered、redacted 的 UI / Store 状态承载点还需要开发级方案。

## 3. Step 4D PRD 必须回答的问题

Step 4D PRD 不应直接跳到实现。PRD 至少需要明确：

- Metadata / redacted list item 的字段：kind、source、timestamp、pin state、format summary、length / byte count、repository state 等。
- `summary` 的敏感级别：是否可展示、何时必须替换为 redacted placeholder、历史 summary 如何处理。
- Explicit payload read API：建议包含 `purpose` 枚举，最小 allowlist 为 `paste`、`copyPlainText`、`hoverDetail`、`translationPreview`。
- Payload cache 生命周期：默认 reload 不得填满 recent payload cache；cache 写入必须来自 explicit read；退出 detail 或刷新后的保留策略需明确。
- 默认 denylist：default list、normal panel row/card、Settings summary、DataAudit、BlocksCLI 默认输出不得读取完整 payload。
- Repository unavailable / storage degraded 的用户反馈面：Clipboard panel、Settings 或两者。
- Empty、unavailable、filtered、redacted 四类状态的视觉和文案区别。
- 搜索策略：默认只按 metadata 搜索，还是允许 repository FTS 但结果展示仍 redacted；必须说明不会把正文写入 UI / verifier / logs。
- CLI / helper / App Group 边界：Step 4D 默认不启用 helper 生产写库、App Group 或 CLI 完整 payload 默认输出。

## 4. P11E 最低职责

Step 4D 必须新增 `tools/verification/p11e_clipboard_hardening_checks.py`，并 fail closed。

最低职责：

- 输出 `ok`、`failures`、`checked_files`、`current_evidence`、`baseline_reference`、`read_model_allowlist`、`read_model_denylist`。
- 检查 P11E 自身与新增 Swift 文件的 target membership。
- 检查默认 load / reload 路径不得调用 `repository.readPayload(recordID:)` 或批量填充完整 payload cache。
- 检查普通列表、普通卡片 / 行、Settings summary、DataAudit、CLI 默认输出不读取或传入 `ClipboardRecorderPayload`。
- 检查完整 payload 读取只存在于 allowlist：paste、copy plain text、hover detail、translation preview。
- 检查新增 payload read purpose 未同步 PRD 和 P11E 时失败。
- 检查默认 redacted preview 不直接展示可能来自正文的 `summary`。
- 检查 repository unavailable、empty、unavailable、filtered、redacted 有可区分状态或本地化 key。
- 检查 helper 生产写库、App Group、CLI 默认完整 payload 仍未开启。
- 检查 verification 输出、开发记录、验收记录、audit 和 logs 不含剪贴板正文、URL 全文、完整 file path、图片/base64、OCR 文本、窗口标题、屏幕文本、真实凭据、Authorization header、request body 或 provider raw response。

## 5. 旧门禁迁移要求

Step 4D 不能直接复用当前旧 P8/P9 作为阻断证据。进入开发前或开发首批必须迁移：

- `p8_clipboard_product_polish_checks.py`：旧 story / acceptance / archive 只能作为 `baseline_reference`，不得参与 `ok`。
- `p8i_settings_clipboard_system_checks.py`：迁移到 Step 4C-3 后的 `Features/Settings` shell / pane 当前事实源。
- `p9b_clipboard_appstate_repository_integration_checks.py`：从“payload preload 结构存在”改为“metadata load 与 explicit payload read 边界清楚”。
- `p9a_clipboard_repository_storage_smoke.py`、`p9c_no_reset_fixtures_ui_checks.py`：可作为 storage / fixture regression，但不得替代 P11E。

## 6. 建议子批次

建议 Step 4D 拆成至少两个子批次：

- Step 4D-1：P11E 骨架、read model / Store API / AppState facade 方案和默认列表不预读 payload。
- Step 4D-2：Clipboard panel redacted list、hover detail lazy explicit read、paste/copy/translation preview allowlist、repository unavailable UX、Settings feedback 和 P8/P9 迁移。

每个子批次都需要独立开发记录、必要角色复审、测试/质量验收和主会 stop/go。前一子批次 P0/P1 未关闭前不得启动后一子批次。

## 7. 安全与隐私边界

Step 4D 不得引入：

- 真实外部 provider call。
- OCR 或图片外发。
- Keychain secret 读取。
- 网络外发。
- helper 生产写库。
- App Group。
- CLI 默认完整 payload 输出。
- 任意自动化执行能力。

开发和验收证据只能记录 action kind、read purpose、fixture id / synthetic id、kind、source、timestamp bucket、length / byte count、redacted / truncated / unavailable 状态、PASS/FAIL 和相对文件路径。

## 8. 进入条件

Step 4D PRD 可以在本 handoff 提交后启动。进入开发前必须满足：

- Step 4D PRD 写清 read model、allowlist / denylist、summary 规则和 UX 状态。
- App 架构师、UI/交互、安全合规、测试/质量完成方案复审，P0/P1 为 0。
- PRD 阶段文档已提交，开发在干净基线上开始。

## 9. 接受条件

Step 4D 接受至少需要：

- P11E 通过，并输出 read model allowlist / denylist 摘要。
- 旧 P8/P9 已迁移当前事实源，旧归档 / 旧 story / 旧 acceptance 不参与 `ok`。
- 默认列表、普通面板、Settings summary、CLI 默认输出不读取完整 payload。
- paste、copy、hover detail、translation preview 的完整 payload 读取均有 explicit purpose。
- repository unavailable、empty、unavailable、filtered、redacted 有低敏证据。
- App / CLI build、`blocks --help`、`git diff --check` 通过。
- 安全合规和测试/质量均无 P0/P1。
- 主 agent 写最终接受记录，明确未覆盖真实剪贴板正文和系统动作范围。
