# Step 4 Feature 模块迁移最终接受记录 v0

状态：accepted-with-residual-risk
日期：2026-07-06
来源级别：main agent acceptance record

## 1. 结论

主 agent 最终接受 Step 4 Feature 模块迁移。

Step 4 已完成并接受的范围包括：

- Step 4B PermissionStore。
- Step 4C core：ScreenshotStore、ShortcutStore、Settings shell split。
- Step 4D Clipboard hardening。

Step 4A 预初始化 / rebaseline、Step 4C-4 go/no-go 和 Step 4D handoff 均已作为阶段管理产物归档。Clipboard hardening 未在 Step 4C 内强行继续，而是按 App 架构师和测试/质量意见拆为 Step 4D 独立完成。

## 2. 接受依据

Step 4B PermissionStore：

- 主会最终接受记录：`最终接受记录-Step4B-PermissionStore-v0.md`
- 结论：`accepted`
- 关键事实：`PermissionStore` 成为 `permissionSnapshot` 的 feature-level 事实源，P11B / P7 / P10 回归门禁通过，P7R 旧归档阻断事实源 P1 已关闭。

Step 4C core：

- 主会最终接受记录：`最终接受记录-Step4C-Core-v0.md`
- 结论：`accepted-core`
- 关键事实：ScreenshotStore、ShortcutStore、Settings shell split 三个子批次均完成开发、角色复审、测试/质量验收和主会 Stop/Go；Clipboard hardening 明确不在 Step 4C 内接受。

Step 4D Clipboard hardening：

- 主会最终接受记录：`最终接受记录-Step4D-ClipboardHardening-v0.md`
- 结论：`accepted-with-residual-risk`
- 关键事实：默认 read model 收敛为 metadata-first / redacted-first；完整 payload read 仅允许四个 explicit purpose；purpose-keyed cache、historical pinned `displayName` preview/search、filtered search P1 均已关闭；P11E / P8 / P8I / P9A / P9B / P9C / build / CLI help / diff check 均通过。

## 3. 已完成的架构迁移

- `PermissionStore`：权限 snapshot 事实源从 `AppState` 迁出，系统动作集中到白名单 adapter / 既有 presenter 路径。
- `ScreenshotStore`：截图 facts / actions 事实源迁出，`AppState` 保留 facade / coordinator，result view 通过窄 routeResolver 做 preview-only AI route。
- `ShortcutStore`：快捷键注册结果、绑定配置、诊断计数和快捷键 facade 迁出，动作注入限制为声明闭包。
- Settings shell：`SettingsView` 退化为 wrapper，`SettingsShellView` 和 feature pane 承接主体，全量 mode mapping 保持。
- Clipboard hardening：默认 repository / UI / Settings / DataAudit / CLI 不读完整 payload，完整 payload read 改为 explicit purpose allowlist。

## 4. 已建立或强化的门禁

- P11A：ScreenshotStore boundary。
- P11B：PermissionStore boundary。
- P11C：ShortcutStore boundary。
- P11D：Settings shell split。
- P11E：Clipboard hardening read model。
- 相关 P3 / P6 / P7 / P8 / P9 / P10 门禁已按对应切片迁移当前事实源；旧 story / archive / acceptance 不作为阻断 `ok` 输入。

## 5. 最终验证

Step 4D 主会最终串行复跑并通过：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

Step 4B 与 Step 4C 的验证命令见各自最终接受记录。本记录不重复重跑已提交切片的重型历史矩阵。

## 6. 未关闭的跨阶段残余风险

以下内容不阻断 Step 4 接受，但必须进入 Step 5 或后续专项：

- 真实 UI / VoiceOver / 多语言 / 窄宽度实物验收仍不足，尤其 Settings、Clipboard panel、Shortcut recorder、Screenshot result。
- 真实 TCC fresh / denied / revoked 矩阵仍未全覆盖。
- 真实截图 region / window / fullscreen、copy/save/retake/close 仍缺完整低敏实物验收。
- 真实快捷键冲突、OSStatus、recording cancel / pane switch / close cleanup 仍缺实测。
- Clipboard 真实 paste / copy / hover detail / translation preview 未触发，只由静态门禁和构建证明结构边界。
- 既有 `FloatingPanelSupport.swift` MainActor / NSApp warning 与 AppIntents metadata skipped warning 仍存在，但未阻断本轮构建。
- Blocks App build 出现 `AppState.swift` unused `record` warning，未阻断本轮构建。
- `AppState` 已被多轮切片瘦身，但仍不是最终理想状态；Step 5 可继续清理 facade 和 legacy helper。

## 7. 下一阶段建议

Step 5 建议目标：

- 清理旧路径、旧 helper、未路由 view 和临时兼容层。
- 为 P11A-E 增强低敏输出、current fact source 和 cache lifecycle 摘要。
- 以低敏 fixture 补齐真实 UI / TCC / VoiceOver / 多语言 / 窄宽度证据。
- 收敛 `AppState` 剩余 facade 和 Settings pane 对跨 feature 的依赖。
- 复盘角色协作流程，固化 PRD、开发、验收、提交的节奏。
