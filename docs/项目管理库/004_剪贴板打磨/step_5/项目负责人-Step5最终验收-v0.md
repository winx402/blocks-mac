# Step 5 项目负责人最终验收 v0

状态：accepted-with-p2-residuals
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 5 隐私页真实 App 清单与 CLI 广义对象管理

## 1. 结论

结论：`accepted-with-p2-residuals`。

Step 5 已接受。R3 定向代码审查结论为 `approve`，P0/P1 清零。Step 5 可以结束，后续可按串行流程启动 Step 6 集成验收与收口。

本验收不代表 Step 6 已启动或完成；Step 6 必须单独回扫需求覆盖矩阵、阶段 residual 和跨阶段集成路径。

## 2. 最终复审输入

- `step_5/产品经理-PRD-v1.md`：Step 5 PRD 输入。
- `step_5/App架构师-技术方案-v1.md`：Step 5 技术方案输入。
- `step_5/项目负责人-Step5-R2验收-v0.md`：R2 项目负责人验收，结论 `development-rework-verified-pending-code-review`。
- `step_5/代码审查-Step5-R2复审-v0.md`：R2 代码审查，结论 `rework-required`，发现 1 个 P1。
- `step_5/项目负责人-Step5-R2复审收敛-v0.md`：接受 R2 代码审查结论并派发 R3。
- `step_5/开发记录-Step5-R3-v0.md`：R3 开发记录，结论 `DONE_WITH_EVIDENCE`。
- `step_5/项目负责人-Step5-R3验收-v0.md`：R3 项目负责人验收，结论 `development-rework-verified-pending-code-review`。
- `step_5/代码审查-Step5-R3复审-v0.md`：R3 代码审查，结论 `approve`。

## 3. 已关闭 P1

### 初始开发验收关闭

- P13E stdout evidence schema 与 required scenario id 对齐。
- 隐私页真实 App 清单、搜索/过滤/排序、icon fallback、低敏 evidence 的基础门禁进入可验收状态。

### R2 关闭

- 旧 `clipboard.policy.excludedBundleIDs` migration 进入 `privacy_policy_rules` restricted `bundle_id` 规则和 marker 路径。
- CLI typed subject 扩展到 `app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`。
- P13E 补充 Swift / CLI implementation evidence，降低假 PASS 风险。
- 隐私页 App icon provider 改为系统本地图标读取能力，失败有稳定 fallback。

### R3 关闭

- `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 已改为 `ON CONFLICT(subject_ref) DO NOTHING`，legacy migration 只补齐缺失 rule。
- 已有 current rule 的 `policy`、用户/agent intent 和更新时间不再被旧 `clipboard.policy.excludedBundleIDs` 覆盖。
- legacy-only bundle 仍会迁移为 `restricted`。
- P13E 新增 `privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004`，覆盖“已有 allowed rule + legacy old key + legacy-only bundle”场景。
- 正常 `applyPolicy` 的 explicit policy set conflict update 未被误伤。

## 4. 最终验证

项目负责人在 R3 验收中独立运行：

| 命令或验证项 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` + 独立 schema/id/evidence 解析 | PASS；`ok=true`，37 个场景，20 个必需 id 不缺失 |
| P13A / P13B / P13C / P13D | PASS |
| P11E | PASS |
| P9A / P9B | PASS |
| P8 / P8I | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS |
| `git diff --check` | PASS |

R3 代码审查额外复核：

- 静态阅读 R2/R3 文档、`PrivacyPolicyRepository.swift`、`Step5OneShotMigration.swift`、`p13e_clipboard_privacy_policy_checks.py`。
- 复跑 `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` 和 `git diff --check`。
- 结论为 `approve`，P0/P1 为 0。

## 5. 接受边界

本次接受不声称以下真实路径已完成：

- 真实 App UI 实物操作。
- 真实系统剪贴板。
- 真实 `/Applications`、`~/Applications`、`/System/Applications` 全量扫描实物验收。
- 真实 App icon 视觉截图。
- 真实 VoiceOver。
- 对真实用户数据库执行旧 key migration。
- provider、Keychain、TCC、System Settings、Finder、App launch 或系统状态变更。

这些未覆盖项在 Step 5 中作为 P2 residual 接受，Step 6 集成验收需要统一回扫并决定是否补低敏证据或继续记录为发布前待办。

## 6. P2 Residual

- P13E legacy conflict 覆盖是静态语义 + 合成场景，不是临时 SQLite repository 的运行时 migration harness；已足以关闭本轮 P1，但未来建议补低敏 temp DB fixture。
- 真实系统 App 清单和真实 icon 视觉未做实物截图。
- hidden app、unreadable app、损坏 app 等边界以 deterministic fixture 和 fallback 状态覆盖，未做真实文件系统异常枚举。
- CLI policy set confirm 路径未对真实用户数据库执行 mutation。
- 真实 VoiceOver / accessibility inspector 证据未覆盖。

## 7. 下一步

Step 5 已结束。按用户要求继续串行推进，下一步可启动 Step 6：集成验收与收口。Step 6 必须回扫 [需求覆盖矩阵 v0](../需求覆盖矩阵-v0.md)、各阶段 P2 residual 和旧事实源退出情况，确认需求没有丢失、遗漏或走偏。
