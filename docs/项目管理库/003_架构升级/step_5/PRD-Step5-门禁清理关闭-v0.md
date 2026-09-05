# Step 5 门禁、清理与关闭 PRD v0

状态：prd-ready-for-parallel-review
日期：2026-07-06
来源级别：main agent PRD

## 1. 目标

Step 5 是本轮架构升级的最后实施阶段。目标不是继续做兼容式搬迁，而是在 Step 4 accepted 基线上彻底清理长期兼容层、旧 helper/debug 能力、未路由 legacy view、旧 verifier 假设和残余 P2 证据缺口。

Step 5 完成后项目状态写为 `step-5-accepted`。本项目不在 Step 5 直接写 `closed`；是否开启后续专项由 Step 5 最终接受记录判断。

## 2. 用户决策

- 清理强度：`极限清零`。
- 兼容定义：`Facade 也删`。
- 状态组合根：新增 `AppModel` / app environment，替代 `AppState`。
- 历史兼容：只允许一次性 migration；不得保留长期 fallback。
- Clipboard helper/debug：删除整个 `BlocksLoginItemHelper` target。
- 实物验收：真实 UI / TCC / VoiceOver / 多语言 / 窄宽度低敏证据为阻断项。
- TCC 验收：非破坏实测，不执行 `tccutil reset`，不改变系统授权状态。
- TCC 允许调用清单：只允许读取当前状态或运行 `script/build_and_run.sh --verify-permissions-existing`；不得点击 Request、不得触发 `CGRequestScreenCaptureAccess()` / `AXIsProcessTrustedWithOptions(prompt: true)`、不得通过自动粘贴路径制造权限 prompt。
- 证据产物：允许低敏截图进入 `step_5/evidence/`。
- 协作流程：PRD 后角色并行快速复审；开发后只对 P0/P1 或高风险边界补充复审。

## 3. 范围

### 3.1 必做

- 删除 `AppState.swift` 及所有 `@EnvironmentObject AppState` 调用。
- 新增 `AppModel` 作为组合根，只保留 app shell 状态、status、窗口打开、跨 feature coordinator 装配。
- View / pane 直接注入 feature store、coordinator 或显式 action closure，不通过 AppState computed facade 转发。
- 删除 `SettingsView` wrapper，调用点直接使用 `SettingsShellView`。
- 删除或重建 `ClipboardHistoryView`，不得默认显示 `record.summary` 或完整 payload。
- 删除整个 `BlocksLoginItemHelper` target、Embed LoginItems、helper entitlements 和 helper 源文件。
- 删除 App 内 Clipboard debug/preflight/watch/session/reset UI 与 `ClipboardRecorderRuntimeService`。
- 退役或重写依赖 helper、AppState、SettingsView wrapper、`clipboardPayload(for:)`、`record.summary` 默认 UI、旧归档阻断事实源的 verifier。
- 新增 `tools/verification/p12_step5_cleanup_checks.py`。
- 补齐低敏实物证据和最终验收记录。

### 3.2 明确不做

- 不启用 helper / App Group / CLI clipboard payload / OCR / provider call 新能力。
- 不执行 `tccutil reset`。
- 不读取、复制或提交真实剪贴板正文、真实窗口标题、完整路径、API key、Authorization、OCR/base64 或 provider raw response。
- 不把 Step 5 写成项目最终 `closed`。

## 4. 目标架构

### 4.1 AppModel

`AppModel` 是唯一 app composition root：

- owns：`selectedSection`、`status`、main window opener、feature stores、coordinators。
- coordinates：screenshot status、clipboard panel open/paste、permission refresh after paste retry、translation panel open。
- does not expose：feature store computed facades such as `clipboardRecords`、`permissionSnapshot`、`recentCaptures`、`shortcutRegistrationResults`、provider / translation profile lists.

Feature views use one of these patterns:

- direct store environment: `@EnvironmentObject var clipboardStore: ClipboardStore`
- direct model shell: `@EnvironmentObject var appModel: AppModel` only for navigation/status/window-level actions
- explicit closure: for cross-feature UI actions such as opening a window or triggering paste.

### 4.2 One-Shot Migration

Create a narrowly named migration component for old keys only. It may read:

- old clipboard panel bottom size key
- old shortcut option binding shape
- old Settings route / window sizing keys if still present

Rules:

- migration runs once during `AppModel` init.
- migration writes canonical key and deletes old key.
- old keys may only appear in the migration file and P12 allowlist.
- no runtime fallback to old keys after migration.

## 5. Deletion List

### 5.1 Helper / Debug

Delete:

- `apps/Blocks/BlocksLoginItemHelper/`
- `apps/Blocks/BlocksApp/Services/ClipboardRecorderRuntimeService.swift`
- App UI for recorder preflight, debug watch, App Group readiness, long session, reset.
- helper target, dependencies, product reference, Embed LoginItems phase and build settings in `project.pbxproj`.

Retire or rewrite:

- P4 helper recorder scripts.
- P3 helper embedded assertion.
- P4H App Group readiness helper assumption.
- Any verifier that requires `BlocksLoginItemHelper.app`.

### 5.2 Facade / Wrapper / Legacy

Delete or replace:

- `apps/Blocks/BlocksApp/Stores/AppState.swift`
- `apps/Blocks/BlocksApp/Views/SettingsView.swift`
- `@EnvironmentObject AppState`
- `SettingsView(`
- `func clipboardPayload(for:)`
- default UI display of `record.summary`
- long-lived `legacy` runtime branches except one-shot migration.

## 6. P12 门禁

`tools/verification/p12_step5_cleanup_checks.py` must fail closed when:

- `AppState.swift` exists or `AppState` is referenced in App code.
- `SettingsView.swift` exists or `SettingsView(` is referenced.
- `BlocksLoginItemHelper` target / source / entitlements / Embed LoginItems exists.
- `ClipboardRecorderRuntimeService` or recorder debug UI remains.
- `clipboardPayload(for:)` remains.
- `record.summary` appears in default UI.
- `legacy` / `compatibility` / old key references appear outside one-shot migration or allowed verifier baseline labels.
- P11A-E scripts are missing or do not report current evidence.
- old archive/story/acceptance paths participate in any `ok` decision.

P12 output must include checked files, deleted-target confirmation, migration allowlist, verifier-retirement summary and low-sensitive scan summary.

P12 must also confirm a fresh DerivedData build product has no `Contents/Library/LoginItems/BlocksLoginItemHelper.app` residue. Verification must not rely on a stale `DerivedData/Blocks` bundle from earlier helper stages.

## 7. 实物验收

Evidence directory: `docs/项目管理库/003_架构升级/step_5/evidence/`

Required low-sensitive evidence must conclude PASS to close the blocker. A screenshot or note that records a failed / overlapping / unreadable state cannot count as acceptance evidence.

Required low-sensitive evidence:

- Settings normal width and narrow width for at least `.all`, `.clipboard`, `.clipboardPrivacy`, `.shortcuts`, `.permissions` and `.providers`; remaining panes need navigation smoke notes.
- Settings three long-language samples or equivalent long-string rendering evidence.
- VoiceOver / keyboard reading order notes that confirm controls expose setting/action name, state and operation order.
- Clipboard redacted list, empty, filtered, unavailable / degraded states.
- Clipboard paste/copy/hover/translation explicit read UI feedback using fixture content only.
- Screenshot result copy/save/retake/close surface using low-sensitive capture only.
- Shortcut recorder record/cancel/pane close cleanup.
- Current non-destructive TCC status for Screen Recording and Accessibility.

Evidence must not contain real clipboard body, complete URL, complete file path, window title, API key, Authorization, OCR/base64 or provider response. TCC evidence may record granted/missing, bundle id, signature kind and low-sensitive team id; app paths and matching running paths must be redacted or omitted.

## 8. Verification Matrix

Required before Step 5 acceptance:

```bash
python3 tools/verification/p12_step5_cleanup_checks.py
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p11c_shortcut_store_checks.py
python3 tools/verification/p11d_settings_shell_split_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p3c_screenshot_checks.py
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py
python3 tools/verification/p3e_screenshot_result_polish_checks.py
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
python3 tools/verification/p10a_provider_translation_contract_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
rm -rf DerivedData/Step5
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Step5 build
test ! -e DerivedData/Step5/Build/Products/Debug/Blocks.app/Contents/Library/LoginItems/BlocksLoginItemHelper.app
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Step5 build
DerivedData/Step5/Build/Products/Debug/blocks --help
git diff --check
```

If a listed historical verifier is no longer meaningful after helper removal, it must be retired, replaced by P12 evidence, and documented in the development and acceptance records.

## 9. Role Flow

- App 架构师：review AppModel boundary, store injection and helper target removal.
- 安全合规：review helper removal, low-sensitive evidence, no new provider/Keychain/TCC/system-action expansion.
- UI/交互：review Settings/Clipboard/Screenshot/Shortcut evidence requirements.
- 测试/质量：review P12 and retired verifier matrix.

PRD review runs in parallel. Development review only repeats for P0/P1 or high-risk changes.

## 10. Acceptance

Step 5 can be accepted only when:

- PRD, development record, role reviews, QA acceptance and final acceptance record exist.
- P0/P1 are zero.
- P12 and current P11A-E pass.
- App and CLI build pass.
- Low-sensitive evidence exists and is referenced from acceptance record.
- `index.md` and `step.md` say `step-5-accepted`.
- Step 5 implementation is committed.
