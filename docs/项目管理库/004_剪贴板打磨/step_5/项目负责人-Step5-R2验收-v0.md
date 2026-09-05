# 004_剪贴板打磨 Step 5 R2 项目负责人验收 v0

日期：2026-07-07

## 结论

结论：`development-rework-verified-pending-code-review`。

Step 5 R2 开发返工已完成项目负责人独立验收。本轮只验收代码审查确认的 4 个 P1：旧 exclusion migration、CLI typed subject 范围、P13E 实现级 fail-closed、真实 App icon provider。当前可以进入代码审查 R2 定向复审；代码审查完成并由项目负责人收敛前，不进入 Step 6，也不声明 Step 5 最终接受。

## 输入材料

- [代码审查 Step 5 开发复审 v0](代码审查-Step5开发复审-v0.md)
- [Step 5 开发复审收敛 v0](项目负责人-Step5开发复审收敛-v0.md)
- [Step 5 R2 开发派发 v0](项目负责人-开发派发-Step5-R2-v0.md)
- [Step 5 R2 开发记录 v0](开发记录-Step5-R2-v0.md)
- [Step 5 技术方案 v1](App架构师-技术方案-v1.md)
- [Step 5 PRD v1](产品经理-PRD-v1.md)

## 验收范围

本次只验收 R2 返工范围：

1. 旧 `clipboard.policy.excludedBundleIDs` 迁移到 `privacy_policy_rules` restricted `bundle_id`，marker 为 `privacy.policy.migratedExcludedBundleIDs.v1`。
2. CLI typed subject 扩展到 `app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`，默认低敏输出，不做真实系统枚举或系统动作。
3. P13E 从场景 id / schema 检查提升为包含 Swift / CLI 实现级 evidence 的 fail-closed gate。
4. 隐私页真实 App icon provider 使用系统本地图标读取能力，失败有稳定 fallback，不输出或持久化 icon binary。

不验收 Step 6，也不重新打开 Step 1-4 的产品范围。

## 独立验证

项目负责人本轮重新执行了以下验证，未直接采信开发记录中的 PASS：

| 验证项 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` + 独立 schema/id/evidence 解析 | PASS；`ok=true`、`failures=0`、36 个场景、19 个必需 id 不缺失，`implementation_evidence` 子项齐全，current evidence 指向 `开发记录-Step5-R2-v0.md` |
| P13A / P13B / P13C / P13D | PASS；均 `ok=true` |
| P11E | PASS；`ok=true` |
| P9A / P9B | PASS；均 `ok=true` |
| P8 / P8I | PASS；均 `ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；仅保留既有 AppIntents metadata warning。Xcode build 包含默认 LaunchServices 注册步骤，但未启动 App |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS；输出 privacy actions list |
| `git diff --check` | PASS |

## 抽查结论

- `Step5OneShotMigration` 中旧 exclusion migration 在 repository 写入成功后才写 marker；失败路径会清除 marker，避免假完成。
- `PrivacyPolicySubjectType` 已包含 7 类 subject；`PrivacySubjectResolver` 使用 `sub_v1_<type>_<hash20>` opaque ref。
- `PrivacyCLIService` 支持 typed subject resolve / policy set 的 explicit input、existing policy 和低敏 opaque ref 路径；`--include-sensitive-paths` 明确 unsupported，dangerous action 只返回 blocked evidence。
- `PrivacyStore.visibleApps` 搜索包含 `pathSummary`，并阻断 raw home path query 命中。
- `SystemAppIconProvider` 使用 `NSWorkspace.shared.icon(forFile:)` 读取本地 `.app` icon，使用 cache / failed state；`PrivacyAppRowView` 保持 fixed-size icon / fallback 布局。
- P13E stdout 已包含 `ui_interaction`、`capture_bridge`、`performance`、`implementation_evidence`，并覆盖 R2 新增 required id。

## 残余风险

- P2：本次仍未触发真实 App UI、真实系统剪贴板、真实 `/Applications` 全量扫描、真实 VoiceOver、provider、Keychain、TCC、System Settings、Finder 或 App launch。
- P2：真实 icon provider 通过代码路径、构建和 deterministic/static evidence 验证，未做真实系统 App 清单实物截图或图标视觉验收。
- P2：CLI policy set confirm 路径未对真实用户数据库执行 mutation；本轮保持 dry-run / 低敏 evidence / static implementation 验证。
- P2：hidden app、unreadable app 等边界仍以 deterministic fixture 和 fallback 状态覆盖，未做真实文件系统异常枚举。

## 下一步

派发代码审查做 Step 5 R2 定向复审。复审重点只看 R2 四个 P1 是否真正关闭、P13E 是否仍存在假 PASS、R2 是否引入新的 P0/P1 或越界系统动作。代码审查完成并由项目负责人收敛前，Step 5 不最终接受，Step 6 不启动。
