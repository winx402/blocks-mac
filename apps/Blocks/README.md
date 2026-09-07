# Blocks macOS App

状态：Step 5 架构清理完成中
最后审阅：2026-07-06

这是「积木工具」的第一个正式 macOS App 工程，不是 P2 spike。Step 5 后当前工程以 `AppModel` 作为组合根，截图、权限、快捷键、设置、Provider/Translation 和 Clipboard 事实源由 feature store 承担；旧 `AppState` facade、`SettingsView` wrapper、未路由 `ClipboardHistoryView`、Login Item helper target 和 App 内 recorder debug UI 已删除。剪贴板默认 UI 采用 metadata-first / redacted-first 读取模型；完整 payload 只允许在 paste、copy、record detail 和 translation preview 等显式 purpose 路径中读取。生产级 packaging/notarization、future helper/App Group、CLI clipboard payload、真实 OCR/provider 图片外发仍需另开 PRD。

## Targets

- `Blocks`：官方直发 App，采用 App Sandbox、Developer ID、Hardened Runtime 和 notarization；不计划上架 App Store。`LocalDevelopment` 使用独立 bundle/runtime identity、数据目录和 Keychain namespace，且不启用 App Sandbox，不能与官方包的身份或数据混用。`build_and_run.sh` 会把开发产物固定 staging 到 `~/Applications/BlocksDev/Debug/Blocks.app`；尚未完成的签名、公证和更新链路不代表可发行。

首次构建前，将 `Config/Signing.local.example.xcconfig` 复制为被 Git 忽略的 `Config/Signing.local.xcconfig`，按模板填写自己的 Team、签名及 profile 配置，并安装授权对应 Keychain 组的开发 profile。不要提交本机配置、证书或 profile。缺少签名时脚本会在修改安装包前停止；`BLOCKS_REQUIRE_STABLE_SIGNING=0` 不会取消系统对 profile 的要求。

运行脚本默认把构建产物放在 `~/Library/Caches/BlocksDev/DerivedData.noindex/Blocks`，避免 Spotlight 将其当作第二个应用；可用 `BLOCKS_DERIVED_DATA_DIR` 显式覆盖（自定义路径也应位于非索引目录）。请从稳定安装路径启动 App。旧版本在仓库 `DerivedData/` 生成的副本不会自动删除；确认不再使用后可自行移除旧构建目录。
- `BlocksCore`：共享 action 与 XPC contract module，提供 action envelope、audit id、permission status 和通用 Action Broker DTO。
- `BlocksScreenshotCore`：截图领域 framework，提供智能选择状态机、跨屏几何、编辑文档、渲染和编码。
- `BlocksActionBroker`：用户显式启用的 LaunchAgent，负责在 CLI 与 App 之间路由本地 action。
- `blocks`：CLI target，支持 `list` 和新版 `blocks.screenshot.capture` 交互式/无编辑契约。

## Build And Run

项目根目录下使用统一入口：

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

稳定签名门禁：

```bash
BLOCKS_REQUIRE_STABLE_SIGNING=1 ./script/build_and_run.sh --verify
```

如果本机没有有效开发签名，普通构建和上述门禁都会 fail fast。配置好证书及匹配 profile 后再构建；已有安装包可用 `--open-existing` 启动，但不能因此将 Screen Recording / Accessibility 验收标为通过。

等价 App 构建命令：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath "$HOME/Library/Caches/BlocksDev/DerivedData.noindex/Blocks" build
```

CLI target 单独构建：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath "$HOME/Library/Caches/BlocksDev/DerivedData.noindex/Blocks" build
```

CLI 示例：

```bash
BLOCKS_CLI="$HOME/Library/Caches/BlocksDev/DerivedData.noindex/Blocks/Build/Products/Debug/blocks"
"$BLOCKS_CLI" list
"$BLOCKS_CLI" run blocks.screenshot.capture --interactive
"$BLOCKS_CLI" run blocks.screenshot.capture --interactive --kind smart
"$BLOCKS_CLI" run blocks.screenshot.capture --no-editor --kind display --display-scope current --copy
"$BLOCKS_CLI" run blocks.screenshot.capture --no-editor --kind region --output /tmp/blocks-shot.png
```

P3-C 截图稳定化验证：

```bash
python3 tools/verification/p3c_screenshot_checks.py --timeout 180
```

P3-D 截图 AI action entries 验证：

```bash
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py --timeout 180
```

P4 Clipboard helper / debug verifier 已在 Step 5 退役。当前阻断门禁使用 P8/P9/P11E/P12；旧 P4 脚本只作为 Step 5 cleanup guard，确认 helper/debug target、legacy history view 和 runtime service 不再存在。

P5-A 翻译入口 skeleton 验证：

```bash
python3 tools/verification/p5a_translation_skeleton_checks.py --timeout 180
```

P5-B 翻译 mock result panel 验证：

```bash
python3 tools/verification/p5b_translation_mock_result_checks.py --timeout 180
```

P5-C Provider 设置 skeleton 验证：

```bash
python3 tools/verification/p5c_provider_settings_checks.py --timeout 180
```

P5-D Keychain lifecycle UI skeleton 验证：

```bash
python3 tools/verification/p5d_keychain_lifecycle_ui_checks.py --timeout 180
```

P5-E Provider audit summary skeleton 验证：

```bash
python3 tools/verification/p5e_provider_audit_checks.py --timeout 180
```

P5-F Provider connection gate skeleton 验证：

```bash
python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180
```

P5-G Keychain UI gate 验证：

```bash
python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180
```

P5-H AI Capability Provider Layer 验证：

```bash
python3 tools/verification/p5h_ai_capability_layer_checks.py --timeout 180
```

P5-I LLM Adapter Boundary 验证：

```bash
python3 tools/verification/p5i_llm_adapter_boundary_checks.py --timeout 180
```

P5-J API Key / OpenAI Connection Gate 验证：

```bash
python3 tools/verification/p5j_api_key_connection_gate_checks.py --timeout 180
```

P5-K User API Key Keychain Gate 验证：

```bash
python3 tools/verification/p5k_user_secret_keychain_gate_checks.py --timeout 180
```

P5-L OpenAI-compatible Test Connection Gate 验证：

```bash
python3 tools/verification/p5l_openai_connection_test_gate_checks.py --timeout 180
```

P5-N Translation Engine Router Integration 验证：

```bash
python3 tools/verification/p5n_translation_engine_router_checks.py --timeout 180
```

P5-O OpenAI-compatible Translation Runtime Gate 验证：

```bash
python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180
```

P6-A Shortcut + Floating Panel Interactions 验证：

```bash
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py --timeout 180
```

P6-B Shortcut Customization + Floating Panel Polish 验证：

```bash
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py --timeout 180
```

P6-C / P4-J / P5-P / P3-E 批量交互补强验证：

```bash
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py --timeout 180
python3 tools/verification/p4j_clipboard_panel_deepening_checks.py --timeout 180
python3 tools/verification/p5p_translation_panel_polish_checks.py --timeout 180
python3 tools/verification/p3e_screenshot_result_polish_checks.py --timeout 180
```

P4-K / P5-Q / P3-F P7 前补强验证：

```bash
python3 tools/verification/p4k_clipboard_recorder_policy_checks.py --timeout 180
python3 tools/verification/p5q_translation_language_error_ux_checks.py --timeout 180
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py --timeout 180
```

P7-A 当前验收聚合门禁（历史文件名保留）：

```bash
python3 tools/verification/p7a_low_sensitive_acceptance_gate_checks.py --timeout 180
```

P7-B Settings sidebar stability fix 验证：

```bash
python3 tools/verification/p7b_settings_sidebar_stability_checks.py --timeout 180
```

P7-C 设置 / 浮层 / 玻璃优化验证：

```bash
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py --timeout 180
python3 tools/verification/p7c_shortcut_global_modifier_checks.py --timeout 180
python3 tools/verification/p7c_clipboard_paste_style_panel_checks.py --timeout 180
python3 tools/verification/p7c_translation_auto_split_panel_checks.py --timeout 180
python3 tools/verification/p7c_liquid_glass_visual_boundary_checks.py --timeout 180
```

P7-D 浮层、设置页、快捷键与权限引导优化验证：

```bash
python3 tools/verification/p7d_clipboard_panel_resize_hover_checks.py --timeout 180
python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py --timeout 180
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py --timeout 180
python3 tools/verification/p7d_translation_auto_target_alignment_checks.py --timeout 180
python3 tools/verification/p7d_permission_assist_glass_diagnostics_checks.py --timeout 180
```

P7-E 设置页、Clipboard、Translation 与权限辅助深度打磨验证：

```bash
python3 tools/verification/p7e_issue_ledger_checks.py
python3 tools/verification/p7e_settings_visual_scroll_checks.py
python3 tools/verification/p7e_clipboard_position_autopaste_checks.py
python3 tools/verification/p7e_translation_language_result_checks.py
python3 tools/verification/p7e_permission_assist_flow_checks.py
```

P7-F 设置导航、权限授权与自动粘贴回归修复验证：

```bash
python3 tools/verification/p7f_issue_ledger_reopen_checks.py
python3 tools/verification/p7f_settings_menu_dedup_checks.py
python3 tools/verification/p7f_permission_state_refresh_checks.py
python3 tools/verification/p7f_permission_assist_position_drag_checks.py
python3 tools/verification/p7f_clipboard_autopaste_permission_retry_checks.py
```

P7-G 权限与设置交互重构验证：

```bash
python3 tools/verification/p7g_permission_settings_interaction_checks.py
```

P7-H 真实交互回归修复验证：

```bash
python3 tools/verification/p7h_stable_signing_permission_identity_checks.py
python3 tools/verification/p7h_clipboard_autopaste_activation_checks.py
python3 tools/verification/p7h_translation_swap_result_sync_checks.py
```

P7-K/M/N Alpha 门禁与当前剪贴板交互门禁验证：

```bash
python3 tools/verification/p7k_permission_identity_gate_checks.py --timeout 180
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py --timeout 180
python3 tools/verification/p7m_translation_settings_productization_checks.py
python3 tools/verification/p7n_alpha_readiness_gate_checks.py --timeout 180
```

P7-L 绑定重构前的剪贴板源码结构，仅保留为历史检查；P7-N 已改用其当前后继 P13-C。

P8-M/N 剪贴板模块化、自捕获抑制与条目字体门禁：

```bash
python3 tools/verification/p8m_clipboard_modularization_checks.py --timeout 180
python3 tools/verification/p8n_clipboard_capture_font_settings_checks.py
```

## Current Boundaries

- 截图只有一个智能入口：单击捕获窗口、拖拽选择区域、`F` 切换屏幕；区域确认前可移动、八向缩放和键盘微调。
- Clipboard 记录交互固定为原生 AppKit 解析：按下即时选择，单击打开详情，双击执行复制、关闭与粘贴链路；不提供单击/双击粘贴模式或对应偏好 key。
- 捕获支持跨屏区域、指定屏幕和全部屏幕合成；领域几何和像素上限由 `BlocksScreenshotCore` 统一处理。
- 编辑器提供专业/简洁两种共享状态布局、基础标注工具、对象选择移动、撤销重做、缩放平移和 PNG/JPEG 输出。
- Phase 1 不保存截图历史，不提供 OCR、翻译、总结或其他 AI 路由；这些能力按 006 后续阶段单独实现。
- CLI 通过用户显式启用的 Action Broker 调用 App；CLI 内不实现选择、捕获或渲染逻辑。
- Step 5 已删除 P4 helper/debug 路径：无 `BlocksLoginItemHelper` target、无 Embed LoginItems、无 helper entitlements、无 `ClipboardRecorderRuntimeService`、无 App 内 recorder preflight/watch/session/reset UI。
- Clipboard panel 当前由 `ClipboardStore`、`ClipboardController`、`ClipboardRecordViews`、`ClipboardFloatingPanelView` 和 `ClipboardDetailPresentationLayer` 组成；默认 list/card/tray/settings 只读取 redacted metadata preview。
- 完整 clipboard payload 读取只允许在 `ClipboardPayloadReadPurpose` allowlist 下发生：paste、copy plain text、record detail、translation preview。默认 repository load 不预读 payload，payload cache 按 `(recordID, purpose)` 分区。
- Settings Clipboard 仍保留 retention days、max items、preserve pinned 和 excluded bundle IDs 策略；策略作用于 App 内 storage/read model，不恢复 P4 helper/debug 能力。
- 菜单栏 Clipboard / Pause Recorder 会打开主窗口并选中 Clipboard 面板；Pause 只影响本次运行内存态。
- P5-B Translation section 支持 Local Mock、BYOK API placeholder 和 Local CLI placeholder 三类 provider profile；只有 Local Mock 能生成本地 mock 结果，BYOK/API 和 CLI 仍只显示 `external_transfer` / not ready，不调用 provider、不执行 CLI、不接 OCR、不上传内容。
- P5-C Settings 增加 Provider / AI section：默认 provider、Keychain account alias、API Base URL、本地 CLI 名称和 confirmation preview。当前只保存 alias / base URL / CLI 名称，不读取 Keychain、不读取 env、不访问网络、不执行 CLI。
- P5-D Settings 增加 Keychain secret lifecycle UI skeleton：Save/Rotate/Delete/Verify Missing 只改变本地生命周期状态和低敏 audit id，不提供 secret 输入框。
- P5-E Settings 增加 Provider audit summary skeleton：Local Mock 结果、Provider confirmation preview 和 Keychain lifecycle UI intent 会写入最多 20 条内存态脱敏摘要，设置页展示最近 5 条并支持清空；不持久化、不记录 provider 原始输出、不调用真实 provider。
- P5-F Settings 增加 Provider connection gate skeleton：Local Mock 显示 ready；BYOK API 和 Local CLI 显示真实 Keychain / 网络 / CLI 执行门禁阻断；Validate 和 Preview Test 只更新状态与脱敏审计摘要，不调用真实 provider。
- P5-G Settings 增加真实 Keychain 低敏测试门禁：Save/Rotate/Delete/Verify Missing 会调用 `SecItem` 写入、读取、更新、删除固定低敏 fixture，UI 和审计只显示 service、account、长度、OSStatus 和 SHA-256 前 12 位。
- P5-G 只证明 Keychain fixture gate 可用；用户 API key 保存由 P5-K 接管，低敏 OpenAI-compatible test connection 由 P5-L 接管；真实工具内容 provider 调用、CLI 执行和持久审计日志仍未开放。
- P5-H Settings 增加 AI Capability Gate：LLM Provider、Translation Engine、OCR Engine 分层展示，预留 OpenAI-compatible、LiteLLM / Gateway、本地 CLI、LLM-backed 翻译、专用翻译 API、Apple Vision OCR、多模态 LLM OCR 和云 OCR profile。
- P5-H 只证明能力层 catalog / UI / 本地化骨架；真实 API 调用、真实 CLI execution、真实 OCR 和 provider 原始输出仍未开放。
- P5-I Settings 增加 LLM Adapter Boundary：OpenAI-compatible preview 只生成 `external_transfer` 脱敏审计摘要，本地 mock adapter 只生成 mock response，不调用 API、CLI、OCR、网络、Keychain 或剪贴板。
- P5-I 新增 `LLMProviderAdapter` / `LLMProviderRequest` / `LLMProviderResponse` / `LLMProviderError` / `OpenAICompatibleProfileBoundary`，供后续总结、改写、LLM-backed 翻译、multimodal OCR 和 LLM 转换类工具复用。
- P5-J Settings 增加 API Key Input Gate 和 OpenAI Connection Preview：候选 key 可先做本地预览并清空；connection preview 只生成 `POST /v1/chat/completions` draft 元数据，不发网络请求。
- P5-J 新增 `ProviderSecretInputPreview` / `OpenAIConnectionPreviewDraft` 和 `secretInputPreview` / `openAIConnectionPreview` audit kind；审计只记录 account alias、字符数、provider、model、base URL host、endpoint、timeout 和 audit id。
- P5-K Settings 增加用户 API key Keychain 保存门禁：只有勾选确认且 alias/key 非空才写入 `openai-compatible:<alias>`；Verify/Delete/Missing 只展示 service、account、found、长度和 audit id，不读取 key bytes、不记录 key hash。
- P5-L Settings 增加 OpenAI-compatible Test Connection Gate：只有 alias、base URL、model、已保存 Keychain secret 和显式外发确认齐备时才执行低敏 ping test；审计只展示状态、HTTP status、耗时、request id、输出字符数和 audit id，不保存 provider 原始响应。
- P5-M 新增 Provider route check：Translation 面板和 Settings 可解析 Local Mock、OpenAI-compatible、LLM-backed Translation、专用翻译、Apple Vision OCR 和云 OCR 的 route/error；不读取 key、不执行 CLI、不调用真实 provider。
- P5-N Translation 面板的主 picker 已迁到 Translation Engine：Local Mock 可继续生成本地 mock result；LLM-backed Translation 和 Dedicated Translation API 只显示 route resolution、本地化错误和 confirmation level。本轮不读取 secret、不调用 provider、不执行 CLI。
- P5-O 新增 OpenAI-compatible 翻译 runtime gate：Settings 默认关闭真实翻译外发；用户开启 gate 且 Keychain/base URL/model/alias 齐备时，LLM-backed Translation 可调用 `/v1/chat/completions`，结果只保存脱敏 metadata 和译文，不保存 raw request、Authorization、Bearer 或 raw response。
- P5-P 翻译浮层新增清空输入、运行中状态、复制译文和短错误提示；复制只写当前显示译文，不读取环境变量、不执行 CLI、不上传截图或剪贴板历史完整内容。
- P5-Q 翻译入口新增默认目标语言和记住上次目标语言偏好；runtime 错误使用 ProviderErrorCode 的三语短文案，不增加费用、额度或商业提示。
- P6-A 新增 `ShortcutController` 注册三工具快捷键，并新增 Bob 风格 `TranslationPanelPresenter` / `TranslationFloatingPanelView`；P7-O 后当前可靠默认快捷键为 `Control + Option + A/V/D`，Translation 默认按 Settings 开关读取当前剪贴板纯文本并预填输入框，不读取剪贴板历史完整内容。
- P6-B 将三条快捷键升级为 Settings 可启用/禁用、录入和恢复默认；剪贴板浮层支持再次触发关闭、搜索默认聚焦和 `Esc` 关闭；翻译浮层已打开时只聚焦不覆盖输入，输入框默认聚焦，预填时尝试全选，并支持 source / target 语言交换。
- P6-C Settings 新增快捷键注册诊断、重新注册和低敏人工验收提示；P6-B 快捷键自定义能力保持兼容，自动化只验证 wiring 和状态展示，不伪造真实系统按键触发结果。
- P7-A 的历史脚本名继续作为聚合入口，但事实源已迁移到当前 `015_翻译工具完善` PRD 和实施/阻断记录；自动化通过仍不能替代安装版快捷键、截图 OCR、多服务、收藏和插件的真实验收。
- P7-B 将 Settings detail 从 root `Form` 改为 top-anchored `ScrollView` + `SettingsSection`，避免超高设置内容影响主侧边栏布局。
- P7-C 将主窗口改为固定宽度手动 sidebar + 顶部锚定 detail；Provider、Shortcuts、Permissions 升级为独立入口；快捷键支持全局修饰键且单项自定义优先；剪贴板底部浮层改成 Paste 风格横向卡片 tray；翻译浮层改成左右分割并自动翻译；`GlassPanel` 统一更透明的 Liquid Glass / material fallback。
- P7-D 将 Clipboard / Translation 浮层改成互斥 show/focus、点击外部关闭和尺寸保存；Clipboard 默认不展示详情，hover 时显示详情；Translation 使用自动目标语言 resolver；Settings 增加 Clipboard / Translation 独立 route、彩色分组侧边栏、权限辅助拖拽面板和玻璃诊断。
- P7-E 将 P7-D 后的体验问题整理为 issue ledger 并逐项修正：Settings 左侧栏独立滚动、内容区保留顶部留白，Clipboard bottom 模式满宽且只保存高度、left/right 固定屏幕高度，低敏可恢复 fixture 支持双击写回剪贴板并尝试 Command+V，Translation 浮层显示检测语言、双向交换和译文结果，Permission Assist 会隐藏 Blocks 设置页并尽量贴近 System Settings。
- P7-F 修复 P7-E 后复现的回归：主侧边栏不再显示旧 Clipboard / Translation 工具页；Clipboard / Translation 主要入口回到快捷浮层和对应设置 route；权限状态通过统一 snapshot 刷新，并显示 ad-hoc signing / 重启诊断；Permission Assist 等待 System Settings 出现后展示，箭头方向随左右位置变化，拖动 App 图标不会拖动整个面板。
- P7-G 将设置导航进一步改成无分组设置分类；Screen Recording 权限路径补 `NSScreenCaptureUsageDescription`、`CGRequestScreenCaptureAccess()` 和 Check / Request / Recover 诊断；Accessibility 可从权限页独立请求；Clipboard 自动粘贴使用 `ClipboardPasteAttempt` 分型；Permission Assist 使用显式状态机管理打开、等待、引导、检查、失败和关闭。
- P7-H 将 Debug App 运行路径固定到稳定 staging path；P7 实测后默认改为 `~/Applications/BlocksDev/Debug/Blocks.app`，避免中文项目路径、DerivedData 和 SwiftUI drag cache 多副本影响 TCC 识别。权限诊断会展示 signature kind、Team ID、running path 和 identity issue；Clipboard 自动粘贴增加 target activation failed 分型，不再依赖 deprecated activation；Translation 交换语言后立即刷新 preview/result metadata。
- P7-K/L/M/N/P/Q/R/S 增加稳定签名权限 gate、Clipboard bottom tray 高度/空白收敛、Translation route/audit 诊断折叠、串行 Alpha readiness gate、P7-P closure gate、P7-Q screenshot mode pass、P7-R Permission Assist granted-state pass 和 P7-S final baseline。当前机器 Apple Development 证书 trust settings 已恢复系统默认，`--verify-permissions` 已通过；P7-O 已完成真实 Screen Recording / Accessibility、区域截图、Translation 浮层和 Clipboard 自动粘贴核心路径验收；P7-Q 已完成 Window / Fullscreen 真实点击验收。
- P8-H 修复第一批产品细节：Clipboard 设置页迁移到左右行设置模型，侧边栏密度收紧，历史 `Option` 默认快捷键迁移到 `Control + Option`，Clipboard panel 打开后延迟 outside-click monitor 避免自关，筛选组改为同一行内展开，fixture 图片卡片可展示缩略图。
- P8-I 系统化修复 Settings 与 Clipboard bottom panel：所有主要 Settings route 迁移到统一 `SettingsTableSection + SettingsFormRow`，普通行不再放每项图标，右侧控件统一 trailing column；Clipboard bottom panel 每次按当前 screen visibleFrame 贴底满宽，只允许调高度并只保存 `floatingPanel.clipboard.bottom.height`。
- P8-J 修复 Settings 右对齐和控件类型：统一 `SettingsLayout` / `SettingsRowShell`，消除散落控件宽度；4 项及以上选项改用 menu，下拉选择不再挤成 segmented。
- P8-K 修复 Settings 全屏适配和 section 标题：Settings 内容在全屏下居中收敛，普通 section 标题不再显示图标。
- P8-L 重开并修复 Clipboard bottom panel 高度锚定：bottom panel 底边固定在 `visibleFrame.minY`，拖动顶部 handle 只改变真实 `frame.height`，关闭重开后高度保持，x/y/width 始终按当前屏幕可见区域重算。
- P8-M 模块化剪贴板：`ClipboardFloatingPanelView` 现在是 composition root；filter bar、record views、width resize、record detail、auto paste、pinboard、preview、typed settings 和 controller 均已拆到独立文件；P8-M 有 story 和 acceptance record，但实物 QA 仍标记 pending。
- P8-N 当前是代码和静态门禁事实：live capture 可忽略内部 pasteboard 写入，自动粘贴和复制纯文本会把写入后的 change count 交给 capture service 抑制回捕；live ingest 后立即应用 retention/max items/preserve pinned/excluded bundle 策略并裁剪 payload；Clipboard 设置页提供条目内容字体 10...18 pt slider，bottom/side/record detail 只缩放内容文字，不缩放标题和 chrome。本项尚无正式 story / acceptance record。
- 当前可见 UI 接入 String Catalog，首批语言为 `zh-Hans`、`en`、`ja`；设置页 Language 偏好先保存并提示重启生效。
- `GlassPanel` 统一处理 macOS 26+ Liquid Glass 和 macOS 14-25 material fallback；截图选区 overlay 不使用重毛玻璃。
- CLI/action JSON 字段名、action 名和结构化错误机器字段不本地化。
- OCR 真实执行、截图/OCR 图片外发、剪贴板历史完整内容外发、总结、标注、拖拽导出、完整设置页、真实 CLI execution、开机常驻剪贴板 recorder、App Group 共享 store、真实用户剪贴板可恢复保存、持久审计日志和 hook runtime 仍不在 P5-O/P4-H。
- Permission Assist revoked-flow、真实多屏、权限撤销/重授权仍需单独验收；Region 已在 P7-O 完成一次真实捕获，Window / Fullscreen 已在 P7-Q 完成真实捕获。
- 运行时截图不得进入仓库；运行脚本构建产物使用 Library 下的 `.noindex` 缓存目录，历史 `DerivedData/` 仍被 Git 忽略。
