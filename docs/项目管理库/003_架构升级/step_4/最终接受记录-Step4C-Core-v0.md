# Step 4C core 最终接受记录 v0

状态：accepted-core
日期：2026-07-06
来源级别：main agent acceptance record

## 1. 接受结论

主 agent 最终接受 Step 4C core。

接受范围仅包括：

- Step 4C-1 ScreenshotStore。
- Step 4C-2 ShortcutStore。
- Step 4C-3 Settings shell split。
- Conditional Step 4C-4 Clipboard hardening 的 go/no-go 评估结论与 Step 4D handoff。

Step 4C-4 Clipboard hardening 不在 Step 4C 内接受。它已经拆为 Step 4D 独立推进。

## 2. 接受依据

Step 4C PRD 阶段：

- Step 4C PRD 已完成 App 架构师、UI/交互、测试/质量、安全合规四方方案复审。
- PRD P1 已回写并完成轻量复审，新增 P0/P1 为 0。
- PRD 阶段已提交，后续子批次在干净基线上推进。

Step 4C-1 ScreenshotStore：

- 开发记录结论为 `DONE_WITH_CONCERNS`。
- App 架构师实现复审：`approve-for-acceptance`，P0/P1 为 0。
- UI/交互实现复审：`approve-for-acceptance`，无 P0/P1 阻断。
- 安全合规补充复审：`accepted-with-residual-risk`，原失败路径低敏输出 P1 已关闭。
- 测试/质量独立验收与补充复验：`accepted-with-residual-risk`，P0/P1 为 0。
- 主会 Stop/Go 记录结论为 `go-after-commit`。

Step 4C-2 ShortcutStore：

- App 架构师实现复审：`approve-for-acceptance`，P0/P1 为 0。
- UI/交互实现复审：`approve-for-acceptance`，无 P0/P1 阻断。
- 安全合规实现复审：`accepted-with-residual-risk`，P0/P1 为 0。
- 测试/质量独立验收：`accepted-with-residual-risk`，P0/P1 为 0。
- 主会 Stop/Go 记录结论为 `go-after-commit`。

Step 4C-3 Settings shell split：

- App 架构师实现复审：`approve-for-acceptance`，P0/P1 为 0。
- UI/交互实现复审：`approve-for-acceptance`，无 P0/P1 阻断。
- 安全合规实现复审：`accepted-with-residual-risk`，P0/P1 为 0。
- 测试/质量独立验收：`accepted-with-residual-risk`，P0/P1 为 0。
- 主会 Stop/Go 记录结论为 `go-after-commit`。

Step 4C-4 Go/No-Go：

- App 架构师建议 `split-to-step4d`。
- 测试/质量结论 `changes-required-before-go`。
- UI/交互与安全合规允许进入 4C-4 开发，但均要求 P11E、read model 和低敏输出在验收前作为 P1 关闭。
- 主会最终选择 `no-go-split-to-step4d`。

## 3. 已接受成果

ScreenshotStore：

- `ScreenshotStore` 成为 screenshot facts / actions 的 feature-level 事实源。
- `AppState.lastCaptureSummary`、`AppState.recentCaptures` 为 computed facade，并桥接 `screenshotStore.objectWillChange`。
- 截图入口、权限刷新顺序、缺权 alert、retake 回调和 preview-only route resolver 语义保持。
- `ScreenshotResultPresenter` / `ScreenshotResultView` 不再直接依赖 `EnvironmentObject AppState`，AI route preview 仍不上传图片、不调用 provider。
- P11A 和相关 P3 / P7Q 门禁已迁移当前事实源。

ShortcutStore：

- `ShortcutStore` 成为快捷键注册结果、绑定配置、诊断计数和快捷键 facade 的 feature-level 事实源。
- `AppState.shortcutRegistrationResults` 为 computed facade，并桥接 `shortcutStore.objectWillChange`。
- 动作注入限制为 `screenshotRegion`、`clipboardHistory`、`translationPanel` 三个声明闭包。
- `ShortcutBindingStore` 持久化策略、restore default 和 global modifier 语义保持。
- P11C 和相关 P6 / P7 门禁已迁移当前事实源。

Settings shell split：

- `SettingsView` 退化为 compatibility wrapper。
- `SettingsShellView` 与 `Features/Settings` pane 承接 Settings 主体。
- `SettingsViewMode` 全量保留，`clipboardPrivacy`、`hooks`、`dataAudit` 映射明确。
- Provider、Translation、Permission、Shortcut、Clipboard 既有 store / facade / adapter / gate 边界未被本切片重写。
- P11D 和相关 P8G / P7 门禁已迁移当前事实源。

## 4. 已验证门禁

Step 4C-1 覆盖：

```bash
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p3c_screenshot_checks.py
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py
python3 tools/verification/p3e_screenshot_result_polish_checks.py
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py
python3 tools/verification/p5m_provider_routing_error_localization_checks.py
python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py
```

Step 4C-2 覆盖：

```bash
python3 tools/verification/p11c_shortcut_store_checks.py
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py
python3 tools/verification/p7c_shortcut_global_modifier_checks.py
python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py
```

Step 4C-3 覆盖：

```bash
python3 tools/verification/p11d_settings_shell_split_checks.py
python3 tools/verification/p8g_settings_shell_redesign_checks.py
python3 tools/verification/p7b_settings_sidebar_stability_checks.py
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py
python3 tools/verification/p7e_settings_visual_scroll_checks.py
python3 tools/verification/p7f_settings_menu_dedup_checks.py
```

各子批次均已有记录显示 App build、BlocksCLI build、`blocks --help` 和 `git diff --check` 通过。主会在本最终接受记录提交前只补跑文档层面的 `git diff --check`，不重新运行重型 build。

## 5. 未接受范围

以下内容不属于 Step 4C core 已接受成果：

- Clipboard hardening 实现。
- `tools/verification/p11e_clipboard_hardening_checks.py` 通过。
- 默认列表 / 普通面板 / Settings summary / CLI 默认输出不读取完整 payload。
- redacted list、repository unavailable 产品化、empty / unavailable / filtered / redacted 四类状态实物证据。
- paste / copy / hover detail / translation preview 的 explicit payload read allowlist 实现。
- helper 生产写库、App Group、CLI 默认完整 payload、真实 OCR、provider call、网络外发、Keychain 或任意自动化能力。
- 真实截图 region / window / fullscreen 实物路径、真实 TCC denied / revoked 矩阵、真实 Settings UI 多语言 / VoiceOver / 窄宽度完整覆盖。

## 6. 残余风险接受

主会接受以下 P2 风险，不阻断 Step 4C core 关闭：

- Screenshot 真实截图、copy/save/retake/close、Screen Recording revoked 路径仍缺低敏实物验收。
- Shortcut 真实系统快捷键、OSStatus 冲突、Settings recorder invalid / cancel / pane 切换 / 关闭清理仍缺实物验收。
- Settings 真实 UI 点击、滚动、多语言、VoiceOver、窄宽度和长文本仍缺低敏实物验收。
- 既有 `FloatingPanelSupport.swift` MainActor / NSApp warning 与 AppIntents metadata skipped warning 仍存在，但未导致本轮门禁失败。
- Clipboard hardening 的 read model 风险已经拆到 Step 4D，不允许在 Step 4C 文档中写成已解决。

## 7. 下一步

- Step 4C core 关闭后，下一阶段是 Step 4D Clipboard hardening PRD。
- Step 4D 开发前必须先完成 PRD、四方方案复审、P0/P1 清零和 PRD 提交。
- Step 4D 不得直接派开发改 Clipboard 业务代码。
- Step 4D 最终接受前，不得声称 Step 4 架构升级已全部完成。
