# 004_剪贴板打磨 Step 4 R1 App 架构师复审 v0

日期：2026-07-07
角色：App 架构师
范围：Step 4 R1 / R1a 定向实现复审，仅复核详情编辑与元数据组织的 R1 返工闭环。

## 1. 结论

结论：`approve`。

从 App 架构视角，R1 针对上一轮 Step 4 的 P1 已闭合，P0 / P1 清零。当前实现可以进入项目负责人最终接受收敛，不建议为了本复审列出的 P2 residual 再要求 R1b / R2。

依据：

- P13D 已从静态 token / 文件存在检查升级为 deterministic fixture / fault injection / fail-closed gate，且本轮复跑 PASS。
- Repository 保存路径已经收敛为 `ClipboardRepository.saveDetailEdit(command:)` 单一事务边界，保存成功类和失败类均有 mutation / revision evidence。
- OCR user-edited source、locked revision、retry、late completion 的持久边界已闭合。
- Dirty navigation 的状态所有权在 `ClipboardDetailStore`，View 只绑定确认动作，没有绕过 repository 或直接丢弃 draft 的新事实源。
- Metadata full value read 走显式 purpose 和 UI 动作，保存路径 pasteboard read / write 为 0。
- Rich text fidelity 服务是明确的 Step 4 合同：代表格式可证明时保存，无法证明时 fail closed，不静默降级为 plain text。

## 2. 复审输入

已读取：

- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1a-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R1验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`

重点抽查代码：

- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailEditCommand.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailReadModel.swift`
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。

## 3. R1 P1 关闭情况

### P1-1：P13D 假 PASS

关闭。

事实依据：

- `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` PASS，`failure_summary.count=0`。
- P13D 当前输出包含非空 scenario evidence：`mutation_count`、`content_revision_before`、`content_revision_after`、pasteboard attempts、full value attempts、scenario assertions。
- `purpose_matrix.negative_reuse_count` 全部为 0。
- R1a 已修正 `current_evidence.development_record`，当前指向 `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`。
- P13D 覆盖 save success、invalid URL、rich text fidelity、OCR guard、fault injection、dirty navigation binding、full value、migration 等关键场景。

判断：P13D 已具备本阶段可接受的 fail-closed 架构门禁能力。

### P1-2：OCR user-edited guard

关闭。

事实依据：

- `ClipboardRepository.updateOCRResult` 在 `ocrTextSource == .userEdited` 或 `ocrLockedContentRevision != nil` 时直接拒绝更新，不再把 protected source 改写成其他持久 source。
- `ClipboardVisionOCRQueue.retryOCR` 与 process path 同步检查 `userEdited` / locked revision，retry 和 late completion 不能覆盖 user-edited OCR。
- `saveDetailEdit(command:)` 保存 OCR 文本时写入 `.userEdited`、`ocrUserEditedAt` 和 `ocrLockedContentRevision = newContentRevision`。
- P13D `detail_ocr_user_edited_retry_004` 证明 late completion、retry、second completion 均 rejected，OCR text / source / locked revision preserved。

判断：OCR 冲突处理已从 View-local 风险收敛为 repository/search-document 持久边界。

### P1-3：Dirty-navigation 三动作确认

关闭。

事实依据：

- `ClipboardDetailStore` 持有 `pendingNavigationAction`、`dirtyNavigation`、draft 和 status，状态所有权清晰。
- `requestOpen(recordID:)`、`requestClose()`、`cancel()` 统一进入 dirty guard；`open(recordID:)` 不再直接绕过 guard 加载新记录。
- `saveAndContinue()`、`discardChangesAndContinue()`、`continueEditing()` 对应三动作，保存失败会保留 draft 并停留当前记录。
- `ClipboardDetailEditorView` 使用 `.confirmationDialog` 绑定 `Save and Continue`、`Discard Changes`、`Continue Editing`。
- `ClipboardFloatingPanelView` overlay close 走 `clipboardStore.closeDetailEditor()`，不会直接绕过 store guard。

判断：架构边界已闭合。真实 UI 点击、默认焦点和 VoiceOver 仍属于 P2 验收 residual。

### P1-4：Metadata full value read / copy

关闭。

事实依据：

- `ClipboardRepository.readDetailMetadataFullValue(recordID:itemID:purpose:)` 只接受 `detailFullValueRead`。
- `ClipboardMetadataItem` 提供 `fullValueAvailable`、`category`、`copyPurpose` 和 bounded value。
- `ClipboardDetailStore.fullValueText(item:purpose:)` 校验 item 与 purpose 后才读取完整值。
- `ClipboardDetailEditorView` 对 `fullValueAvailable` 的 item 提供显式 `Show full value` 按钮、反馈和 accessibility hint。
- P13D `detail_full_value_read_004` 与 `detail_full_value_copy_fake_pasteboard_004` 证明 explicit full value path、fake copy attempt、real pasteboard write zero。

判断：本轮实现的是“显式 reveal / fake copy evidence”的等价完整值路径，不写真实系统剪贴板，符合当前低敏边界。若后续产品要求真实 copy，需要另设 user-triggered pasteboard adapter。

### P1-5：Rich text 编辑合同

关闭。

事实依据：

- `ClipboardRichTextFidelityService` 位于 BlocksCore，Foundation-only，不把 rich text fidelity 判定放到 View 层。
- 服务保留原 RTF 容器和控制结构，只替换可匹配的可见文本；段落数量、结构合法性或代表格式 evidence 不通过时返回失败。
- `saveDetailEdit(command:)` 对 rich text 保存要求 `result.passed`，否则抛出 `richTextFidelityFailed`，不写 payload、不推进 revision。
- P13D `detail_rtf_format_004` 证明 link、paragraph、inline style、list representation、richText kind、plain text derivation；`detail_rtf_fidelity_failure_004` 证明 malformed RTF mutation 0。

判断：这不是完整富文本编辑器，但已成为可维护的 Step 4 合同：代表格式可证保存，无法证实时 fail closed，不静默降级。

## 4. 架构复核结论

### Repository / DetailStore / SearchDocument / FTS 原子更新

通过。

- `ClipboardDetailReadModel` 使用 `contentRevision` 和 `captureIdentityRevision` 分离可变内容版本与捕获身份版本。
- `ClipboardDetailEditCommand` 携带 `expectedContentRevision`，repository transaction 内检查 stale revision。
- `saveDetailEdit(command:)` 在同一 transaction 中处理 payload、summary、format summary、contentUpdatedAt、contentRevision、search document upsert 和返回 read model。
- fault injection 场景证明 search document fail、FTS fail、transaction rollback、record missing、payload missing、stale conflict 不产生用户可见部分提交。
- P13D 输出 `async_reindex_enabled=false` 和 not-applicable reason，符合 Step 4 同步 transaction 口径。

### OCR user-edited / locked revision / retry / late completion

通过。

- 持久 source 和 locked revision 是核心防线，retry / process / updateOCRResult 均检查。
- late completion 被拒绝时不改变 protected source。
- P13D 已覆盖 user-edited save 后 late completion、retry、second completion 序列。

### Dirty navigation 状态所有权

通过。

- Dirty draft、pending navigation、保存/放弃/继续编辑状态均在 `ClipboardDetailStore`。
- View 只绑定 store action，未直接写 repository 或持久事实源。
- record switch、close、overlay dismiss 已归一到 store guard。

### Metadata full value purpose / fake pasteboard / UI

通过。

- 默认 metadata snapshot 是 bounded。
- 完整值必须由显式 UI 动作触发。
- Full value read 与 save path 分离；P13D 证明 save path pasteboard read/write 为 0。
- 当前 UI 是 reveal full value，不是真实系统 copy。该取舍在本轮边界内可接受。

### Rich text fidelity service

通过。

- Rich text fidelity 是 Core helper + repository save guard + P13D fixture 的组合合同。
- 未出现“View 层先判断再绕过 Repository 保存校验”的隐式降级路径。
- 代表格式之外的真实 RTF 长尾通过 fail closed 承接，列为 P2。

## 5. Findings

### P0

无。

### P1

无。上一轮五个 P1 均已关闭。

### P2 residual

1. 真实 UI / VoiceOver / 真实系统剪贴板未运行验证。本轮只做静态绑定、fixture 和 fake pasteboard 证据，符合用户限制，但最终验收记录需要继续保留为 Step 6 或专项回扫项。
2. Rich text fidelity 只覆盖代表 fixture，不代表所有真实来源 RTF 变体。当前 fail-closed 策略可接受，但后续如提升富文本体验，需要扩展 fixture 和失败文案。
3. Metadata full value 当前是显式 reveal / fake copy evidence，不是真实系统 copy。若产品后续坚持“复制完整值”写系统剪贴板，需要独立 pasteboard adapter、用户触发边界和低敏 spy gate。
4. `ClipboardDetailEditCommand.purpose` 与 repository detail read/save purpose 仍是 `String` guard，而不是 BlocksCore 内强类型 purpose。P13D 已覆盖正负向 purpose matrix，本阶段不阻塞；后续可收敛为 Core 层 typed enum，减少拼写和跨 target 漂移风险。
5. `ClipboardDetailStore.fullValueText(purpose:)` 仍保留一个不带 `ClipboardMetadataItem` 的旧式完整值读取 helper。当前 UI 调用的是 `fullValueText(item:purpose:)`，P13D 也覆盖 item path；建议后续清理或限制旧 helper，避免未来误用。

## 6. 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
git diff --check
```

结果：

- P13D：PASS，`ok=true`，`failure_summary.count=0`，`purpose_matrix.negative_reuse_count` 全 0。
- P9A：PASS，schema version 4，低敏临时 DB。
- P9B：PASS。
- P11E：PASS。
- `git diff --check`：PASS。

未复跑：

- Blocks App / BlocksCLI build、`blocks --help`、P13A / P13B / P13C / P8 / P8I。项目负责人 R1 验收记录已给出 PASS；本轮是 R1 定向 App 架构复审，未重复完整质量验收矩阵。

## 7. 建议

建议项目负责人接受 Step 4 R1 的 App 架构复审结果，并进入最终接受收敛。当前没有需要开发返工的 P0 / P1；P2 residual 应写入最终验收记录或后续 Step 6 / 专项回扫，不应阻塞 Step 4 结束。
