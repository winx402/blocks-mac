# Step 4B PermissionStore 开发记录 v0

状态：developed
日期：2026-07-06
来源级别：development record

## 1. 结论

开发结论：DONE。

已按 `PRD-Step4B-PermissionStore-v0.md` 实施 PermissionStore 单切片。`PermissionStore` 已成为 `permissionSnapshot` 的唯一事实源，进入 Blocks app target；`AppState.permissionSnapshot` 已改为 computed facade，原有 public facade 继续保留；`refreshPermissionState()` 仍在刷新权限 store 后触发 `retryPendingClipboardPasteIfPossible()`，Clipboard retry 未迁入 PermissionStore。

本次没有创建分支，没有提交 commit，没有写入真实凭据，没有读取真实 secrets，没有调用真实外部 provider，没有自动触发系统权限请求、系统设置、Show in Finder 或重启。

## 2. 实际改动文件

### 新增

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift`
- `tools/verification/p11b_permission_store_checks.py`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-v0.md`

### 修改

- `apps/Blocks/BlocksApp/Stores/AppState.swift`
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
- `tools/verification/p7e_permission_assist_flow_checks.py`
- `tools/verification/p7f_permission_state_refresh_checks.py`
- `tools/verification/p7g_permission_settings_interaction_checks.py`
- `tools/verification/p7k_permission_identity_gate_checks.py`
- `tools/verification/p7r_permission_assist_ux_checks.py`

说明：工作区中已有 Step 3 和文档改动，本记录只覆盖 Step 4B 本次开发触碰范围。

## 3. 关键实现决策

- `PermissionStore` 是 `@MainActor final class PermissionStore: ObservableObject`，发布 `permissionSnapshot`，并通过窄协议接收 snapshot provider、access requester、assist presenter 和 system actions。
- `PermissionStore` 不持有 `AppState`、`ProviderStore`、`TranslationStore`、`ScreenshotStore` 或 `ShortcutStore`，不包含 Clipboard retry、pending paste、pasteboard 或 provider / secret token。
- `PermissionSystemActions.swift` 是本切片唯一新增的系统动作 adapter，集中承接打开 Screen Recording 设置、Show in Finder 和 restart。`PermissionStore` 只调用协议，不直接出现系统动作 token。
- `AppState` 持有 `let permissionStore: PermissionStore` 并绑定 `permissionStore.objectWillChange`。Settings / Screenshot Home 继续通过 AppState facade，不拆 Settings shell，不创建 ScreenshotStore / ShortcutStore。
- Permission Assist 的用户触发入口通过 `PermissionStore.requestScreenRecordingPermissionAssist` / `requestAccessibilityPermissionAssist` 进入；assist flow 结束后 store 刷新 snapshot，再由 AppState facade 触发 Clipboard retry。
- P7E/P7F/P7G/P7K/P7R 已从旧 AppState 直接请求事实源更新为当前 PermissionStore / adapter / AppState facade 事实源。P7K/P7R 输出已做路径、邮箱和 TCC requirement 低敏处理。

## 4. 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p11b_permission_store_checks.py` | PASS |
| `python3 tools/verification/p7e_permission_assist_flow_checks.py` | PASS |
| `python3 tools/verification/p7f_permission_state_refresh_checks.py` | PASS |
| `python3 tools/verification/p7f_permission_assist_position_drag_checks.py` | PASS |
| `python3 tools/verification/p7g_permission_settings_interaction_checks.py` | PASS |
| `python3 tools/verification/p7k_permission_identity_gate_checks.py` | PASS |
| `python3 tools/verification/p7r_permission_assist_ux_checks.py` | PASS |
| `python3 tools/verification/p10b_core_state_split_checks.py` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS |
| `git diff --check` | PASS |

补充说明：

- P11B 先在旧结构下按预期失败，随后在实现后通过；当前输出包含检查文件、target membership 来源、规则命中 / 未命中摘要。
- P10B 是 Step 3 regression guard，不作为 PermissionStore acceptance 替代。
- Blocks app build 有既有 `FloatingPanelSupport.swift` main actor isolation warning，以及 AppIntents metadata extraction skipped warning；未导致 build 失败。本切片未修改该文件。
- 未运行 `p7h_stable_signing_permission_identity_checks.py`，原因：本切片未修改 signing、TCC identity、Info.plist、bundle ID、code signing 或 permission identity 诊断实现。

## 5. 实物验收证据

已覆盖的低敏证据：

- P7K stable permission verify mode 通过，确认当前 stable signing / permission identity gate 没有因 PermissionStore 迁移失效。
- P7R existing TCC mode 通过，确认现有 Screen Recording / Accessibility 已授权环境下 Permission Assist UX gate 仍满足已有验收基线；脚本输出仅保留 bundle id、授权枚举和低敏摘要，TCC requirement 已脱敏。
- P7F 确认 `startScreenshot(mode:)` 前仍调用权限刷新，并检查 Screen Recording snapshot。
- P7G 确认 Settings Permissions 仍暴露权限诊断和用户触发动作入口。
- P11B 确认 `PermissionStore` 不处理 Clipboard retry，AppState refresh facade 保留 retry 顺序。

受限 / 未覆盖：

- 未自动打开 Settings Permissions 页面，未做窄宽度 / 三语言长句 / VoiceOver 实机检查；这些需要测试/质量在独立验收中以低敏截图或文字记录覆盖。
- 未自动点击 Request Screen Recording、Request Accessibility、Show in Finder 或 Restart Blocks；这些都是真实用户触发动作，开发阶段未代替用户触发。
- 未重置 TCC，未覆盖 fresh install、denied、revoked 全矩阵。
- 未真实触发 Screenshot 缺少 Screen Recording 的弹窗路径；当前环境权限状态不适合作为 revoked/fresh 权限证据。
- 未真实触发 Clipboard pending paste 全局 Command+V retry；自动化和代码检查已证明 retry 仍在 AppState / Clipboard 协调层。

## 6. 敏感数据处理声明

- 本次开发记录不包含真实用户主目录、完整本地路径、完整窗口标题、屏幕文本、选中文本、剪贴板正文、真实截图图片、base64、OCR 原文、真实凭据、secret hash、Authorization header、完整 request body 或 provider raw response。
- P7K / P7R 验证脚本已对路径、邮箱和 TCC raw requirement 做脱敏处理。
- 未新增读取前台 UI 内容、抓取选中文本、发送键鼠事件、AppleScript、外部 CLI provider、provider call 或 secret 读写能力。

## 7. 残余风险

- `PermissionStateService` 和 permission snapshot 类型仍留在 `PermissionAssistPanelPresenter.swift`，文件仍偏大；按 PRD 这是可接受残余，没有在本切片重写 presenter 状态机。
- Settings shell 未拆，Settings Permissions 仍通过 AppState facade 读取。
- ScreenshotStore / ShortcutStore 未创建；截图 capture 和结果展示仍由 AppState 协调。
- 真实 TCC 行为受签名、bundle path、历史授权状态和系统设置影响，仍需测试/质量独立验收逐项标记覆盖与未覆盖。
- AppState 行数不会显著下降；本切片目标是权限事实源迁移，不是 AppState 全量瘦身。

## 8. 阻塞项

无。
