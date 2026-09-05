# Step 4 安全合规顾问开发实现复审 v0

状态：role-review-complete
日期：2026-07-07
复审角色：安全合规顾问
复审对象：004_剪贴板打磨 Step 4 详情编辑与元数据组织开发实现

## 结论

结论：`rework-required`

P0：0
P1：1
P2：3

建议项目负责人暂不最终接受 Step 4。当前业务实现的静态安全边界总体正确，未发现保存路径读取/写入真实系统剪贴板、provider 外发、网络调用、Keychain、TCC、Finder/System Settings 或自动化执行迹象；但 Step 4 的核心安全证据门禁 P13D 仍存在 P1：per-scenario evidence 不是 fail-closed 的真实 fixture / fault injection 证据，`mutation_count`、content revision before/after、full value read/copy attempts 等关键字段全部为 `null` 仍可 PASS。这会削弱对保存事务、full value 隔离、pasteboard no read/write 和低敏输出边界的最终验收可信度。

建议只要求针对 P13D / evidence gate 返工；除非返工中发现新的实现问题，当前未要求改 PRD、技术方案或业务逻辑。

## 复审范围

已读取：

- `AGENTS.md`
- `agents/安全合规顾问.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发验收-v0.md`

静态抽查了 Step 4 touched files：

- `ClipboardPayloadAccess.swift`
- `ClipboardDetailStore.swift`
- `ClipboardDetailEditorView.swift`
- `ClipboardRepository+DetailEdit.swift`
- `ClipboardDetailURLValidator.swift`
- `ClipboardRichTextFidelityService.swift`
- `ClipboardVisionOCRQueue.swift`
- `p13d_clipboard_detail_edit_checks.py`

本复审未启动真实 App，未读取或写入真实系统剪贴板，未触发 TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## 已运行命令

| 命令 | 结果 | 说明 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | P13D 输出 `ok=true`、pasteboard read/write 为 0、denylist 为 0、sanitizer ok；但见 P1-1。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | Step 1 明文搜索/OCR 输出边界回归通过。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | payload purpose / output-boundary 回归通过。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | temp DB、schema v4、search/OCR/tag fixture smoke 通过，输出使用 `<TMP>`。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / Store / repository 集成边界通过。 |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | Step 2 标签 / 收藏回归通过。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | Step 3 面板交互 / layout 回归通过。 |
| `git diff --check` | PASS | 未发现 whitespace error。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅输出 usage 和 action list，不含剪贴板内容。 |
| Step 4 touched-file denylist `rg` | PASS | 未命中 `NSPasteboard`、`URLSession`、provider、Keychain、Finder/System Settings、ScreenCaptureKit、CGEvent 等 token。 |
| 开发记录 / 验收记录低敏 `rg` | PASS | 未命中真实 home path、凭据样式、图片 base64、完整 URL 样式或邮箱。 |

说明：一次低敏 `rg` 初始命令因 shell 正则包含反引号解析失败，已用简化模式重跑并通过；该失败不作为安全证据。

未重跑 App / CLI build；项目负责人验收记录已独立记录两者 PASS。本轮安全复审没有必要为安全结论重复重型构建。

## P0 Findings

无。

## P1 Findings

### P1-1：P13D per-scenario evidence 未 fail closed，不能支撑最终安全验收

事实依据：

- P13D 当前 PASS，但脚本输出的 29 个 scenarios 中，`mutation_count`、`content_revision_before`、`content_revision_after`、`full_value_read_attempts`、`full_value_copy_attempts` 均为 `null`。
- 脚本实现中这些字段直接写为 `None`，仍把 scenario 标记为 pass。
- P13D 的 scenario pass 主要由 scenario id 字符串是否存在于脚本 / 源码决定，没有证明 deterministic fixture 已实际执行保存、回滚、fault injection、full value read/copy 或 revision before/after 断言。
- 技术方案 v1 明确要求 P13D 缺 mutation count / fixture id / purpose matrix / state ownership 等应 fail closed；当前输出与该要求不一致。

安全影响：

- 当前静态代码边界看起来安全，但最终验收无法充分证明四类保存的 mutation count、revision 前进 / stale conflict、full value read/copy 隔离和 failure rollback 确实发生。
- 如果后续实现误把 full value copy、保存路径或 failure detail 接到真实 pasteboard / provider / 日志，当前 scenario schema 可能仍然因为静态字符串满足而 PASS。
- 这不是直接用户数据泄漏证据，但属于安全门禁可信度不足，阻塞最终接受。

建议返工：

- P13D 必须对每个必测 scenario 产生非空、可验证的低敏 evidence；至少：
  - 成功保存类：`mutation_count = 1`、`content_revision_before`、`content_revision_after` 且 after > before。
  - invalid / conflict / rollback 类：`mutation_count = 0`，并证明 payload / summary / search document / FTS 未部分提交，或进入明确 pending / failed 状态。
  - full value read/copy 类：区分 `full_value_read_attempts`、`full_value_copy_attempts`、`pasteboard_read_attempts`、`pasteboard_write_attempts`；copy 使用 fake pasteboard / spy，不写真实系统剪贴板。
  - pasteboard 保存类：四类保存均输出 read/write attempts 为 0。
- 如果某些 scenario 现阶段只能静态检查，P13D 应显式输出 `evidence_type=static_only` 并由项目负责人决定是否接受；不能以完整 fixture smoke 的名义 PASS。
- P13D failure path 的 stdout / stderr / exception 仍必须经 shared sanitizer 后进入 JSON。
- 返工后建议至少复跑：P13D、P9A、P9B、P13A、P11E、`git diff --check`。

## P2 Findings

### P2-1：P13D purpose matrix 输出存在可读性噪声

P13D PASS 输出中 `negative_reuse_count.paste = 1`、`negative_reuse_count.searchIndex = 4`，但收窄静态抽查未发现 Step 4 detail edit/save 路径复用 `.paste` 或 `.searchIndex` purpose；命中看起来来自字符串 / 类型名计数噪声。

建议：P13D 将 forbidden purpose reuse 统计限定到 detail edit / full value / save call graph 的语义位置，避免 PASS 输出看起来像存在高风险复用。

### P2-2：Rich text fidelity 是保守 gate，不是完整富文本编辑器

`ClipboardRichTextFidelityService` 在无法证明链接、段落、inline style 或列表保真时会失败，不静默降级 plain text。这是安全上可接受的保守实现，但用户可能遇到复杂 RTF 保存失败。

建议：将该点保留为产品 / UI residual，不作为安全阻塞；验收记录不得把它描述成完整富文本编辑器。

### P2-3：真实 UI、真实 VoiceOver、真实系统剪贴板未覆盖

本轮证据来自静态抽查、temp DB、fixture、spy 和低敏 verifier；没有真实 App UI、真实系统剪贴板、真实 VoiceOver 或真实跨 App 富文本交互。

建议：该残余不阻塞安全门禁修复，但 Step 6 或专项验收应继续回扫；当前文档不得写成真实系统环境已验证。

## 安全事实依据

### 保存路径与 pasteboard

- `ClipboardDetailStore.save()` 只构造 `ClipboardDetailEditCommand` 并调用 `repository.saveDetailEdit(command:)`。
- `ClipboardRepository+DetailEdit.saveDetailEdit(command:)` 检查 `purpose == "detailEditSave"`，并在 repository transaction 内更新 payload / summary / search document / FTS / revision。
- Step 4 touched files 收窄扫描未命中 `NSPasteboard` 或真实系统 pasteboard API。
- P13D 输出 `pasteboard_read_attempts=0`、`pasteboard_write_attempts=0`。

### Purpose 隔离

- `ClipboardPayloadReadPurpose` 存在 `detailEditRead`、`detailFullValueRead`、`detailEditSave`、`detailCopyFullValue`。
- `ClipboardDetailStore.beginEditing()` 使用 `detailEditRead`。
- `ClipboardDetailStore.save()` 使用 `detailEditSave`。
- `ClipboardDetailStore.fullValueText()` 默认使用 `detailFullValueRead`。
- `ClipboardRepository+DetailEdit.readDetailEditablePayload(...)` 只允许 `detailEditRead` / `detailFullValueRead`。
- Step 4 touched files 未发现复用 hover、translation、provider、ocrInput 等高风险 purpose 承载详情编辑读写。

### URL / Rich Text / OCR

- `ClipboardDetailURLValidator` 只做本地 `URLComponents` / `URL` 解析，默认只允许 `http`、`https`、`mailto`，拒绝 empty、control character、missing scheme、`file`、custom scheme；未见网络请求或系统动作。
- `ClipboardRichTextFidelityService` 是 Foundation-only 保守 gate；无法证明保真时返回 failure，不静默转 plain text。
- `ClipboardVisionOCRQueue` 和 repository OCR update 路径检查 `ocrTextSource != .userEdited`，避免 retry / late completion 覆盖用户编辑 OCR 文本。

### Provider / 自动化 / Keychain / 系统动作

- Step 4 detail read / save / URL / rich text / OCR text edit touched files 收窄扫描未命中 `URLSession`、provider、Authorization/Bearer、`Process`、AppleScript、CGEvent、Accessibility、ScreenCaptureKit、Finder/System Settings、SecItem / Keychain 等 token。
- 全局 grep 命中的 provider、Keychain、ScreenCaptureKit、pasteboard 和 CGEvent 位于既有服务 / 截图 / provider / autopaste 路径，不属于 Step 4 detail edit/save touched files；本复审未把这些既有路径计为 Step 4 新风险。

### 低敏输出

- P13D / P13A / P13B / P13C sanitizer 均 PASS。
- P9A 输出使用 `<TMP>`，未暴露完整临时路径。
- CLI help 只输出 usage 和 screenshot action list。
- 开发记录和项目负责人验收记录低敏扫描未见真实 home path、URL 全文、邮箱、凭据样式、图片 base64 或 OCR 原文。

## 未覆盖风险

- 未启动真实 App，未做真实 UI 操作。
- 未读取或写入真实系统剪贴板。
- 未触发 TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 未重跑 App / CLI build；本轮只引用项目负责人验收记录中的 build PASS。
- 未对项目既有 provider、Keychain、screenshot、autopaste 等旧能力做全量安全审计；只判断 Step 4 touched paths 是否新增或绕过这些能力。

## 是否建议接受

不建议项目负责人当前最终接受 Step 4。

建议要求开发做一次定向返工：修复 P13D per-scenario evidence，使其真正 fail closed，并补足 mutation count、content revision、full value read/copy、pasteboard spy 与 fault injection 证据。若返工后 P13D、P9A、P9B、P13A、P11E 和 `git diff --check` 继续通过，且无新的真实外发 / pasteboard / 凭据输出问题，安全合规可以转为建议接受。
