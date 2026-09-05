# Step 1A-0 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发

## 1. 目标

开始 Step 1 开发，但只做第一个子批次：`Step 1A-0：P13A baseline red`。

本批次目标是先建立 fail-closed 验证门禁，证明当前旧实现仍不满足 Step 1 明文展示、search document、Vision OCR 和低敏输出目标。不得在本批次修业务代码让门禁转绿。

## 2. 输入文档

- `step_1/产品经理-PRD-v1.md`
- `step_1/项目负责人-PRD-v1复核-v0.md`
- `step_1/App架构师-技术方案-v1.md`
- `step_1/项目负责人-技术方案-v1复核-v0.md`

## 3. 允许改动

- 新增 `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`。
- 新增开发记录：`step_1/开发记录-Step1A-0-P13A-baseline-red-v0.md`。
- 如脚本需要复用 sanitizer/helper，可做最小只读调用或轻量 helper 接入；不得扩大到业务实现。

## 4. 不允许改动

- 不实现 search document / bounded preview。
- 不修改 Clipboard repository / Store / View / Settings / OCR 业务代码。
- 不迁移 P8/P8I/P9A/P9B/P11E。
- 不启动 Step 2/3/4/5。
- 不触发真实 App、真实剪贴板、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。
- 不提交 commit，不创建分支。

## 5. P13A baseline red 最低要求

脚本应 fail closed，当前基线预期失败。最低检查：

- P13A 自身存在且可执行。
- 输出低敏 JSON，包含 `ok=false`、`failures`、`current_evidence`、`baseline_reference`、`checked_files`、`rules`。
- 旧 003 / Step 4D 文档只能进入 `baseline_reference`，不得参与 `ok`。
- 检查当前缺少 search document / preview snapshot / OCR state 或等价类型。
- 检查当前 search / preview 主路径仍存在旧 redacted / visible filter / hardening 事实源风险。
- 检查 active Settings 仍存在 hardening/redacted 负向 token 或等价旧口径时失败。
- 检查 P13A 输出经过低敏 sanitizer，禁止输出真实 payload、完整 URL query、完整 `/Users/...` path、base64、OCR 全文、凭据类 token。
- 检查 Step 1 新增或 touched 文件不得引入 provider upload、新增权限、Authorization header、image upload、多模态 provider call、系统设置跳转或自动化动作；本批次新增的 P13A 脚本也必须遵守。

## 6. 必须运行

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
git diff --check
```

P13A 本批次预期输出应为低敏 `ok=false`。如果脚本无法执行、输出不低敏、或失败原因不是当前旧实现缺口，则本批次不能接受。

## 7. 回传要求

回传结论使用：

- `DONE`：P13A baseline red 已建立，输出低敏，开发记录完整。
- `DONE_WITH_CONCERNS`：P13A baseline red 已建立，但有非阻断残余风险。
- `BLOCKED`：脚本无法可靠建立 baseline red 或工作区状态冲突。

回传需列出：

- 改动文件。
- P13A 输出摘要。
- `git diff --check` 结果。
- P0/P1/P2 残余风险。
