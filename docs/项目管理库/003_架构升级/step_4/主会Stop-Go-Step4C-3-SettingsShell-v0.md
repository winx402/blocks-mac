# Step 4C-3 Settings shell split 主会 Stop/Go 记录 v0

日期：2026-07-06
角色：主 agent / 项目负责人 / 产品经理
结论：go-after-commit

## 1. 决策

Step 4C-3 Settings shell split 子批次接受，允许进入 conditional Step 4C-4 Clipboard hardening 的 go/no-go 评估，但必须先提交当前 Step 4C-3 交付物，保持下一子批次工作区干净。

本结论只覆盖 Step 4C-3 Settings shell split；不代表 conditional Step 4C-4 Clipboard hardening 已启动、已开发或已验收。

## 2. 接受依据

- 开发回调：`DONE_WITH_CONCERNS`；P11D、P8G、P7B、P7C、P7D、P7E、P7F、Blocks build、BlocksCLI build、`blocks --help`、`git diff --check` 均 PASS。
- App 架构师实现复审：`approve-for-acceptance`，P0=0，P1=0；P11D 与 `git diff --check` 均 PASS。
- UI/交互实现复审：`approve-for-acceptance`，无 UI/交互 P0/P1 阻断。
- 安全合规实现复审：`accepted-with-residual-risk`，P0=0，P1=0；P11D 与 `git diff --check` 均 PASS。
- 测试/质量独立验收：`accepted-with-residual-risk`，P0=0，P1=0；P11D、P8G、P7B、P7C、P7D、P7E、P7F、Blocks build、BlocksCLI build、`blocks --help`、写文档前后 `git diff --check` 均 PASS。

## 3. 范围确认

已接受范围：

- `SettingsView` 退化为 compatibility wrapper，仅保留 `mode` 并委托 `SettingsShellView(mode:)`。
- `SettingsShellView` / `Features/Settings` pane 承接 Settings 主体、滚动容器、header、mode route mapping 和 `all` 组合。
- `SettingsViewMode` 全量保留：`all`、`general`、`clipboard`、`clipboardPrivacy`、`translation`、`shortcuts`、`providers`、`agentCLI`、`hooks`、`dataAudit`、`permissions`。
- `clipboardPrivacy` 明确映射到 `ClipboardSettingsPane(showPrivacySection: true)`，并保留返回 Clipboard 设置路径。
- `hooks` / `dataAudit` 分别映射到 `HooksSettingsPane` / `DataAuditSettingsPane`。
- Provider、Translation、Permission、Shortcut、Clipboard 既有 store / facade / adapter / gate 边界未被本切片重写。
- Provider secret 输入、外发确认、连接测试确认、Shortcut recorder state、Translation runtime state 等 pane 局部状态仍留在对应 pane 内。
- P11D 覆盖 target membership、wrapper、full modes、mode mapping、`clipboardPrivacy`、setting keys、pane-local state、forbidden token 和旧事实源处理。
- P8G/P7B/P7C/P7D/P7E/P7F 已迁移到当前 Step 4C PRD、4C-3 开发记录和当前 shell/pane 代码事实源；旧 story/archive/project docs 仅为 `baseline_reference`，不参与 `ok`。

未接受 / 未启动范围：

- Conditional Step 4C-4 Clipboard hardening。
- Clipboard repository unavailable、redacted list、explicit payload read、payload allowlist / denylist、read model 和 P11E。
- Settings 真实 UI 点击、滚动、pane 切换、窄宽度、多语言、VoiceOver / 键盘导航实物验收。
- 真实权限请求、系统设置、Show in Finder、restart、TCC reset。
- Provider call、Keychain secret 读取、真实 OCR、图片外发、剪贴板完整 payload 读取。

## 4. 残余风险接受

主会接受以下 P2 残余风险，不阻断 Step 4C-3 提交：

- 未实物操作 Settings UI 的进入各 pane、滚动、pane 切换、视觉密度和窄宽度路径。
- 未覆盖长 app path、长 bundle ID、长 recommended action、长 provider requirement、长 audit ID 和三语言长句的真实渲染。
- 未覆盖 VoiceOver hidden-label 控件、键盘导航和可访问性实际读屏。
- Shortcut recorder 的切换 pane / 关闭 Settings 清理、Provider 局部状态切换 pane 后的行为仍需低敏实物验收。
- Permission diagnostics UI 可能显示 app path / running paths，后续验收记录不得复制真实完整本地路径。
- P11D direct-token fail-closed 足够覆盖本切片，但 facade 方法是否只出现在 Button / user-action 路径仍依赖人工复核，后续可加强 verifier。
- 既有 `FloatingPanelSupport.swift` MainActor/NSApp warning 与 AppIntents metadata skipped warning 仍存在，但未导致本轮门禁失败。

这些残余风险不得在后续文档中写成已完成实物验收；如 Step 4C-4 或后续切片触碰 Settings、Clipboard、Permission、Provider 或 Shortcut 相关用户路径，必须重新评估是否升级为阻断门禁。

## 5. 下一步协议

- 先提交 Step 4C-3 代码、verifier 和文档交付物。
- 提交完成前不得启动 conditional Step 4C-4 开发。
- Step 4C core 现已完成：4C-1 ScreenshotStore、4C-2 ShortcutStore、4C-3 Settings shell split 均已主会 stop/go 并准备提交。
- Conditional Step 4C-4 Clipboard hardening 启动前必须先做 go/no-go；若 P11E、payload allowlist/denylist、UX contract、安全合规或测试/质量门禁无法闭合，应拆到 Step 4D 并写 handoff record。
- 若决定拆 Step 4D，Step 4C 最终接受记录只能写 Step 4C core 完成，不得暗示 Clipboard hardening 已完成。
