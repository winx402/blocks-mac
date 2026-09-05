# Step 4 R1 安全合规顾问定向复审 v0

状态：role-review-complete
日期：2026-07-07
复审角色：安全合规顾问
复审对象：004_剪贴板打磨 Step 4 R1 / R1a 详情编辑与元数据组织返工实现

## 结论

结论：`approve`

P0：0
P1：0
P2：4

建议项目负责人从安全合规视角接受 Step 4 R1 / R1a。本轮定向复审没有发现保存路径读取或写入真实系统剪贴板、full value 读取复用高风险 purpose、provider / network / Keychain / TCC / Finder / System Settings / 自动化动作扩大的实现迹象。上一轮安全 P1 指向的 P13D 证据门禁已关闭：P13D 当前具备动态 Swift fixture、per-scenario 非空 evidence、purpose matrix 负向复用 fail-closed、sanitizer fail-closed 和 R1 current evidence 指针。

本结论不表示已实测真实 App、真实系统剪贴板、真实 VoiceOver、真实跨 App rich text 或真实用户剪贴板内容；这些仍按 P2 residual / Step 6 回扫处理。

## 复审输入

已读取：

- `AGENTS.md`
- `agents/安全合规顾问.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1a-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R1验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/安全合规顾问-Step4开发复审-v0.md`

静态抽查：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPayloadAccess.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailReadModel.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailEditCommand.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailURLValidator.swift`
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

本轮未启动真实 App，未读取或写入真实系统剪贴板，未触发 provider、Keychain、TCC、System Settings、Finder 或自动化动作。

## 已运行命令

| 命令 | 结果 | 说明 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | P13D 输出 `ok=true`；29 个 required scenarios 均有非空 evidence；`negative_reuse_count` 全 0；保存路径 pasteboard read/write 为 0。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | 默认 payload denylist / 输出边界回归通过。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | 明文搜索 / OCR 输出边界回归通过。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | temp DB / schema v4 / search / OCR / tag fixture smoke 通过，输出使用 `<TMP>`。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / Store / repository 集成边界通过。 |
| `git diff --check` | PASS | 未发现 whitespace error。 |
| Step 4 touched-file forbidden token `rg` | PASS | 未发现 detail save/full-value 路径新增真实 pasteboard、network/provider、Keychain、Finder/System Settings、Accessibility 或自动化 API；命中仅为 OCR 队列既有 `ocrInput` purpose、模型字段名和 P13D 自身 denylist 文本。 |
| R1 / R1a / 验收记录低敏 `rg` | PASS | 无命中，未发现真实 home path、凭据样式、图片/base64、OCR 原文、完整 URL / file path 等输出。 |

未重跑 Xcode App / CLI build 和 CLI help；项目负责人验收记录已记录这些命令 PASS。本轮安全复审重点是 R1 P13D、低敏输出和边界路径，不重复触发重型构建。

## P0 Findings

无。

## P1 Findings

无。

上一轮安全 P1 已关闭：

- P13D 当前会编译并执行动态 Swift fixture；Swift fixture 编译失败、执行失败或 JSON 不可解析都会写入 failure 并导致 gate fail。
- P13D `scenario_failure_reason` 对 `mutation_count`、`content_revision_before`、`content_revision_after`、`pasteboard_read_attempts`、`pasteboard_write_attempts`、`full_value_read_attempts`、`full_value_copy_attempts`、`assertions` 和 scenario sanitizer 做非空 / 全真检查。
- P13D 输出 `current_evidence.development_record` 已指向 `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`，R1a 仅修 current evidence 指针，未弱化门禁。
- P13D `purpose_matrix.negative_reuse_count` 对 `.hoverDetail`、`.paste`、`.copyPlainText`、`.translationPreview`、`.ocrInput`、`.searchIndex`、provider 复用均为 0；脚本中非 0 会触发 `detail_purpose_negative_reuse` failure。

## P2 Findings

### P2-1：真实系统剪贴板未实测，copy full value 仍是 fake pasteboard / spy 证据

当前安全上可接受。Step 4 R1 没有实现真实系统剪贴板写入；full value 通过显式 `Show full value` 路径读取并展开，P13D 的 copy 场景使用 fake copy evidence，`pasteboard_write_attempts=0`。如果后续产品要求真实 copy full value，必须单独通过用户显式动作、独立 adapter、低敏反馈和禁止默认预取的门禁重新复审。

### P2-2：full value helper 存在未使用的完整 payload 读取入口，后续调用点需维持显式动作约束

`ClipboardDetailStore.fullValueText(purpose:)` 可在显式 purpose 下读取 editable payload 全文，但当前静态搜索未发现 View 或默认布局调用该 overload；实际 UI 使用的是 `fullValueText(item:purpose:)` 并通过按钮触发。该点不阻塞 R1，但后续新增调用点必须继续由 P13D / P11E 约束为用户显式动作，不得接入默认 layout、tooltip、search、provider、translation 或 hover 自动路径。

### P2-3：Rich text fidelity 覆盖代表 fixture，不等于全量真实 RTF 来源覆盖

R1 已证明代表 fixture 的 link、paragraph、inline style、list、rich text kind 和 plain text derivation；无法保真时 fail closed，不静默降级为 plain text。真实跨 App RTF 变体仍可能触发保存失败，这是产品 / UI residual，不是当前安全阻塞。

### P2-4：真实 UI、真实 VoiceOver 和真实系统环境未覆盖

Dirty navigation、metadata full value 和 accessibility 当前主要依赖 Swift 编译、P13D static binding evidence 与 fixture。按本任务边界未触发真实 App、真实系统剪贴板或 VoiceOver；这些应保留到 Step 6 或专项实物验收，不应写成本轮已实测事实。

## 安全事实依据

### 保存路径与系统剪贴板隔离

- `ClipboardDetailStore.save()` 构造 `ClipboardDetailEditCommand`，purpose 固定为 `detailEditSave`，并调用 `repository.saveDetailEdit(command:)`。
- `ClipboardRepository+DetailEdit.saveDetailEdit(command:)` 在 repository transaction 内校验 `expectedContentRevision` 和 `purpose == "detailEditSave"`，再更新 payload / summary / search document / FTS / content revision。
- Step 4 detail save/full-value touched files 未发现 `NSPasteboard.general`、`setString`、`setData`、`writeObjects`、`clearContents` 或真实系统 pasteboard 读取 token。
- P13D `detail_pasteboard_save_no_read_write_004`、plain text、URL、rich text、OCR text 等场景均输出 pasteboard read/write attempts 为 0。

### Metadata full value read/copy 边界

- `ClipboardPayloadReadPurpose` 包含 `detailEditRead`、`detailFullValueRead`、`detailEditSave`、`detailCopyFullValue`。
- `ClipboardRepository.readDetailMetadataFullValue(recordID:itemID:purpose:)` 只接受 `detailFullValueRead`，否则返回 nil。
- `ClipboardDetailEditorView` 仅在 `item.fullValueAvailable` 且 `copyPurpose == .detailFullValueRead` 时显示 `Show full value` 按钮；默认 metadata grid、bounded preview 和 accessibility label 不直接读取 full value。
- P13D `detail_full_value_read_004` 输出 `full_value_read_attempts=1`、mutation count 0；`detail_full_value_copy_fake_pasteboard_004` 输出 `full_value_copy_attempts=1`、real pasteboard write zero。

### OCR user-edited guard

- `ClipboardVisionOCRQueue.retryOCR` 和 process path 均检查 `document.ocrTextSource != .userEdited` 且 `ocrLockedContentRevision == nil`。
- `ClipboardRepository.updateOCRResult` 遇到 user-edited 或 locked OCR source 时拒绝更新。
- P13D `detail_ocr_user_edited_retry_004` 覆盖 user-edited save 后 late completion、retry、second completion 均 rejected，OCR text、source 和 locked revision preserved。
- 本轮未新增 provider OCR、外部 OCR、自动化读取或图片外发路径。

### URL / Rich Text 边界

- `ClipboardDetailURLValidator` 仅使用本地 `URLComponents` / `URL(string:)` 校验；默认允许 `http`、`https`、`mailto`，拒绝 empty、relative、missing scheme、control character、`file:` 和 custom scheme；未发现网络请求、App launch、Finder 或 System Settings 行为。
- `ClipboardRichTextFidelityService` 为 Foundation-only 保守 helper；不能证明保真时返回 failure，不静默降级为 plain text。

### 低敏输出

- P13D sanitizer self-check 通过，并对 root path、home path、邮箱、TCC raw requirement / csreq 样例做脱敏。
- P13D 输出不包含真实 payload、OCR 原文、完整 file path、图片/base64、Authorization / Bearer / secret。
- R1 / R1a 开发记录和项目负责人验收记录的敏感模式扫描无命中。

## R1a 证据修正确认

R1a 只将 P13D `DEV_RECORD` / `current_evidence.development_record` 从旧开发记录修正为 `开发记录-Step4-R1-v0.md`。复审未发现 R1a 弱化 P13D fail-closed 规则、移除 required scenarios、放宽 forbidden token、关闭 sanitizer 或把旧事实源重新纳入 ok 判定。

## 未覆盖风险

- 未启动真实 App，未做真实 UI 操作。
- 未读取或写入真实系统剪贴板。
- 未触发 provider、Keychain、TCC、System Settings、Finder 或自动化动作。
- 未实测真实 VoiceOver、真实跨 App rich text 和真实用户剪贴板内容。
- 未对项目既有 provider、Keychain、screenshot、autopaste 等旧能力做全量审计；仅复核 Step 4 R1 touched paths 是否新增或绕过这些能力。

## 是否建议接受

建议项目负责人接受 Step 4 R1 / R1a 的安全合规复审结果。P0/P1 已清零，上一轮安全 P1 已通过 P13D fail-closed evidence 修复；当前 P2 residual 不阻塞 Step 4 最终安全接受，但应在后续 Step 6 / 实物验收中继续回扫。
