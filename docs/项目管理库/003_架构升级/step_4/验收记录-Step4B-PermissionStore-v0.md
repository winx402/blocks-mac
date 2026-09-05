# Step 4B PermissionStore 测试/质量独立验收记录 v0

- 角色：测试/质量
- 日期：2026-07-06
- 结论：`changes-requested`
- 验收对象：Step 4B PermissionStore 单切片实现与门禁证据

## 1. 验收范围

本次验收覆盖：

- `PermissionStore` 是否成为 `permissionSnapshot` 事实源，并进入 Blocks app target。
- `AppState.permissionSnapshot` 是否为 computed facade，`AppState` 是否持有并桥接 `PermissionStore.objectWillChange`。
- `refreshPermissionState()` 后 Clipboard pending paste retry 是否仍留在 `AppState` / Clipboard 协调层，未迁入 `PermissionStore`。
- `PermissionSystemActioning` / adapter 边界、用户触发边界、P11B fail closed、旧 P7 / P10 当前事实源要求。
- Settings Permissions、Permission Assist、Screenshot permission missing path、Show in Finder、Restart、Screen Recording Settings 入口的静态/门禁回归证据。

本次未创建分支，未提交 commit，未读取或保存真实敏感凭据，未调用真实外部 provider，未主动触发真实权限请求、Show in Finder、Restart 或系统设置跳转。

## 2. 已读取事实源

- `AGENTS.md`
- `agents/测试-质量.md`
- `docs/项目管理库/003_架构升级/step_4/PRD-Step4B-PermissionStore-v0.md`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-05-App架构师Step4B方案复审-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-05-安全合规Step4B方案复审-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-05-测试质量Step4B方案复审-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-05-UI交互Step4B方案复审-v0.md`
- 相关实现与门禁脚本：`PermissionStore.swift`、`PermissionSystemActions.swift`、`AppState.swift`、`p11b_permission_store_checks.py`、P7/P10 相关 verification 脚本。

## 3. 已验证项

### 3.1 PermissionStore 与 App target

已验证：

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift` 存在。
- `PermissionStore` 为 `@MainActor final class PermissionStore: ObservableObject`，持有 `@Published private(set) var permissionSnapshot`。
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj` 包含 `PermissionStore.swift in Sources` 与 `PermissionSystemActions.swift in Sources`。
- P11B 输出确认 target membership 缺失项为空，permission feature files 为 `PermissionStore.swift` 与 `PermissionSystemActions.swift`。

### 3.2 AppState facade 与 objectWillChange

已验证：

- `AppState.permissionSnapshot` 为 computed facade，返回 `permissionStore.permissionSnapshot`。
- `AppState` 持有 `let permissionStore: PermissionStore`。
- `AppState` 通过 `permissionStore.objectWillChange` 转发到自身 `objectWillChange.send()`。
- P11B 未发现 `@Published var permissionSnapshot` 或 `PermissionStateService.snapshot()` 仍作为 AppState 直接事实源。

### 3.3 Clipboard retry 边界

已验证：

- `AppState.refreshPermissionState()` 调用顺序为先 `permissionStore.refreshPermissionState()`，后 `retryPendingClipboardPasteIfPossible()`。
- `requestScreenRecordingPermissionAssist()` / `requestAccessibilityPermissionAssist()` 的 after-refresh closure 由 `AppState` 调用 `retryPendingClipboardPasteIfPossible()`。
- `PermissionStore.swift` 未命中 P11B 的 Clipboard / pending paste / pasteboard 禁止 token。
- `retryPendingClipboardPasteIfPossible()` 仍在 `AppState` / Clipboard 协调层，未迁入 `PermissionStore`。

### 3.4 系统动作 adapter 与用户触发边界

已验证：

- `PermissionSystemActions.swift` 集中包含 `NSWorkspace.shared.open`、`activateFileViewerSelecting`、`openApplication` 和 `NSApp.terminate`。
- P11B 的 system action whitelist 允许位置仅包含 `PermissionSystemActions.swift` 与既有 `PermissionAssistPanelPresenter.swift`，本次输出无越界命中。
- P11B 覆盖 `PermissionStore.init`、`objectWillChange`、`onAppear`、timer、background 等非用户路径副作用扫描，未报告失败。

证据限制：

- `PermissionStore.requestScreenRecordingPermissionAssist` 与 `requestAccessibilityPermissionAssist` 方法本身会调用 request access；本次只通过静态门禁确认这些方法未出现在非用户路径中，未通过真实点击链路验证。

### 3.5 Settings / Permission Assist / Screenshot / CLI 回归

已验证：

- P7E 覆盖 Permission Assist flow、系统设置定位、隐藏 Blocks windows、自动关闭监控和本地化路径。
- P7F 覆盖权限 snapshot model、屏幕录制和辅助功能读取/请求路径、截图前刷新权限、didBecomeActive 刷新、Settings 诊断展示和重启引导本地化。
- P7F position/drag 覆盖 launch grace、flow timeout、callback refresh、箭头方向、相对系统设置窗口定位和拖拽隔离。
- P7G 覆盖 Settings permissions cards、request path、permission assist state machine、Clipboard paste feedback model 和相关本地化。
- P7K 覆盖 stable permission identity gate、无 destructive TCC reset、request path、fallback 和本地化。
- P7R 覆盖 existing TCC gate、Permission Assist 状态机、拖拽隔离、关闭条件、现有 TCC 已授权环境和本地化。
- Blocks app build、BlocksCLI build、`blocks --help` 均通过。

## 4. 命令结果

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p11b_permission_store_checks.py` | PASS，exit 0 | `ok: true`；target membership 缺失项为空；forbidden tokens、view forbidden tokens、system action whitelist 均无 hits。 |
| `python3 tools/verification/p7e_permission_assist_flow_checks.py` | PASS，exit 0 | `ok: true`；8 项 checks 全为 true。 |
| `python3 tools/verification/p7f_permission_state_refresh_checks.py` | PASS，exit 0 | `ok: true`；8 项 checks 全为 true。 |
| `python3 tools/verification/p7f_permission_assist_position_drag_checks.py` | PASS，exit 0 | `ok: true`；7 项 checks 全为 true。 |
| `python3 tools/verification/p7g_permission_settings_interaction_checks.py` | PASS，exit 0 | `ok: true`；failures 为空。 |
| `python3 tools/verification/p7k_permission_identity_gate_checks.py` | PASS，exit 0 | `ok: true`；`stable_verify.ok: true`；无 destructive TCC reset。输出含签名摘要，本文不复写完整签名 hash。 |
| `python3 tools/verification/p7r_permission_assist_ux_checks.py` | PASS，exit 0，但见 P1 | `ok: true`；existing TCC gate passed；ScreenCapture / Accessibility 现有 TCC 行为授权枚举为已授权。脚本仍依赖旧归档验收记录，见第 6 节。 |
| `python3 tools/verification/p10b_core_state_split_checks.py` | PASS，exit 0 | `ok: true`；failures 为空；作为 Step 3 regression guard。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS，exit 0 | 输出以 `BUILD SUCCEEDED` 结束；可见 warning：多 matching destinations、AppIntents metadata extraction skipped。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS，exit 0 | 输出以 `BUILD SUCCEEDED` 结束；可见 warning：多 matching destinations。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS，exit 0 | 输出 usage：`blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`。 |
| `git diff --check` | PASS，exit 0 | 无输出。 |

未运行：

- `python3 tools/verification/p7h_stable_signing_permission_identity_checks.py`

判断依据：本次 diff 中 project 文件只新增 `PermissionStore.swift` / `PermissionSystemActions.swift` target membership；未看到 `DEVELOPMENT_TEAM`、`CODE_SIGN`、`PRODUCT_BUNDLE_IDENTIFIER`、`INFOPLIST_FILE`、Info.plist、entitlement、bundle ID 或 permission identity diagnostics 实现变更。因此 P7H 未升级为本轮额外阻断门禁。

## 5. 未验证项与环境限制

以下项目未写成通过：

- 未真实点击 Request Screen Recording / Request Accessibility；未触发新的系统权限请求。
- 未真实点击 Show in Finder、Restart Blocks 或 Screen Recording Settings；这些系统动作只通过静态边界和按钮入口门禁验证。
- 未重置 TCC，未覆盖 fresh install、denied、revoked 全矩阵。
- 当前 P7R 只证明现有 TCC 环境下 Screen Recording / Accessibility 已授权路径，不证明首次授权弹窗或 revoked 后恢复路径。
- 未用低敏截图实测 Settings Permissions 页面、窄宽度、长 app path、长 bundle ID、长 recommended action、三语言长句和 VoiceOver label。
- 未真实触发 Screenshot 缺少 Screen Recording 的 revoked 权限路径；当前仅由代码路径和 P7F/P7G 静态门禁证明 `permissionMissing` 与辅助入口未被删除。
- 未真实触发 Clipboard pending paste 的全局 Command+V retry；当前由 P11B、P7G 和代码抽查证明 retry 仍在 AppState / Clipboard 协调层。

## 6. P0 / P1

P0：未发现。

P1：发现 1 项，属于质量门禁事实源问题。

### P1-1 P7R 仍把旧归档验收记录作为阻断检查输入

证据：

- `tools/verification/p7r_permission_assist_ux_checks.py` 仍定义 `ARCHIVE = ROOT / "docs/项目管理库/000_归档/2026-07-05_项目视图改造前"`。
- 同脚本仍读取：
  - `实施记录/acceptance/p7-r-permission-assist-acceptance-record.md`
  - `实施记录/stories/p7-r-permission-assist-validation.md`
- 同脚本的阻断 checks 仍包含 `acceptance_records_granted_state_and_limits` 与 `story_links_acceptance`，并依赖旧归档文本命中。

判断：

- 这不代表当前 `PermissionStore` runtime 实现失败；P7R 同时也检查了当前 `PermissionStore`、`PermissionSystemActions`、`AppState`、Settings 和 existing TCC。
- 但 PRD 第 7.2 / 第 9 节要求旧 P7 / P10 阻断门禁确认使用当前事实源；若仍依赖旧验收记录、旧路径或旧归档，只能作为 baseline 辅助证据。
- 因此，当前验收证据不足以支撑 Step 4B 最终接受，需先修正 P7R 的当前事实源问题，或将旧归档相关 checks 明确降级为非阻断 baseline，并补充 Step 4B 当前验收证据路径。

建议修复：

- 将 P7R 中旧归档验收记录依赖替换为 Step 4B 当前验收/开发证据路径；或
- 保留旧归档读取但只作为 `baseline_reference` 输出，不参与 `ok` 判定；并新增 Step 4B 当前证据检查；然后复跑 P7R 和完整 Step 4B 必跑门禁。

## 7. 残余风险

- P7K / P7R 输出会包含签名摘要和 TCC 枚举；脚本已脱敏用户主目录、邮箱和 TCC requirement，本文未复写完整签名 hash。后续建议进一步减少验证 JSON 中的签名 hash 明文。
- `PermissionStore.request...Assist` 方法本身具备请求权限副作用；当前安全性依赖调用方只从用户动作进入，已由 P11B 静态扫描覆盖，但未做真实 UI 点击链路验证。
- Permission Assist 的 opening、waiting、guiding、checking、granted、failed、cancelled、timedOut 状态未在本轮逐一实物触达。
- Settings shell、ScreenshotStore、ShortcutStore 仍未拆；这是 Step 4B 非目标，不作为本轮阻断。
- App build 存在既有 Xcode warning：多 matching destinations、AppIntents metadata extraction skipped；未导致构建失败，本轮未判定为 Step 4B P1。

## 8. 最终建议

不建议当前直接进入主 agent 最终接受。建议先处理 P1-1，复跑至少：

```bash
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p7k_permission_identity_gate_checks.py
git diff --check
```

若 P7R 当前事实源修正后仍通过，且没有新增代码改动扩大范围，再由测试/质量更新验收记录或出具补充验收结论。
