# 004_剪贴板打磨 Step 4 App 架构师开发复审 v0

日期：2026-07-07
角色：App 架构师
对象：Step 4 详情编辑与元数据组织开发实现
范围：只读架构复审；未修改业务代码、PRD 或技术方案；未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## 1. 结论

结论：`rework-required`

实现主线基本符合 Step 4 技术方案 v1：schema v4、bounded detail read model、detail purpose、DetailStore、Repository save command、contentRevision、URL validator 和保守 rich text gate 都已有明确落点。项目负责人记录中的低敏回归命令在本轮抽查中也能复现关键 PASS。

但本轮发现 2 个 P1：

1. OCR user-edited guard 在 late completion 后不再可靠，存在后续 OCR retry / completion 覆盖用户编辑 OCR 文本的路径。
2. P13D 当前不是技术方案要求的 per-scenario deterministic fixture / fault-injection gate，PASS 不能证明事务、mutation count、revision、OCR sequence、rich text fidelity 等关键风险已闭合。

建议项目负责人不要最终接受 Step 4，要求 R1 返工。R1 应同时修正 OCR guard 和 P13D 覆盖能力；否则当前 `development-verified-pending-review` 不能升级为 accepted。

## 2. 正向证据

- Schema v4 已实现：`MigrationRunner` 支持 `currentVersion > 4` 拦截和 v4 migration；`migrateV4()` 添加 `content_revision`、`content_updated_at`、`ocr_text_source DEFAULT 'none'`、`ocr_user_edited_at`、`ocr_locked_content_revision`，并只对 succeeded 且非空 OCR 文本回填 `vision`。证据：`apps/Blocks/BlocksCore/AppDatabase.swift:71`、`:90`、`:260`、`:278`、`:283`、`:308`。
- Mutable contentRevision 与 capture identity 已分离：`ClipboardDetailReadModel` 同时有 `contentRevision` 和 `captureIdentityRevision`；`loadDetailReadModel` 使用 content state revision，capture identity 仍来自 `ClipboardSearchDocumentBuilder.revision(for:)`。证据：`ClipboardDetailReadModel.swift:97`、`ClipboardRepository+DetailEdit.swift:27`、`:29`、`:30`。
- Repository 是主要持久化事实源：`saveDetailEdit(command:)` 在 repository transaction 中校验 expected revision、写 payload / metadata / search document / FTS，并返回 `ClipboardDetailSaveResult`。证据：`ClipboardRepository+DetailEdit.swift:55`、`:56`、`:60`、`:164`、`:197`。
- detail purpose 已显式加入：`detailEditRead`、`detailFullValueRead`、`detailEditSave`、`detailCopyFullValue` 存在于 `ClipboardPayloadReadPurpose`。证据：`ClipboardPayloadAccess.swift:12`。
- URL validation 本地化且边界保守：只允许 `http`、`https`、`mailto`，拒绝 empty、control char、missing scheme、file/custom scheme。证据：`ClipboardDetailURLValidator.swift:27`、`:41`、`:50`。
- Rich text gate 放在 BlocksCore，且不引入 AppKit；无法证明保真时返回 failure，不静默写入 plain text payload。证据：`ClipboardRichTextFidelityService.swift:30`、`:37`、`:62`。

## 3. P0 Findings

无。

## 4. P1 Findings

### P1-1：OCR user-edited guard 在 `ignoredLateVision` 后失效，可能覆盖用户编辑文本

技术方案要求 `updateOCRResult` 检查 user-edited source，并保证用户编辑 OCR text 后 retry / late completion 不覆盖。证据：`App架构师-技术方案-v1.md:213`、`:217`、`:228`。

当前实现第一段保护存在，但不持久：

- OCR 编辑保存会写 `ocrSource = .userEdited` 和 `ocrLockedContentRevision = newContentRevision`。证据：`ClipboardRepository+DetailEdit.swift:156`、`:158`、`:160`。
- `updateOCRResult` 遇到 `.userEdited` 时，会把 document 重新 upsert 为 `source: .ignoredLateVision` 并返回 `false`。证据：`ClipboardRepository+SearchDocuments.swift:385`、`:390`、`:393`。
- 后续 retry / process guard 只检查 `document.ocrTextSource != .userEdited`。一旦 source 已变成 `.ignoredLateVision`，后续 retry / completion 会继续进入 `updateOCRResult`。证据：`ClipboardVisionOCRQueue.swift:42`、`:74`、`:78`、`:97`。
- `updateOCRResult` 后续成功分支没有检查 `ocrLockedContentRevision`，只基于 source 是否 `.userEdited`。证据：`ClipboardRepository+SearchDocuments.swift:396`、`:405`。

影响：

- 序列 `userEdited save -> late completion ignored -> retry/second completion` 后，用户编辑 OCR 文本仍可能被 Vision 结果覆盖。
- 这违反 Step 4 的 OCR user-edited 持久事实源边界，属于用户可见数据回归，不应作为残余风险接受。

R1 要求：

- 不应把 `ignoredLateVision` 作为替代 `userEdited` 的持久 source，除非所有 OCR guard 都把 `ignoredLateVision` 视为同等 protected。
- 更稳妥做法：保留 `ocr_text_source = userEdited`，把 ignored late completion 写为低敏事件 / lastIgnoredOCRResult / separate flag，而不是替换 source。
- `updateOCRResult` 与 `ClipboardVisionOCRQueue.retryOCR/process` 必须同时检查 user-edited lock 和 locked content revision。
- P13D 增加真实 sequence fixture：user-edited save -> late completion -> retry / second completion -> 断言 OCR text、source、contentRevision、mutation count 不被错误覆盖。

### P1-2：P13D 不是 per-scenario fixture gate，PASS 不能支撑架构接受

技术方案 v1 要求 P13D 使用 deterministic fixture / temp DB / fault injection，并输出非空 mutation count、content revision before/after 等 per-scenario evidence。证据：`App架构师-技术方案-v1.md:623`、`:634`、`:644`、`:653`、`:658`。

当前 P13D 主要是静态文件和 token 检查：

- 脚本没有 temp DB / sqlite / subprocess / Swift fixture runner；只读取文件并检查字符串。
- `scenario_status` 只是判断 scenario 名字是否出现在源码字符串中。证据：`tools/verification/p13d_clipboard_detail_edit_checks.py:452`。
- 输出中所有 scenario 的 `mutation_count`、`content_revision_before`、`content_revision_after` 都是 `null`，但仍 `result=pass`。证据：`p13d` 本轮输出。
- `purpose_matrix.negative_reuse_count` 本轮输出 `paste=1`、`searchIndex=4`，但 gate 仍 `ok=true`。这说明负向矩阵没有被真正作为 fail-closed 判据。
- OCR gate 只检查 `ocrTextSource`、`userEdited`、`ignoredLateVision`、`updateOCRResult` 等 token 是否存在，未覆盖 P1-1 的状态序列。证据：`p13d_clipboard_detail_edit_checks.py:398`。

影响：

- P13D 不能证明同步 transaction rollback、stale revision conflict、cache invalidation、OCR late completion、rich text fidelity pass/fail、full value copy fake pasteboard 等场景实际执行过。
- 当前 P13D PASS 不能作为 Step 4 架构边界已闭合的证据。

R1 要求：

- P13D 必须至少对 repository 层执行低敏 fixture：plain text save、URL valid/invalid、revision conflict、transaction rollback、search/FTS fault、record deleted、payload missing、OCR user-edited sequence、rich text pass/fail。
- 每个 scenario 必须有 fixture id、mutation count、content revision before/after、failure reason 或 pass evidence；这些字段缺失时 fail。
- purpose negative count 若非 0，必须 fail，或改成 path-aware 负向扫描避免误报后再 fail-closed。
- 将 P1-1 作为必测 scenario，防止只靠 token presence 再次漏检。

## 5. P2 Findings

### P2-1：Rich text fidelity 是安全保守实现，但不能宣称格式代表项已保真通过

当前 `ClipboardRichTextFidelityService` 会用简单 RTF 重新包裹 draft 文本；如果原始 RTF 有 link / inline style / list 等 token，通常会返回 `richTextFidelityFailed`，不会静默降级。证据：`ClipboardRichTextFidelityService.swift:45`、`:55`、`:68`、`:80`。

这从数据安全角度可接受，但与 PRD 的“最低格式保留验证范围”存在表达风险。证据：`产品经理-PRD-v1.md:142`。R1 后 P13D 应区分：

- 简单 RTF 可保存。
- 带 link/style/list 的 RTF 被阻断且有明确 failure。
- 如果项目要宣称 `detail_rtf_format_004` PASS，则必须真实证明代表项保真，而不是只证明会失败。

### P2-2：purpose 仍是字符串边界，OCR/full-value 读取存在绕过显式 purpose 的实现余量

`ClipboardDetailEditCommand.purpose` 是 `String`，repository 通过字符串比较校验；`ClipboardDetailStore.beginEditing()` 对 image OCR 文本直接读取 `loadSearchDocument(...).ocrText`，没有同等 purpose 参数。证据：`ClipboardDetailEditCommand.swift:16`、`ClipboardRepository+DetailEdit.swift:48`、`ClipboardDetailStore.swift:119`。

这不一定阻断当前接受，但建议 R1 或后续收口把 Core 层 purpose 类型化，或至少让 OCR full text / edit draft 也经过等价 explicit purpose 入口，减少后续绕过。

### P2-3：UI dirty-navigation 目前更像 action bar 状态，不是完整阻断式 sheet

PRD 要求 dirty navigation 使用阻断式确认 sheet，默认焦点在安全动作。证据：`产品经理-PRD-v1.md:308`。当前 `ClipboardDetailStore.cancel()` 将状态置为 `.dirtyNavigation`，`ClipboardDetailEditorView` 里 action bar 按钮切成 `Discard` / `Save`，未看到真正三动作 sheet 和默认焦点证据。证据：`ClipboardDetailStore.swift:140`、`ClipboardDetailEditorView.swift:119`。

这更偏 UI/交互复审范围，本架构复审不把它列为 P1；但 P13D 当前也没有真实 UI fixture，因此应交 UI/交互和测试/质量确认。

## 6. 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
```

结果：exit 0 / PASS，但复审判定为证据不足。关键原因：scenario 的 `mutation_count`、`content_revision_before`、`content_revision_after` 均为 `null`；`purpose_matrix.negative_reuse_count` 中 `paste=1`、`searchIndex=4` 仍未导致 fail。

```bash
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
```

结果：PASS。输出 `schema_version=4`，`storage_root=<TMP>`，仓储 smoke 低敏。

```bash
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
```

结果：PASS。

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

结果：PASS。

```bash
git diff --check
```

结果：PASS。

本轮未重新运行 Blocks App / BlocksCLI xcodebuild 和 CLI help；项目负责人验收记录已运行并 PASS。本复审已经发现 P1，继续消耗构建时间不会改变“需 R1”的架构结论。

## 7. 未覆盖风险

- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 未做真实 UI / VoiceOver / 真实跨 App 富文本交互验证。
- 未运行完整构建矩阵；以项目负责人记录和本轮静态/低敏 gate 为依据。
- P13D 当前不是可依赖的动态 gate，因此其 PASS 只能视为静态边界参考，不能视为 Step 4 架构闭合证据。

## 8. 建议

建议项目负责人要求 R1 返工，不建议当前接受。

R1 最低闭合条件：

1. 修复 OCR user-edited guard：late completion 不得把 protected source 解除，后续 retry / completion 也不得覆盖用户编辑 OCR 文本。
2. 重写或补强 P13D：真实执行 deterministic repository fixtures / fault injection，非空 mutation count 和 revision evidence，fail-closed 覆盖 P1-1。
3. R1 后至少复跑：P13D、P9A、P9B、P11E、`git diff --check`；若 UI 或 Core target 有改动，再复跑 Blocks App / BlocksCLI build。
