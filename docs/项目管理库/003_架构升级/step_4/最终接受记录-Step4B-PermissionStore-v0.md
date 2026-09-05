# Step 4B PermissionStore 最终接受记录 v0

状态：accepted
日期：2026-07-06
来源级别：main agent acceptance record

## 1. 结论

Step 4B PermissionStore 单切片最终接受。

本次接受范围限于：

- `PermissionStore` 成为 `permissionSnapshot` 的 feature-level 事实源。
- `AppState.permissionSnapshot` 降为 computed facade。
- `AppState` 持有并桥接 `PermissionStore.objectWillChange`。
- 权限刷新后 Clipboard pending paste retry 仍留在 `AppState` / Clipboard 协调层。
- 系统权限动作集中到 `PermissionSystemActions.swift` 等白名单 adapter / 既有 presenter 路径。
- P11B PermissionStore 专项门禁和相关 P7 / P10 回归门禁通过。
- P7R 旧归档阻断事实源问题已修复并通过测试/质量补充复验。

本次不接受为已完成：

- ScreenshotStore。
- ShortcutStore。
- Settings shell split。
- Clipboard hardening。
- Fresh install / denied / revoked TCC 全矩阵。
- 真实点击 Request Screen Recording / Request Accessibility / Show in Finder / Restart Blocks / Screen Recording Settings。
- Settings Permissions 窄宽度、多语言长文本和 VoiceOver 实物验收。
- Screenshot 缺少 Screen Recording 的真实 revoked 路径。
- Clipboard 全局 paste retry 的真实系统级触发。

## 2. 输入材料

- `docs/项目管理库/003_架构升级/step_4/PRD-Step4B-PermissionStore-v0.md`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-v0.md`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-P1修复-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-App架构师Step4B实现复审-v0.md`
- `docs/项目管理库/003_架构升级/step_4/验收记录-Step4B-PermissionStore-v0.md`
- `docs/项目管理库/003_架构升级/step_4/验收记录-Step4B-PermissionStore-P1复验-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-安全合规Step4B实现复审-v0.md`

## 3. 角色结论

- App 架构师：`approve-for-acceptance`，P0/P1 为 0。
- 测试/质量初验：`changes-requested`，P1 为 P7R 旧归档事实源仍作为阻断输入。
- 测试/质量补充复验：`accepted-with-residual-risk`，原 P1 已关闭，未发现新增 P0/P1。
- 安全合规：`approve-for-acceptance`，P0/P1 为 0。

## 4. 已验证门禁

开发、测试/质量和主会话已覆盖以下门禁记录：

```bash
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p7e_permission_assist_flow_checks.py
python3 tools/verification/p7f_permission_state_refresh_checks.py
python3 tools/verification/p7f_permission_assist_position_drag_checks.py
python3 tools/verification/p7g_permission_settings_interaction_checks.py
python3 tools/verification/p7k_permission_identity_gate_checks.py
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

P1 修复后补充复验覆盖：

```bash
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p7k_permission_identity_gate_checks.py
git diff --check
```

`p7h_stable_signing_permission_identity_checks.py` 未作为本轮额外阻断门禁运行。原因：本轮未修改 signing、TCC identity、Info.plist、bundle ID、code signing 或 permission identity diagnostics 实现。

## 5. 安全与隐私接受边界

接受依据：

- 未写入真实凭据。
- 未读取真实 secrets。
- 未调用真实外部 provider。
- 未新增截图图片外发、OCR、前台 UI 内容读取、键鼠事件发送、AppleScript 或 shell 执行能力。
- 验证输出已对用户主目录、邮箱、TCC requirement 等做低敏处理。
- 权限请求、打开系统设置、Show in Finder 和 restart 未从 init、onAppear、timer、background refresh、objectWillChange 或 permission assist refresh callback 静默触发。

## 6. 残余风险

以下风险接受为 Step 4B 后续残余，不阻断本切片关闭：

- TCC 行为依赖签名、bundle path、历史授权状态和系统设置；fresh / denied / revoked 全矩阵仍需后续环境覆盖。
- 真实用户点击权限请求、系统设置、Show in Finder 和 restart 未在本轮自动化触发。
- Settings Permissions 的窄宽度、长路径、长 bundle ID、长 recommended action、三语言长句和 VoiceOver label 仍缺低敏实测证据。
- Screenshot 缺少 Screen Recording 的 revoked 权限路径仍未真实触发。
- Clipboard pending paste 的全局 Command+V retry 仍未真实触发。
- `PermissionStateService` 与部分 permission 类型仍留在 `PermissionAssistPanelPresenter.swift`。
- `AppState` 行数仍大；本切片只关闭权限事实源迁移，不关闭 AppState 全量瘦身。

## 7. 后续建议

- 下一切片不得默认扩大到多个 feature；继续按单切片 PRD、复审、提交、开发、验收、接受、提交的节奏推进。
- 若后续触碰真实 TCC 请求流程、截图 capture、Shortcut 自动化、外部 CLI、provider call、secret 或图片外发，必须重新触发安全合规复审。
- Settings shell、ScreenshotStore、ShortcutStore 和 Clipboard hardening 分别另立 PRD，不复用 Step 4B 的接受结论。
