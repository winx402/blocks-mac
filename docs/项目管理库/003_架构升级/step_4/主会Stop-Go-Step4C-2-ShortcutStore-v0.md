# Step 4C-2 ShortcutStore 主会 Stop/Go 记录 v0

日期：2026-07-06
角色：主 agent / 项目负责人 / 产品经理
结论：go-after-commit

## 1. 决策

Step 4C-2 ShortcutStore 子批次接受，允许进入 Step 4C-3 Settings shell split 准备，但必须先提交当前 Step 4C-2 交付物，保持下一子批次工作区干净。

本结论只覆盖 Step 4C-2 ShortcutStore；不代表 Step 4C-3 Settings shell split、conditional Step 4C-4 Clipboard hardening 或真实系统快捷键 / Settings UI 实物路径已完成或已验收。

## 2. 接受依据

- 开发回调：`DONE_WITH_CONCERNS`；P11C、P6A、P6B、P6C、P7C、P7D、Blocks build、BlocksCLI build、`blocks --help`、`git diff --check` 均 PASS。
- App 架构师实现复审：`approve-for-acceptance`，P0=0，P1=0。
- UI/交互实现复审：`approve-for-acceptance`，无 UI/交互 P0/P1 阻断。
- 安全合规实现复审：`accepted-with-residual-risk`，P0=0，P1=0。
- 测试/质量独立验收：`accepted-with-residual-risk`，P0=0，P1=0；P11C、P6A、P6B、P6C、P7C、P7D、Blocks build、BlocksCLI build、`blocks --help`、写文档前后 `git diff --check` 均 PASS。

## 3. 范围确认

已接受范围：

- `ShortcutStore` 成为快捷键注册结果、绑定配置、诊断计数和快捷键 facade 的 feature-level 事实源。
- `AppState.shortcutRegistrationResults` 保持 computed facade，并桥接 `shortcutStore.objectWillChange`。
- `ShortcutStore` 不持有完整 `AppState`；动作注入收敛为 `screenshotRegion`、`clipboardHistory`、`translationPanel` 三个声明闭包。
- `ShortcutBindingStore` 持久化策略、UserDefaults key、restore default 和 global modifier 语义保持不变。
- P11C 覆盖 target membership、AppState facade/objectWillChange、Store 不持有 AppState、动作 allowlist、forbidden token、ShortcutBindingStore 持久化、single recorder state 和旧事实源处理。
- P6A/P6B/P6C/P7C/P7D 已迁移到当前 Step 4C PRD、4C-2 开发记录和当前代码事实源；旧 story/archive/project docs 仅为 `baseline_reference`，不参与 `ok`。

未接受 / 未启动范围：

- Step 4C-3 Settings shell split。
- Conditional Step 4C-4 Clipboard hardening。
- 真实系统快捷键按键、真实 OSStatus 冲突矩阵、真实 Settings recorder 实物操作。
- 真实权限请求、系统设置、Show in Finder、restart、TCC reset。
- Provider call、图片外发、真实 OCR、Keychain secret 读取、剪贴板完整 payload 读取。

## 4. 残余风险接受

主会接受以下 P2 残余风险，不阻断 Step 4C-2 提交：

- 未覆盖真实系统快捷键按键、系统级注册冲突和 OSStatus 展示。
- 未实物操作 Settings UI 的录制成功、invalid shortcut、Esc/cancel、录制中切换行、切换 pane、关闭 Settings 后 recorder 清理。
- Global modifier 与 custom binding 在真实 UI 下的同步刷新、failed count 展示、VoiceOver / 窄宽度 / 三语言长句仍需低敏实物验收。
- SettingsView 仍较大；Settings shell split 明确留到 Step 4C-3。
- 既有 `FloatingPanelSupport.swift` MainActor/NSApp warning 与 AppIntents metadata skipped warning 仍存在，但未导致本轮门禁失败。

这些残余风险不得在后续文档中写成已完成实物验收；如 Step 4C-3 或后续切片触碰 Settings shortcut / recorder / panel focus 路径，必须重新评估是否升级为阻断门禁。

## 5. 下一步协议

- 先提交 Step 4C-2 代码、verifier 和文档交付物。
- 提交完成前不得启动 Step 4C-3 开发。
- Step 4C-3 仍需按 PRD 的子批次硬门禁执行：独立开发记录、必要专项复审、测试/质量验收记录、主会 stop/go；前一子批次 P0/P1 未关闭不得进入后一子批次。
- Conditional Step 4C-4 Clipboard hardening 启动前仍需 go/no-go；若 P11E、payload allowlist/denylist、UX 或安全质量门禁无法闭合，应拆到 Step 4D 并写 handoff record。
