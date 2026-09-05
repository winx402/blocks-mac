# Step 4B PermissionStore P1 修复补充复验记录 v0

- 角色：测试/质量
- 日期：2026-07-06
- 结论：`accepted-with-residual-risk`
- 复验对象：Step 4B PermissionStore 测试 P1 修复

## 1. 复验范围

本次只复验上一版验收记录中的 P1：

- `tools/verification/p7r_permission_assist_ux_checks.py` 不应再把 `docs/项目管理库/000_归档/2026-07-05_项目视图改造前` 下旧 acceptance / story 文档作为阻断 checks 输入。
- P7R 应改用 Step 4B 当前事实源作为阻断证据。
- `legacy_archive_used_for_ok` 应为 `false`。
- P11B、P7K 和 `git diff --check` 不应因 P1 修复回归。

本次未修改业务代码，未创建分支，未提交 commit，未读取或保存真实敏感凭据，未调用真实外部 provider，未主动触发真实权限请求、系统设置、Show in Finder 或 restart。

## 2. 新增 / 更新事实源

已读取：

- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-P1修复-v0.md`
- `tools/verification/p7r_permission_assist_ux_checks.py`

静态确认：

- P7R 当前脚本未定义 `ARCHIVE`，未出现 `000_归档` 路径。
- P7R 当前脚本不再包含旧阻断 check：`acceptance_records_granted_state_and_limits`、`story_links_acceptance`。
- P7R 当前脚本包含当前事实源阻断 check：`step4b_prd_records_ux_evidence_contract`、`step4b_development_record_records_ux_limits`。
- P7R 输出包含 `current_evidence` 与 `baseline_reference`，且 `baseline_reference.legacy_archive_used_for_ok` 固定为 `false`。

## 3. 独立复验命令结果

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p7r_permission_assist_ux_checks.py` | PASS，exit 0 | `ok: true`；failures 为空；`legacy_archive_used_for_ok: false`；`current_evidence.prd` 指向 Step 4B PRD；`current_evidence.development_record` 指向 Step 4B 开发记录；新增两个当前事实源 checks 均为 true。 |
| `python3 tools/verification/p11b_permission_store_checks.py` | PASS，exit 0 | `ok: true`；target membership 缺失项为空；PermissionStore forbidden tokens、view forbidden tokens、system action whitelist 均无 hits。 |
| `python3 tools/verification/p7k_permission_identity_gate_checks.py` | PASS，exit 0 | `ok: true`；`no_destructive_tcc_reset: true`；`stable_verify.ok: true`。输出含脱敏签名摘要，本文不复写完整签名 hash。 |
| `git diff --check` | PASS，exit 0 | 无输出。 |

未补跑原 Step 4B 全量门禁。判断依据：本次 P1 修复只触及 P7R 验证脚本和 P1 修复开发记录；补充复验已覆盖 P7R 当前事实源、P11B PermissionStore 边界、P7K 权限身份门禁和 diff 格式。上一轮全量 Step 4B 门禁已通过，唯一阻断项就是 P7R 旧归档事实源问题。

## 4. P1 关闭判断

P1-1 状态：已关闭。

证据：

- P7R 当前脚本不再读取旧归档 acceptance / story 作为阻断输入。
- P7R 当前阻断 checks 使用 Step 4B PRD 与 Step 4B 开发记录。
- P7R 本轮输出明确 `baseline_reference.legacy_archive_used_for_ok = false`。
- P7R 本轮 `ok: true` 且 failures 为空。
- P11B / P7K / `git diff --check` 未出现因修复引入的新失败。

P0：未发现。

P1：未发现新增 P1。

## 5. 仍未覆盖 / 环境限制

以下风险仍存在，但本轮判断为残余风险，不阻断 Step 4B：

- 未真实点击 Request Screen Recording / Request Accessibility；未触发新的系统权限请求。
- 未真实点击 Show in Finder、Restart Blocks 或 Screen Recording Settings。
- 未重置 TCC，未覆盖 fresh install、denied、revoked 全矩阵。
- P7R 仍只证明现有 TCC 环境下 Screen Recording / Accessibility 已授权路径，不证明首次授权弹窗或 revoked 后恢复路径。
- 未用低敏截图实测 Settings Permissions 页面、窄宽度、长路径、长 bundle ID、长 recommended action、三语言长句和 VoiceOver label。
- 未真实触发 Screenshot 缺少 Screen Recording 的 revoked 权限路径。
- 未真实触发 Clipboard pending paste 的全局 Command+V retry。

## 6. 最终建议

建议主 agent 可将 Step 4B PermissionStore 从测试/质量视角推进到最终接受流程，但最终接受时应保留上述真实 TCC / UI 实物场景的环境限制。测试/质量不替主 agent 接受残余风险。
