# Step 1C 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发

## 1. 目标

在 Step 1B 已接受的基础上，进入 Step 1C：系统 Vision OCR 队列与可测试 OCR 搜索接入。

本批次只解决 OCR recognizer protocol、Apple Vision 实现边界、确定性 mock、OCR 队列、OCR 状态 / retry 入口和 OCR 文本进入 search document；不做 Step 1D 设置页清理，不推进 Step 2/3/4/5。

## 2. 必读输入

- `step_1/产品经理-PRD-v1.md`
- `step_1/项目负责人-PRD-v1复核-v0.md`
- `step_1/App架构师-技术方案-v1.md`
- `step_1/项目负责人-技术方案-v1复核-v0.md`
- `step_1/项目负责人-Step1A验收-v0.md`
- `step_1/项目负责人-Step1B验收-v0.md`
- `step_1/开发记录-Step1A-v0.md`
- `step_1/开发记录-Step1B-v0.md`

## 3. 本批次范围

必须覆盖：

- 新增或补齐 `ClipboardVisionTextRecognizer` protocol，便于 Apple Vision 实现与 deterministic mock 分离。
- 新增 Apple Vision OCR 实现，但只能处理已有剪贴板 image payload；不得读取 file URL 本体、扫描目录或上传 provider。
- 新增或补齐 `ClipboardVisionOCRQueue` 或等价队列，OCR 异步执行，不阻塞面板打开、搜索输入和滚动。
- Core 层只保存 OCR 状态、派生 OCR 文本和 search document 生命周期，不依赖 Vision 框架。
- OCR 状态可表达并持久化或可恢复：pending、running、completed、failed。
- OCR failed 条目提供强关联 retry 入口；点击 retry 后应有可见状态变化，且不会重复启动失控队列。
- OCR 文本成功后进入 search document / FTS，可被 Step 1B 搜索路径命中。
- deterministic OCR mock / fixture 覆盖 pending、running、failed、retry、completed 与 OCR 文本搜索。
- P13A 消除三个 OCR 失败码：`ocr_recognizer_protocol_missing`、`apple_vision_implementation_missing`、`ocr_mock_missing`。
- 低敏输出继续禁止 raw payload、完整 OCR 文本、完整 URL query、完整 file path、base64、secret。

允许最小更新：

- `ClipboardSearchDocument` / `ClipboardSearchDocumentBuilder` 增加 OCR text / status 投影。
- repository OCR 状态写入、重建和搜索索引 invalidation。
- `ClipboardStore` 暴露最小 OCR 状态和 retry action。
- 图片条目或搜索状态区域增加最小 OCR 状态 / retry UI。
- P13A / P9A 或新增窄 smoke 的 fixture 与 fail-closed 规则。
- Xcode project membership 与 localization key。

## 4. 明确不覆盖

- 不清理设置页 hardening / redacted UI，不迁移 P8/P8I/P9B/P11E，这是 Step 1D。
- 不实现外部 OCR provider，不上传图片或 OCR 文本。
- 不新增 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset 或系统设置跳转。
- 不读取 file URL 指向的真实文件内容做 OCR。
- 不改标签/收藏、详情编辑、隐私页 App 清单、面板 hover 安全区、单/双击控件或卡片密度专项。
- 不触发真实 App、真实剪贴板、provider、Keychain、系统设置、Show in Finder 或 restart。
- 不提交 commit，不创建 branch。

## 5. 验收口径

本批次完成后：

- `P13A` 中 Step 1C OCR 失败码应消除；整体可以继续 `ok=false`，但只允许剩余 Step 1D `settings_hardening_negative_tokens_active`。
- OCR recognizer protocol、Apple Vision implementation、deterministic mock 都有静态或 smoke 证据。
- OCR 队列不在搜索输入或面板 body 路径同步运行。
- OCR 只处理已有 image payload；file URL、目录扫描、provider upload、权限扩张均为 fail-closed。
- OCR pending / running / completed / failed / retry 状态可由 fixture 稳定证明。
- OCR text 搜索命中使用 synthetic fixture，不复制真实用户剪贴板或真实图片内容。
- 开发记录必须说明 OCR 数据流、失败重试行为、搜索索引更新、低敏输出和剩余 Step 1D 风险。

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

- `DONE`：Step 1C 范围已完成，验证通过，`P13A` 红灯残余归因清楚。
- `DONE_WITH_CONCERNS`：主要范围完成，但存在非阻断残余风险。
- `BLOCKED`：OCR protocol、mock、queue、retry、索引更新或 verifier 无法可靠收敛，或需要项目负责人重新拆分。

回传需列出：

- 改动文件。
- 关键实现边界。
- OCR 状态 fixture、retry fixture 与 OCR text search fixture。
- `P13A` 输出摘要及 Step 1C 相关失败码变化。
- smoke / build / `git diff --check` 结果。
- P0/P1/P2 残余风险。
