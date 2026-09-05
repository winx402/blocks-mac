# 004_剪贴板打磨 Step 3 R1 开发记录 v0

## 结论

Step 3 R1 两个 P1 已修复，结论为 `DONE_WITH_EVIDENCE`。

## 改动范围

- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
  - 新增 `.hoverDetail` source / trigger 与 `.detailOpen` action。
  - hover detail open 现在先进入 `handleRecordAction(...)`，写 selected、focused、interaction token 和本地 event，再由 hover detail surface 继续触发 `.hoverDetail` payload load。
  - paste activation 顶部控件改为 icon + 本地化短文本的 compact 互斥按钮组，并提供 group / option / selected accessibility 语义。
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
  - `ClipboardPanelActivationTrigger` 增加 `hoverDetail`。
- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`
  - hover safe bridge 对齐派发默认值：`safeBridgePadding=12`、`safeRegionInflation=16`。
  - safe bridge background 显式 `.allowsHitTesting(false)`，避免透明区域拦截点击。
- `apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift`
  - paste activation 标题、完整标签、accessibility label/value 改为 String Catalog。
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
  - 新增 paste activation zh-Hans / en / ja 短标签、完整标签、accessibility、selected/not selected 文案。
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`
  - 增加 detail code path、paste activation localization/accessibility、hover bridge hit-testing、direct paste broadened scan。
  - current evidence 的开发记录事实源切到本文件。

## R1 红灯证据

命令：

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
```

在只新增 P13C 检查、尚未改业务代码时，P13C 按预期失败：

- `hover_safe_bridge_hit_transparent`
- `paste_activation_localized`
- `paste_activation_visible_current`
- `paste_activation_accessibility`
- `detail_open_handler_present`
- `detail_open_precedes_surface_load`

该红灯证明 R1 两个 P1 和相关 P2 不再只由 manifest 自述通过。

## P1 修复说明

### P1-1 detail_open 假 PASS

修复后，`ClipboardHoverTrackingView.showDetail(for:)` 仍先调用面板 closure，再展示 detail surface；面板的 `setHoveredRecordID(_:)` 对非空 recordID 调用：

```swift
handleRecordAction(recordID, source: .hoverDetail, trigger: .hoverDetail, action: .detailOpen)
```

`handleRecordAction(...)` 统一先写 selected / focused / interaction token / event，再在 `.detailOpen` 分支更新 `hoverDetailState`。detail card 的 `.hoverDetail` payload read 仍由 hover detail surface lazy load 触发，但发生在 show detail 的面板 handler 之后。

P13C 新增代码级 fail-closed 检查：

- `detail_open_handler_present`
- `detail_open_precedes_surface_load`
- `detail_payload_load_is_hover_detail`

### P1-2 paste activation 语义不足

修复后，paste activation 顶部控件：

- 不再是 icon-only；每个选项显示模式图标 + 本地化短文本。
- 选中态保留模式图标，并用 foreground / background / stroke 表示当前值。
- `ClipboardPasteActivationMode` 文案全部走 `L10n`。
- `Localizable.xcstrings` 新增 zh-Hans / en / ja 的短标签、完整标签、accessibility label、group label、selected/not selected value。
- 控件暴露 group accessibility label，单个选项暴露 option label、selected/not selected value 和互斥选择 hint。

P13C 新增 fail-closed 检查：

- `paste_activation_localized`
- `paste_activation_visible_current`
- `paste_activation_accessibility`

## P2 同步处理

- Hover safe bridge 点击透明：已处理，P13C 新增 `hover_safe_bridge_hit_transparent`，要求 `.allowsHitTesting(false)` 且 12 / 16 参数对齐。
- P13C direct paste 检查过字面化：已处理，P13C 改为扫描 row/card 主体区域，禁止绕过 `onPrimaryActivation` 的 `onPaste()` / `pasteClipboardRecord(` / `action: .paste` 等直连。
- Hover 参数 10 / 8 与派发默认不一致：已处理，改回 12 / 16。

## 验证结果

已运行：

- `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`：PASS。新增 `detailCodePathChecks=true`、`pasteActivationLocalizationChecks=true`、`hoverBridgeHitTestingChecks=true`。
- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`：PASS。
- `python3 tools/verification/p13b_clipboard_tags_model_checks.py`：PASS。
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`：PASS。
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS。
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`：PASS，输出低敏 `<TMP>`。
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`：PASS。
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`：PASS。
- `git diff --check`：PASS。

## 未覆盖项 / 残余风险

- 未触发真实 App、真实剪贴板、真实 VoiceOver、TCC、provider、Keychain、系统设置或自动化。P13C 仍是静态代码检查 + 低敏 fixture manifest，不等同于真实 UI/VoiceOver 录屏。
- SwiftUI 单击 / 双击真实事件顺序仍建议后续低敏实物验收；本轮只证明 row/card 主体不会绕过 activation handler 直连 paste。

## 安全隐私声明

本轮未读取或输出真实剪贴板正文、OCR 原文、完整本地路径、真实 App 名、邮箱、凭据、Authorization header、验证码、二维码或图片字节内容。所有验证输出均为低敏 fixture、相对路径或 sanitizer 结果。
