# Step 5 开发派发

日期：2026-07-07
角色：项目负责人
对象：`004_剪贴板打磨` Step 5：隐私页真实 App 清单与 CLI 广义对象管理
状态：dispatched-to-development

## 1. 任务目标

按 Step 5 PRD v1 和 App 架构师技术方案 v1，实现隐私页真实 App 清单、UI policy mutation、CLI typed subject 管理、capture policy 接入和 P13E fail-closed 门禁。

本次按一个较大 Step 5 开发批次推进。开发可以在内部按 P13E baseline、Core model/scanner、UI policy、capture bridge、CLI、回归门禁组织提交顺序，但对项目负责人交付时必须形成完整 Step 5 开发记录与证据。

## 2. 主要输入

- [产品经理 PRD v1](产品经理-PRD-v1.md)
- [项目负责人 PRD 最终接受 v0](项目负责人-PRD最终接受-v0.md)
- [App 架构师技术方案 v1](App架构师-技术方案-v1.md)
- [项目负责人技术方案最终接受 v0](项目负责人-技术方案最终接受-v0.md)
- [测试/质量技术方案 v1 定向复审 v0](测试-质量-技术方案-v1定向复审-v0.md)

## 3. 开发范围

必须实现：

- `PrivacyAppInstance` / `PrivacyPolicySubject` / `PrivacyPolicyRule` / `PrivacyPolicySnapshot` 等 Step 5 模型。
- `PrivacyPolicyRepository` 作为 UI 与 CLI 共享的单一 policy fact source。
- 三 root synthetic-testable scanner：`/Applications`、`~/Applications`、`/System/Applications`；`.app` bundle 是扫描叶子。
- App 侧 icon provider 与 in-memory cache，图标失败有 fallback。
- 隐私页 App list、search/filter/sort、row layout、policy menu、duplicate confirmation、pending/saving/saved/failed/retry/cancel。
- 旧 `ClipboardPrivacyExclusionList` / `excludedBundleIDs` active UI 和 active fact source 退出；旧值一次性迁移为 restricted bundle id policy rule。
- `ClipboardCapturePolicy` 消费 `PrivacyPolicySnapshot`，支持 bundle id 与 app path allow/restricted、precedence、default allow、missing path fallback。
- `blocks privacy ...` CLI typed subject / policy get/set / dry-run / confirm / low-sensitive JSON output / dangerous action hard-block。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py` 或等价 P13E hard gate。
- target membership、build、CLI help 与相关回归门禁。

明确不实现：

- Step 6 集成回扫。
- 真实 provider、Keychain、TCC、System Settings、Finder、App launch、命令执行、系统登记源扫描。
- CLI 首版不实现 `--include-sensitive-paths`。
- login item / helper / launch label 首版不做系统枚举，只支持 explicit input / existing policy / synthetic fixture。
- 不重做 Step 1-4 的搜索、标签、面板布局、详情编辑。

## 4. P13E hard gate

P13E 必须是 Step 5 的第一门禁。缺实现时应 red；完成后必须 pass。

P13E required scenarios 至少包含技术方案 v1 第 9.4 节的全部场景，尤其必须包含：

- UI interaction / layout：
  - `privacy_app_search_fields_004`
  - `privacy_app_filter_combination_004`
  - `privacy_app_sort_stability_004`
  - `privacy_app_row_a11y_004`
  - `privacy_app_narrow_width_004`
  - `privacy_app_long_text_i18n_004`
- Capture bridge：
  - `privacy_capture_bundle_restricted_004`
  - `privacy_capture_bundle_allowed_004`
  - `privacy_capture_app_path_precedence_004`
  - `privacy_capture_default_allow_004`
  - `privacy_capture_missing_path_fallback_004`
  - `privacy_capture_snapshot_low_sensitive_004`

`ui_interaction` 与 `capture_bridge` 的 required scenarios 不得降级为 optional、baseline_reference 或只读 token scan；任一缺失必须 `ok=false`。

P13E 必须做值级断言：

- capture bridge：`decision`、`matched_rule_type`、`mutation_performed=false`、`payload_read=false`、`path_redacted=true`。
- UI search：raw home path query must not match。
- UI sort：icon async 后排序不变。
- legacy exit：旧 `excludedBundleIDs` / `excludedBundleIdentifiers` 不是 active fact source。

## 5. 低敏与系统边界

开发和验证默认禁止：

- 真实 App 启动。
- 真实剪贴板读写。
- provider 调用。
- Keychain、TCC、System Settings、Finder、App launch、command execution。
- 真实系统状态变更。

P13E 使用 synthetic temp roots，不读取真实 `/Applications`。输出默认低敏：

- 不输出完整真实路径、完整 home path、窗口标题、剪贴板 payload、base64 image、provider secret、凭据、API key、私钥、验证码。
- list-like evidence 只输出 counts / hashes / summaries。
- sample 不超过 20 rows。
- P13E stdout 不超过技术方案 v1 约定阈值。

## 6. 验收命令与证据

开发记录必须至少包含：

- P13E baseline red / green 证据。
- P13E stdout summary，含 `ui_interaction`、`capture_bridge`、`performance`。
- 回归门禁：
  - P13A
  - P13B
  - P13C
  - P13D
  - P11E
  - P9A
  - P9B
  - P8
  - P8I
- Blocks App build。
- BlocksCLI build。
- CLI help。
- `git diff --check`。

开发记录必须写入：

- `/Users/bot/Documents/Mac 工具集/docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-v0.md`

## 7. 接受标准

项目负责人验收前必须满足：

- Step 5 PRD v1 的三 root UI、policy mutation、CLI typed subject、dangerous action hard-block、低敏输出均有实现和证据。
- P13E PASS 且不可被其他门禁替代。
- 旧隐私排除 UI / old excluded bundle fact source 退出有证据。
- capture policy 对新 snapshot 生效有证据。
- 代码没有把真实系统操作带入默认验证路径。
- 开发记录能让代码审查、测试/质量、安全合规和 UI/交互按需复审。
