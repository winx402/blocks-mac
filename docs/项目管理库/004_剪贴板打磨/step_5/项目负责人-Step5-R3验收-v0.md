# 004_剪贴板打磨 Step 5 R3 项目负责人验收 v0

日期：2026-07-07

## 结论

结论：`development-rework-verified-pending-code-review`。

Step 5 R3 定向返工已通过项目负责人独立验收。本轮只验收 R2 代码审查发现的 1 个 P1：legacy excluded bundle migration 在 `subject_ref` 冲突时不得覆盖已有 current policy rule，且 P13E 必须覆盖该冲突分支。

当前可以进入代码审查 R3 定向复审。代码审查完成并由项目负责人收敛前，Step 5 不最终接受，Step 6 不启动。

## 输入材料

- [Step 5 R2 代码审查复审 v0](代码审查-Step5-R2复审-v0.md)
- [Step 5 R2 复审收敛 v0](项目负责人-Step5-R2复审收敛-v0.md)
- [Step 5 R3 开发派发 v0](项目负责人-开发派发-Step5-R3-v0.md)
- [Step 5 R3 开发记录 v0](开发记录-Step5-R3-v0.md)
- [Step 5 技术方案 v1](App架构师-技术方案-v1.md)
- [Step 5 PRD v1](产品经理-PRD-v1.md)

## 验收范围

本次只验收 R3 返工范围：

1. `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 的 legacy migration conflict strategy。
2. P13E legacy conflict 场景与 implementation evidence。
3. R3 是否引入新的 P0/P1、验证假 PASS 或越界系统动作。

不重新验收 Step 1-4，不进入 Step 6，也不扩大到隐私页真实 UI 实物验收。

## 独立验证

项目负责人本轮重新执行了验证，未直接采信开发记录中的 PASS。

| 验证项 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` + 独立 schema/id/evidence 解析 | PASS；`ok=true`、`failures=0`、37 个场景、20 个必需 id 不缺失，`legacy_conflict_preserves_existing_policy=true`，current evidence 指向 `开发记录-Step5-R3-v0.md` 和 `项目负责人-开发派发-Step5-R3-v0.md` |
| P13A / P13B / P13C / P13D | PASS；均 `ok=true` |
| P11E | PASS；`ok=true` |
| P9A / P9B | PASS；均 `ok=true` |
| P8 / P8I | PASS；均 `ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；`** BUILD SUCCEEDED **`。Xcode build 包含默认 LaunchServices / execution-policy 注册输出，但未启动 App |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；`** BUILD SUCCEEDED **` |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS；输出 privacy actions list |
| `git diff --check` | PASS |

## 抽查结论

- `migrateLegacyRestrictedBundleIDs` 已从 legacy conflict update 改为 `ON CONFLICT(subject_ref) DO NOTHING`，legacy migration 只补齐缺失 rule。
- 已存在 current rule 的 `policy`、用户/agent intent 和更新时间不再被旧 `clipboard.policy.excludedBundleIDs` 覆盖。
- legacy-only bundle 仍会迁移为 `restricted`。
- P13E 新增 `privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004`，覆盖“已有 allowed rule + legacy old key + legacy-only bundle”场景。
- P13E implementation evidence 已将 migration 函数体与正常 `applyPolicy` conflict update 区分，避免误伤正常 policy set 路径。

## 残余风险

- P0：无。
- P1：无已知残留，等待代码审查 R3 定向复审确认。
- P2：本轮没有对真实用户数据库执行旧 key migration；验证使用 deterministic/static evidence。
- P2：真实 App UI、真实系统剪贴板、真实 `/Applications` 全量扫描、真实 icon 视觉、真实 VoiceOver、provider、Keychain、TCC、System Settings、Finder 和 App launch 仍未覆盖。
- P2：开发记录中个别验证表述仍保留“待最终 current evidence 指向 R3 后复跑”的过程性描述；项目负责人已独立复跑并确认 current evidence 指向 R3，不作为阻塞。

## 下一步

派发代码审查做 Step 5 R3 定向复审。复审重点只看 legacy migration conflict P1 是否真正关闭、P13E 是否可 fail-closed 捕获回归、R3 是否引入新的 P0/P1 或越界系统动作。代码审查完成并由项目负责人收敛前，Step 5 不最终接受，Step 6 不启动。
