# 004_剪贴板打磨 Step 4 开发实现测试/质量复审 v0

日期：2026-07-07

角色：测试/质量

复审对象：

- `AGENTS.md`
- `agents/测试-质量.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `step_4/产品经理-PRD-v1.md`
- `step_4/App架构师-技术方案-v1.md`
- `step_4/项目负责人-开发派发-Step4-v0.md`
- `step_4/开发记录-Step4-v0.md`
- `step_4/项目负责人-Step4开发验收-v0.md`
- Step 4 相关代码与 verification 脚本静态抽查。

## 结论

`rework-required`

通用回归矩阵、构建、CLI help 和 `git diff --check` 均已独立复跑通过；但 Step 4 不能据此进入最终接受。核心原因是 Step 4 专属 gate `P13D` 存在假 PASS 风险：它当前主要验证 scenario 名称、token 和文件存在，不验证 deterministic fixture 的真实 mutation、content revision、fault injection、full value read/copy 或 rich text fidelity 结果。该 gate PASS 不能支撑 PRD v1 / 技术方案 v1 的关键 acceptance。

静态抽查还发现 dirty-navigation、rich text fidelity、metadata full value/copy 三条用户路径与 PRD v1 / 技术方案 v1 不一致。这些不是“真实 UI 未覆盖”的 P2，而是当前实现或门禁可静态复现的 P1。

建议项目负责人要求返工，至少先关闭下列 P1，再重新串行跑完整矩阵。暂不建议接受 Step 4。

## P0 / P1 / P2 Findings

### P0

无。

### P1

1. P13D 不是可靠的 fail-closed Step 4 专属验收门禁。

   证据：

   - `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` 返回 PASS。
   - 但输出中每个 scenario 的 `mutation_count`、`content_revision_before`、`content_revision_after`、`full_value_read_attempts`、`full_value_copy_attempts` 均为 `null`。
   - 脚本中 scenario 通过条件只是检查 scenario 字符串是否出现在脚本 / 源文件中；见 `tools/verification/p13d_clipboard_detail_edit_checks.py` 的 `scenario_status = {scenario: scenario in scenario_source ...}`。
   - 脚本直接把 `mutation_count`、revision、full value attempts 写成 `None`，但仍允许 scenario `result=pass`。
   - P13D 输出 `purpose_matrix.negative_reuse_count.paste=1`、`searchIndex=4`，仍 `ok=true`，没有按技术方案要求 fail closed。

   风险：

   - plain text、URL、rich text、OCR user-edited、failure rollback、revision conflict、cache invalidation、full value read/copy、v3->v4 migration 并未由 P13D 真实执行或验证。
   - 项目负责人验收中“P13D scenario 均通过”的结论目前只能证明 scenario 名称存在，不能证明场景行为通过。

   必须修：

   - P13D 必须运行 isolated temp database / deterministic fixture / fake clock / fault injection。
   - 必须对各 scenario 输出真实 `mutation_count`、content revision before/after、search / FTS hit 结果、pasteboard read/write attempts、full value read/copy attempts。
   - 必须在字段缺失或为 `null` 时 fail。
   - forbidden purpose 计数若非 0，要么按调用链缩窄到确实非 Step 4 路径并输出理由，要么 fail。

2. Dirty-navigation 未实现 PRD 要求的三动作确认 sheet。

   PRD v1 要求 dirty 状态离开时出现阻断式确认 sheet，固定动作是 `Save and Continue`、`Discard Changes`、`Continue Editing`，保存失败后留在当前记录。

   当前实现：

   - `ClipboardDetailStore.cancel()` 在 dirty 时只设置 `dirtyNavigation = true` 和 `status = .dirtyNavigation`。
   - `ClipboardDetailEditorView` 在 dirtyNavigation 下只把 Cancel 按钮文案改成 `Discard`，但按钮仍调用 `store.cancel()`。
   - `discardDirtyNavigation()` 存在但未被 UI 调用。
   - 静态搜索未发现 `Save and Continue` / `Continue Editing` / `Discard Changes` 或等价确认 sheet。
   - overlay 外部点击调用 `clipboardStore.detailStore.cancel()`，没有三动作确认路径。

   风险：

   - 用户 dirty 后没有 PRD 要求的明确保存 / 放弃 / 继续编辑三路。
   - 当前 UI 可能让用户反复进入 dirtyNavigation，无法真正 discard，也无法 save and continue 原动作。
   - P13D 的 `detail_dirty_navigation_004` 未真实验证该行为。

   必须修：

   - 实现三动作确认 sheet 或等价阻断 UI。
   - `Discard Changes` 必须调用真正 discard 路径。
   - `Save and Continue` 必须保存成功后执行原动作，保存失败留在当前记录。
   - P13D 增加真实 UI-state 或 store-level scenario，证明三路行为和 mutation count。

3. Rich text fidelity 与“富文本文本内容可编辑”合同不闭合。

   PRD v1 要求富文本编辑首选保持 `rich_text` kind 和可见格式；无法保真时不得作为普通可编辑类型直接开发，必须有项目负责人接受降级 / 暂缓 / 只读记录。

   当前实现：

   - `ClipboardRepository+DetailEdit.editability` 对 `.richText` 直接返回 `.editable(.richText)`。
   - `ClipboardRichTextFidelityService.updatedPayload` 重新生成 `"{\\rtf1\\ansi ...}"`，不是在原 RTF 上保留格式编辑。
   - 如果原 RTF 含 `HYPERLINK` / `\\field`、`\\b` / `\\i` / `\\ul` / `\\strike` 或 list 代表项，当前 helper 多数会返回 fidelity failed；这会让 rich text 显示为可编辑但保存失败。
   - 未见项目负责人接受“富文本暂缓编辑 / 只读 + 可复制纯文本 / 只编辑派生纯文本”的降级记录。

   风险：

   - 富文本在用户入口上可编辑，但含代表格式时无法完成保存。
   - P13D 没有实际验证 `detail_rtf_format_004` 的 link / paragraph / inline style / list 逐项结果；输出只是 scenario pass。

   必须修：

   - 要么实现真正的代表格式保真，并让 P13D 逐项验证；
   - 要么将 rich text 标记为 read-only / 暂缓编辑，并补项目负责人接受记录；
   - 不应保持 “rich text 可编辑” 入口，同时用保存失败覆盖格式不保真。

4. Metadata full value read/copy 没有可用 UI 路径，P13D 却显示对应 scenario 通过。

   PRD v1 / 技术方案 v1 要求长 metadata 至少提供 `copy full value` 或等价完整值路径，且 full value read / copy 必须是显式用户动作。

   当前实现：

   - `ClipboardMetadataItem.copyPurpose` 和 `ClipboardDetailStore.fullValueText(...)` 存在。
   - `ClipboardDetailEditorView.metadataGrid` 只展示 `Text(item.boundedValue).textSelection(.enabled)`，未使用 `fullValueAvailable`、`copyPurpose` 或 `fullValueText`。
   - 静态搜索未发现 `fullValueText` 在 UI 中被调用，也未发现 fake pasteboard copy feedback UI。
   - P13D `detail_full_value_read_004` / `detail_full_value_copy_fake_pasteboard_004` 仍显示 PASS，但没有真实 read/copy attempts 证据。

   风险：

   - 用户只能复制 bounded value，不能获取 PRD 要求的完整值路径。
   - full value read/copy 的 purpose 和 fake pasteboard 证据没有实际行为承载。

   必须修：

   - 为 `fullValueAvailable` metadata 增加显式 Copy / Expand 或等价入口。
   - copy 使用 fake pasteboard / spy 验收，真实系统剪贴板不参与自动化。
   - P13D 必须验证 read/copy attempts 和低敏反馈。

### P2

1. 真实 App UI 自动化、真实系统剪贴板、真实 VoiceOver、真实跨 App 富文本粘贴未覆盖。按派发边界，这可以作为 P2 residual，但不能替代上述 P1。
2. Blocks App build 仍有既有 `FloatingPanelSupport.swift` main actor isolation warnings，以及 AppIntents metadata skipped warning；本轮未发现其阻塞 Step 4，但建议后续统一收口。
3. xcodebuild 输出天然包含本地构建路径；本文档未复制完整路径作为验收 artifact。P13D / P13A / P13B / P13C / P11E JSON 输出均使用 sanitizer 或相对路径 / placeholder。
4. 工作区存在大量既有未提交改动，本轮只读复审未尝试归因或回滚。

## 已运行命令

| 命令 | 结果 | 质量判断 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | 命令退出 0，但发现 P1：per-scenario evidence 为空值/静态占位，不能支撑 Step 4 接受。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | Step 1 搜索/OCR 回归边界未见失败。 |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | Step 2 标签/收藏回归边界未见失败。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | Step 3 面板交互/布局回归边界未见失败。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | 产品 polish 通用门禁未见失败。 |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | Settings clipboard/system 回归未见失败。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | schema version 4，temp DB 输出低敏。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / repository integration 通用门禁未见失败。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | clipboard hardening 回归边界未见失败。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | Blocks App 构建通过；存在既有 warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | BlocksCLI 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出仅含 `blocks.screenshot.capture` usage / action list。 |
| `git diff --check` | PASS | 写本文档前已通过；写入本文档后也应再跑一次。 |

## 验证覆盖判断

已覆盖：

- Step 1 / Step 2 / Step 3 的主要静态与 fixture 回归门禁。
- Blocks App / BlocksCLI 编译可用。
- CLI help 可执行。
- P9A 证明当前 repository smoke 已迁移到 schema version 4。
- P11E 仍覆盖旧 redacted-first / payload hardening 边界。

未充分覆盖：

- P13D 未真实证明 Step 4 关键 save scenarios。
- P13D 未真实证明 mutation count、content revision advance/conflict、failure rollback、full value read/copy、rich text fidelity、OCR late completion、cache invalidation。
- Dirty-navigation 三动作确认 sheet。
- Rich text 代表格式保存成功或明确降级接受。
- Metadata full value read/copy 用户路径。

## 低敏输出复核

- P13D / P13A / P13B / P13C / P11E 输出未见真实剪贴板正文、真实 OCR 原文、图片/base64、邮箱、secret、Authorization header 或验证码。
- P9A 输出 `storage_root=<TMP>`、`database_file=Blocks.sqlite`，符合低敏要求。
- CLI help 输出只有 usage/action list。
- xcodebuild 输出包含本地构建路径，这是构建工具常规输出；本文档未复制完整路径作为验收证据。
- 本轮未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## 建议下一步

1. 要求开发先修 P13D，使它从静态占位 gate 变成真正的 deterministic fixture / fault injection gate。
2. 同时修复 dirty-navigation 三动作确认、rich text 可编辑/降级合同、metadata full value/copy UI。
3. 修复后至少重跑：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

## 是否建议项目负责人接受

不建议接受。建议要求返工。

理由：P13D 是 Step 4 专属 acceptance gate，但当前存在假 PASS；同时 dirty-navigation、rich text 和 full value/copy 三条 PRD v1 核心用户路径存在静态可复现缺口。通用回归 PASS 只能说明 Step 1-3 和构建未明显回退，不能替代 Step 4 专属行为验收。
