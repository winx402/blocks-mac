# Step 5 最终接受记录 v0

结论：`step-5-accepted`

主 agent 接受 Step 5：门禁、清理与关闭阶段完成。架构升级本轮实施阶段到此结束；项目不写 closed，后续是否开启发布体验验收、packaging/notarization、future helper/App Group 或真实 OCR/provider 能力，另开专项判断。

## 接受范围

- `AppState.swift` 已删除，`AppModel` 为组合根。
- `SettingsView.swift` wrapper 已删除，调用点直接使用 `SettingsShellView(mode:)`。
- `BlocksLoginItemHelper` target/source/entitlements、Embed LoginItems、`ClipboardRecorderRuntimeService` 和 App 内 recorder debug UI 已删除。
- `ClipboardHistoryView` 已删除；默认 Clipboard UI 不展示 `record.summary` 或完整 payload。
- 一次性 migration 只存在于 `Step5OneShotMigration.swift`。
- P4 helper/debug verifier 已退役为 Step 5 cleanup guard。
- Step 5 P12 和 P11A-E 均 fail closed 使用当前事实源。

## 最终验证

最终验证命令见 `开发记录-Step5-门禁清理关闭-v0.md`。其中 fresh build 确认：

- `xcodebuild ... -scheme Blocks ... -derivedDataPath DerivedData/Step5 build` PASS。
- `xcodebuild ... -scheme BlocksCLI ... -derivedDataPath DerivedData/Step5 build` PASS。
- `DerivedData/Step5/Build/Products/Debug/blocks --help` PASS，输出只包含 screenshot action。
- `test ! -e DerivedData/Step5/Build/Products/Debug/Blocks.app/Contents/Library/LoginItems/BlocksLoginItemHelper.app` PASS。
- `git diff --check` PASS。

## 后续专项候选

- 真实 UI / VoiceOver / 多语言发布前体验验收。
- Packaging / notarization。
- future helper / App Group / CLI clipboard payload。
- 真实 OCR / provider 图片外发。
- Clipboard 编辑、Paste Stack、完整 Pinboard 编辑。
