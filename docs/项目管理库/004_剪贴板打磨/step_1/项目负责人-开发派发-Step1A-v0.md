# Step 1A 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发

## 1. 目标

在 Step 1A-0 已接受的基础上，进入 Step 1A：Search document 与 bounded preview 基础实现。

本批次只解决搜索派生事实源和明文预览基础，不实现 Step 1B 搜索状态/UI 完整接入，不实现 Step 1C Vision OCR 队列，不做 Step 1D 设置页清理和旧门禁迁移，不推进 Step 2/3/4/5。

## 2. 必读输入

- `step_1/产品经理-PRD-v1.md`
- `step_1/项目负责人-PRD-v1复核-v0.md`
- `step_1/App架构师-技术方案-v1.md`
- `step_1/项目负责人-技术方案-v1复核-v0.md`
- `step_1/项目负责人-Step1A-0验收-v0.md`
- `step_1/开发记录-Step1A-0-P13A-baseline-red-v0.md`

## 3. 本批次范围

必须覆盖：

- 建立 `ClipboardSearchDocument`、`ClipboardContentPreviewSnapshot`、`ClipboardOCRState` 或等价模型。
- 建立 `ClipboardSearchDocumentBuilder` 或等价单一构建入口。
- schema migration 从当前 v1 推进到 v2 或等价版本，新增 search document / OCR state 派生存储。
- `clipboard_fts` 由 search document projection 写入；`clipboard_items.search_text` 如保留，只能作为同一 projection 的兼容字段。
- insert / delete / prune / policy redaction 事务同步维护 record、payload、search document、FTS 和 OCR state。
- `ClipboardStore.preview(for:)` 不再默认使用 `redactedPreview`；列表高频路径读取 bounded preview snapshot。
- text、URL、file URL、rich text plain text 的 preview 与搜索派生基础可通过低敏 fixture 或 smoke 证明。
- 更新必要 repository smoke/verifier，使 v2 schema、search document projection 和旧 `search_text` 兼容语义可测。

允许最小更新：

- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`，用于标明 Step 1A 范围进度或消除 Step 1A 已完成项的失败。
- 既有 `p9a_clipboard_repository_storage_smoke.py` 或新增更窄的 Step 1A repository smoke。
- Xcode project membership。

## 4. 明确不覆盖

- 不实现 `ClipboardSearchCoordinator` 的完整 UI 状态流。
- 不做搜索状态 `idle/results/emptyIndexing/partialIndexing/failed` 的完整面板文案接入。
- 不实现 Apple Vision OCR、OCR queue、OCR retry UI 或 OCR mock running-hold。
- 不清理设置页 hardening/redacted UI，不迁移 P8/P8I/P9A/P9B/P11E。
- 不改标签/收藏、面板 hover/布局、详情编辑、隐私页 App 清单。
- 不触发真实 App、真实剪贴板、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。
- 不提交 commit，不创建 branch。

## 5. 验收口径

本批次完成后：

- repository smoke 能证明 text、URL、file URL、rich text fixture 入库后生成 search document、bounded preview 和 FTS projection。
- duplicate / dedupe 不误建新 search document。
- delete / prune / policy redaction 同步清理或失效 search document、OCR state 和 FTS。
- bounded preview 输出有数据阈值，UI 可见路径有 clamp 或等价约束，不因长文本/长 URL 撑开现有列表。
- View / Store 高频列表预览不批量同步读取完整 payload。
- `P13A` 可以整体继续 `ok=false`，因为 Step 1B/1C/1D 未完成；但开发记录必须说明 Step 1A 已覆盖项的失败码变化，不能把 Step 1A 缺口混入“后续阶段残余”。

## 6. 必须运行

最低命令：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
git diff --check
```

如果 `p9a` 因 schema v2 或 search document 语义变化需要更新，应在本批次内同步更新，并在开发记录说明旧断言如何改为新断言。

如实现触及 Xcode target membership 或 Swift 编译边界，必须补跑对应 build/test 命令，并在开发记录中记录命令和结果。

## 7. 回传要求

回传结论使用：

- `DONE`：Step 1A 范围已完成，验证通过，`P13A` 红灯残余归因清楚。
- `DONE_WITH_CONCERNS`：主要范围完成，但存在非阻断残余风险。
- `BLOCKED`：schema/transaction/smoke/verifier 无法可靠收敛，或需要项目负责人重新拆分。

回传需列出：

- 改动文件。
- 关键实现边界。
- `P13A` 输出摘要及 Step 1A 相关失败码变化。
- repository smoke / build / `git diff --check` 结果。
- P0/P1/P2 残余风险。
