# Step 1B 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发

## 1. 目标

在 Step 1A 已接受的基础上，进入 Step 1B：搜索状态与 Store / UI 接入。

本批次只解决非空搜索主路径、搜索状态和最小 UI 状态文案，不实现 Step 1C Vision OCR 队列，不做 Step 1D 设置页清理和旧门禁迁移，不推进 Step 2/3/4/5。

## 2. 必读输入

- `step_1/产品经理-PRD-v1.md`
- `step_1/项目负责人-PRD-v1复核-v0.md`
- `step_1/App架构师-技术方案-v1.md`
- `step_1/项目负责人-技术方案-v1复核-v0.md`
- `step_1/项目负责人-Step1A验收-v0.md`
- `step_1/开发记录-Step1A-v0.md`

## 3. 本批次范围

必须覆盖：

- 建立或补齐 `ClipboardSearchResultSet` / `ClipboardSearchCoordinator` 或等价搜索状态模型。
- `ClipboardStore` 暴露搜索状态：`idle`、`results`、`empty`、`emptyIndexing`、`partialIndexing`、`failed`。
- 非空查询主路径使用 repository search / search document / FTS projection，不再只调用 `ClipboardController.filteredRecords(query:)` 做 visible string filter。
- 面板搜索框使用新的 Store search result / state；清空查询时回到默认列表。
- 搜索与现有格式、时间、来源、pinboard 过滤关系保持可用；若本批次无法完整组合所有旧 filter，必须在开发记录说明保留路径和风险。
- 当前可用字段必须能通过低敏 fixture / smoke 证明：
  - 正文文本。
  - 来源 App 名称或 bundle id。
  - URL host / path 片段。
  - file URL 文件名 / extension。
  - rich text plain text。
  - 类型同义词，至少覆盖 `image`、`img`、`ima`、`pic`、`picture`、`photo`、`图片`、`图`、`照片`。
  - 最小时间 token，至少覆盖 `YYYY-MM-DD`、UI 可见日期片段、`today`、`yesterday`、`今天`、`昨天`。
- 局部 index / OCR pending 或 failed 不得把已有结果覆盖成全局 `failed`。
- 搜索状态文案最小接入，能区分确定无结果、当前无结果但仍索引中、有部分结果且仍索引中、搜索路径整体失败。
- 更新 P13A / P9A 或新增窄 smoke，使 Step 1B 范围可测。

允许最小更新：

- `ClipboardSearchDocumentBuilder` 的 type synonym / time token 生成。
- repository search facade 和 pending / failed count 查询。
- `ClipboardFloatingPanelView` 与相关 row/status view 的最小 UI 状态接入。
- 相关 localization key。
- Xcode project membership。

## 4. 明确不覆盖

- 不实现 Apple Vision OCR、OCR queue、OCR retry UI 或 OCR mock running-hold。
- 不读取真实图片做 OCR，不触发真实 OCR。
- 不清理设置页 hardening / redacted UI，不迁移 P8/P8I/P9B/P11E。
- 不改标签/收藏、详情编辑、隐私页 App 清单、面板 hover 安全区、单/双击控件或卡片密度专项。
- 不触发真实 App、真实剪贴板、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。
- 不提交 commit，不创建 branch。

## 5. 验收口径

本批次完成后：

- `P13A` 中 Step 1B 失败码应消除；整体可以继续 `ok=false`，但只允许剩余 Step 1C / Step 1D 失败码。
- 搜索正文、source、URL、file name、rich plain text、类型同义词和最小时间 token 的 fixture 均可命中。
- 非空搜索不再通过 visible/redacted preview 或旧 pinned display name 作为主体搜索路径。
- 搜索状态可测：`idle`、`results`、`empty`、`emptyIndexing`、`partialIndexing`、`failed`。
- 搜索输入不触发同步 OCR，不批量读取所有完整 payload，不触发 provider 或自动化外发。
- 开发记录必须说明 Step 1B 失败码变化、搜索字段 fixture、状态 fixture、低敏输出和残余 Step 1C / Step 1D 风险。

## 6. 必须运行

最低命令：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
git diff --check
```

如触及 Swift 编译、Xcode target membership 或 UI 编译边界，必须补跑：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
```

## 7. 回传要求

回传结论使用：

- `DONE`：Step 1B 范围已完成，验证通过，`P13A` 红灯残余归因清楚。
- `DONE_WITH_CONCERNS`：主要范围完成，但存在非阻断残余风险。
- `BLOCKED`：搜索状态、Store/UI 接入、fixture 或 verifier 无法可靠收敛，或需要项目负责人重新拆分。

回传需列出：

- 改动文件。
- 关键实现边界。
- 搜索字段 fixture 与搜索状态 fixture。
- `P13A` 输出摘要及 Step 1B 相关失败码变化。
- smoke / build / `git diff --check` 结果。
- P0/P1/P2 残余风险。
