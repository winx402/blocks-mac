# Step 1C/1D 合并开发补充派发 v0

状态：assigned-supplement
日期：2026-07-07
角色：项目负责人
对象：开发

## 1. 背景

用户补充要求：一次开发的内容可以适度多一些，不需要把同一个顶层 step 拆得过细。

因此，当前开发口径调整为：仍严格保持顶层 Step 串行，Step 1 完成并验收前不进入 Step 2/3/4/5；但 Step 1 内部不再继续拆成过小开发批次。本轮在已派发 Step 1C 的基础上，并入原 Step 1D 的设置页清理、输出边界和门禁迁移，作为 Step 1 收口开发。

本补充替代 `项目负责人-开发派发-Step1C-v0.md` 中“不得做 Step 1D”的限制；其他硬边界继续有效。

## 2. 合并后目标

完成 Step 1 剩余开发收口：

- Vision OCR 队列与可测试 OCR 搜索接入。
- 设置页中与明文展示目标冲突的 hardening / redacted / 内容保护 UI 清理。
- P13A implementation green。
- 旧 P8 / P8I / P9A / P9B / P11E 当前定位迁移或降级，不再以旧 Step 4D redacted-first / metadata-first 作为 Step 1 阻断。
- CLI / log / verifier / 开发记录默认低敏输出回归。

## 3. 必须覆盖

继续覆盖原 Step 1C：

- `ClipboardVisionTextRecognizer` protocol。
- Apple Vision OCR 实现边界。
- deterministic OCR mock / fixture。
- `ClipboardVisionOCRQueue` 或等价队列。
- OCR pending / running / completed / failed / retry 状态。
- OCR 文本进入 search document / FTS 并可被搜索命中。
- OCR 不在面板 open、search input、scroll 主路径同步运行。
- OCR 输入只来自已有 image payload，不读 file URL 本体、不扫描目录、不上传 provider。

并入原 Step 1D：

- active UI 清理或重命名以下负向范围：
  - `settings.clipboardHardening.storage`
  - `settings.clipboardHardening.redactedPolicy`
  - `settings.clipboardHardening.redactedPolicyDetail`
  - `settings.clipboardHardening.allowlist`
  - `settings.clipboardHardening.allowlistDetail`
  - `clipboard.hardening.state.redacted.title`
  - `clipboard.hardening.state.redacted.detail`
  - active UI 中的 `redacted preview`
  - active UI 中的 `payload 不可见`
  - active UI 中的 `只显示字符数` / `只显示长度`
  - active UI 中的 `隐藏摘要`
  - active UI 中的 `metadata-first` 或等价默认遮挡说明
- 容量、保留天数、清理策略、性能、repository unavailable / empty / filtered 状态可以保留，但文案不得暗示默认遮挡真实内容。
- P13A 应从 expected fail 变为 PASS。
- P8 / P8I / P9A / P9B 若仍存在，应迁移为当前事实源检查：
  - bounded plaintext preview。
  - search document / FTS。
  - hardening negative token removed。
  - no unbounded View payload read。
  - no provider / no sensitive output。
- P11E 若保留，只能作为历史 baseline 或 output boundary；不得继续要求默认 UI 不读 payload / redacted read model。
- PASS 与 FAIL 输出、开发记录、验收记录都必须使用同一低敏输出口径。

## 4. 仍然不覆盖

- 不进入 Step 2 标签 / 收藏。
- 不进入 Step 3 面板专项布局、hover 安全区、搜索框宽度、选中反馈、单 / 双击控件、卡片密度。
- 不进入 Step 4 详情编辑、保存 / 取消、富文本编辑、OCR 文本编辑。
- 不进入 Step 5 隐私页真实 App 清单和 CLI 广义对象管理。
- 不实现外部 OCR provider、多模态 provider OCR 或图片上传 OCR。
- 不新增 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset、系统设置跳转或复杂权限开关。
- 不触发真实 App、真实剪贴板、provider、Keychain、系统设置、Show in Finder 或 restart。
- 不提交 commit，不创建 branch。

## 5. 必须运行

Step 1 收口最低命令：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

若保留并可运行 P11E：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

若 P11E 不适合继续作为 Step 1 PASS 门禁，开发记录必须说明其新定位和不运行或降级原因。

## 6. 回传要求

回传结论使用：

- `DONE`：Step 1 剩余开发完成，P13A PASS，旧门禁定位清楚，构建与 smoke 通过。
- `DONE_WITH_CONCERNS`：主要范围完成，但存在非阻断残余风险。
- `BLOCKED`：OCR、设置清理、旧门禁迁移或低敏输出无法可靠收敛，需要项目负责人裁决。

回传需列出：

- 改动文件。
- OCR 状态 fixture、retry fixture、OCR text search fixture。
- 设置页负向 token 清理证据。
- P13A / P8 / P8I / P9A / P9B / P11E 的结果和定位。
- Blocks / BlocksCLI build、CLI help、`git diff --check` 结果。
- P0/P1/P2 残余风险。
