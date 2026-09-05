# Step 5 门禁、清理与关闭开发记录 v0

结论：`implemented`

## 改动范围

- 新增 `AppModel` 作为组合根，删除 `AppState.swift`。`AppModel` 保留 shell 状态、窗口打开、status 发布和跨 feature coordinator 装配；feature facts/actions 由 `ClipboardStore`、`ProviderStore`、`TranslationStore`、`PermissionStore`、`ScreenshotStore`、`ShortcutStore` 直接注入视图。
- 新增 `Step5OneShotMigration`，只迁移旧窗口尺寸 key、旧快捷键形态和旧 marker，并删除旧 key；运行入口在 `AppModel.init()`。
- 删除 `SettingsView` wrapper；`BlocksApp` Settings scene 和 `ContentView` 直接使用 `SettingsShellView(mode:)`。
- 删除 `ClipboardHistoryView`、`ClipboardRecorderRuntimeService`、`BlocksLoginItemHelper` target/source/entitlements 和 Embed LoginItems。
- 删除 App 内 Clipboard recorder debug/preflight/watch/session/reset UI 及相关 localization keys。
- 收紧 Clipboard 默认 read model：默认 list/card/tray/settings/data audit 不读取 payload；hover detail 改为 direct `ClipboardStore.readPayload(..., purpose: .hoverDetail)`；payload cache 继续按 `(recordID, purpose)` 分区。
- 更新 P11A/B/C/D/E、P12、P3C/P3F、P5M、P6A/B/C、P7B/C/D/F/R、P8/P8i、P9B/P9C、P10B 等脚本到 Step 5 当前事实源。
- P4 helper/debug 历史 verifier 统一退役为 Step 5 cleanup guard；当前阻断证据由 P8/P9/P11E/P12 承担。
- 更新 README 和技术知识库当前边界，避免把 helper/debug/AppState wrapper 写成现行能力。

## 验证结果

以下命令均已运行并 PASS：

```bash
python3 tools/verification/p12_step5_cleanup_checks.py
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p11c_shortcut_store_checks.py
python3 tools/verification/p11d_settings_shell_split_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p3c_screenshot_checks.py --timeout 180
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py --timeout 180
python3 tools/verification/p3e_screenshot_result_polish_checks.py --timeout 180
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py --timeout 180
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py
python3 tools/verification/p7b_settings_sidebar_stability_checks.py
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py
python3 tools/verification/p7e_settings_visual_scroll_checks.py
python3 tools/verification/p7f_settings_menu_dedup_checks.py
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
python3 tools/verification/p10a_provider_translation_contract_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Step5 build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Step5 build
DerivedData/Step5/Build/Products/Debug/blocks --help
test ! -e DerivedData/Step5/Build/Products/Debug/Blocks.app/Contents/Library/LoginItems/BlocksLoginItemHelper.app
git diff --check
```

P4 retired guard 抽验和全组运行均 PASS。

## 证据

- 低敏 UI / TCC 证据：`docs/项目管理库/003_架构升级/step_5/evidence/2026-07-06-ui-tcc-evidence-v0.md`
- P12 fresh DerivedData check 确认 `DerivedData/Step5/Build/Products/Debug/Blocks.app` 无 `Contents/Library/LoginItems/BlocksLoginItemHelper.app`。
- `blocks --help` 仅列出 `blocks.screenshot.capture`，未新增 clipboard payload CLI。

## 残余风险

- 未触发真实 Screenshot Result 的 copy/save/retake/close 面板操作。
- 未运行真实 VoiceOver，只读取 accessibility tree。
- 未切换英文/日文系统语言；本轮以 String Catalog 自动化和中文窄宽度实物观察覆盖。
- 未触发真实 paste/copy/hover payload read 或 translation preview payload read。
