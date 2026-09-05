# Step 4B PermissionStore P1 修复开发记录 v0

状态：developed
日期：2026-07-06
来源级别：development record

## 1. 结论

开发结论：DONE。

已修复测试/质量独立验收提出的 P1：`tools/verification/p7r_permission_assist_ux_checks.py` 不再把旧归档 acceptance/story 文档作为阻断 checks 输入。P7R 的阻断证据已切换到 Step 4B 当前事实源：`PRD-Step4B-PermissionStore-v0.md` 和 `开发记录-Step4B-PermissionStore-v0.md`；当前验收记录只作为 availability / status observation 输出，不参与 `ok` 判定。旧归档未读取，未参与 `ok` 判定。

本次没有扩大产品实现范围，没有修改 App 运行时代码，没有触发真实权限请求、系统设置、Show in Finder 或 restart。

## 2. 修复文件

- `tools/verification/p7r_permission_assist_ux_checks.py`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-P1修复-v0.md`

## 3. 修复说明

- 移除 P7R 中旧归档 `ARCHIVE`、旧 acceptance、旧 story 的阻断依赖。
- 删除旧阻断 check：`acceptance_records_granted_state_and_limits`、`story_links_acceptance`。
- 新增当前事实源阻断 check：
  - `step4b_prd_records_ux_evidence_contract`
  - `step4b_development_record_records_ux_limits`
- 新增 `current_evidence` observation，记录当前 PRD、开发记录和验收记录可用性。
- 新增 `baseline_reference` observation，明确旧归档不读取、不参与 `ok` 判定。

## 4. 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p7r_permission_assist_ux_checks.py` | PASS |
| `python3 tools/verification/p11b_permission_store_checks.py` | PASS |
| `python3 tools/verification/p7k_permission_identity_gate_checks.py` | PASS |
| `git diff --check` | PASS |

补充验证：

- 已用最小红灯检查确认修复前 P7R 存在旧阻断 check 名称；修复后同一检查不再命中旧阻断 check 名称。
- P7R 输出包含 `baseline_reference.legacy_archive_used_for_ok = false`。
- P7R 输出包含 Step 4B 当前 PRD / 开发记录 evidence 路径。
- 最终验证按串行顺序运行，避免 P7R / P7K 同时处理同一个 stable app 带来的 existing-app TCC 检查竞态。

## 5. 未覆盖项 / 残余风险

- 本次只修复 P7R 事实源问题，未重新做 UI 实物验收。
- 未触发真实权限请求、系统设置、Show in Finder、restart、TCC reset、Screenshot 缺权真实路径或 Clipboard 全局 paste retry。
- `P7K` 仍会输出低敏签名摘要和 CDHash；路径与邮箱已脱敏，本次未扩大到进一步重写 signing 输出格式。

## 6. 安全隐私声明

- 本记录不包含真实用户主目录、完整本地路径、窗口标题、屏幕文本、选中文本、剪贴板正文、截图/base64/OCR 原文、真实凭据、Authorization header、完整 request body 或 provider raw response。
- 本次没有新增读取前台 UI 内容、抓取选中文本、发送键鼠事件、AppleScript、外部 CLI provider、provider call 或 secret 读写能力。
