# Step 4C-4 Clipboard hardening 主会 Stop/Go 记录 v0

日期：2026-07-06
角色：主 agent / 项目负责人 / 产品经理
结论：no-go-split-to-step4d

## 1. 决策

Conditional Step 4C-4 Clipboard hardening 不在 Step 4C 内启动开发，拆为 Step 4D 独立推进。

本决策不否定 Clipboard hardening 的必要性。主会判断是：当前 Clipboard hardening 涉及完整剪贴板 payload 默认读取模型、redacted list、explicit payload read allowlist、P11E fail-closed 门禁、旧 P8/P9 门禁迁移和低敏验收证据，风险边界已经超过 Step 4C core 的收口尾项。继续放在 Step 4C 内开发会把已完成的 ScreenshotStore、ShortcutStore、Settings shell split 接受范围与敏感 payload 改造混在一起。

Step 4C 最终接受只覆盖 core：Step 4C-1 ScreenshotStore、Step 4C-2 ShortcutStore、Step 4C-3 Settings shell split。Clipboard hardening 未开发、未验收、未被 P11E 覆盖，不得写成 Step 4C 已完成范围。

## 2. 输入材料

- `docs/项目管理库/003_架构升级/step_4/PRD-Step4C-剩余Feature收口-v0.md`
- `docs/项目管理库/003_架构升级/step_4/主会Stop-Go-Step4C-3-SettingsShell-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-App架构师Step4C-4-GoNoGo评估-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-UI交互Step4C-4-GoNoGo评估-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-安全合规Step4C-4-GoNoGo评估-v0.md`
- `docs/项目管理库/003_架构升级/step_4/2026-07-06-测试质量Step4C-4-GoNoGo评估-v0.md`

## 3. 角色结论

- App 架构师：`split-to-step4d`。主要理由是 read model、Store API、AppState facade、列表 / hover / paste / copy / translation 调用点、summary 敏感级别和 P11E 都需要独立方案承接。
- 测试/质量：`changes-required-before-go`。主要理由是 P11E 缺失，旧 P8/P9 门禁不适合作为 4C-4 阻断门禁，当前代码默认 read model 与目标相反。
- UI/交互：`go-for-4c4-development`，但将 P11E、默认列表不读 payload、四类状态可区分、repository degraded 可见和低敏输出列为开发 / 验收前必须关闭的 P1。
- 安全合规：`go-for-4c4-development`，但明确这不是验收通过；要求先建 P11E 并在当前基线红灯，再改 read model；若无法 fail-closed 则拆 Step 4D。

主会采用更保守口径：当架构和测试/质量均提示启动前证据链不足，且 UI / 安全的 go 也依赖 4C-4 内关闭多项 P1 时，不继续在 Step 4C 内追加敏感 payload 改造。

## 4. 关键事实

- 当前基线为 `10d7766 feat: complete step 4c settings shell slice`。
- 当前没有 `tools/verification/p11e_clipboard_hardening_checks.py`。
- 当前 `ClipboardStore.loadRepositoryState(limit:)` 会为 recent records 批量读取完整 payload。
- 当前 `ClipboardFloatingPanelView` 的普通卡片、列表行和 hover overlay 会获取 `appState.clipboardPayload(for:)`。
- 当前 `ClipboardRecordPreview` / `ClipboardDirectContentPreview` 会使用 payload text、URL、fileURL 或 image base64 生成默认 preview。
- 当前 BlocksCLI 未发现 clipboard payload 默认输出路径；后续仍需把“不新增默认 clipboard payload 输出”列入 Step 4D denylist。
- `ClipboardLiveCaptureService` 的 `summary` 可能来自正文短摘要；Step 4D 不能只延迟 `readPayload`，还需要定义 summary / redacted list 边界。
- 旧 P8/P9 门禁仍存在当前事实源或历史断言问题，不能直接作为 Clipboard hardening 阻断证据。

## 5. No-Go 原因

No-Go 原因不是“目标不清楚”，而是“当前无法把开发入口和接受出口写成足够小、足够可验证的 Step 4C 尾项”。

具体阻断点：

- P11E 尚不存在，无法在开发前确认 fail-closed 检查会捕捉默认 payload 预读和普通渲染读取。
- Read model 不是单点改动，至少影响 repository load、store cache、preview/search、AppState facade、panel list/card、hover detail、paste/copy 和 translation preview。
- `summary` 敏感级别未定义，直接使用 summary 仍可能让 redacted list 暴露正文片段。
- `repositoryUnavailable`、empty、unavailable、filtered、redacted 的 UI 承载点和 Store 状态来源还没有开发级方案。
- 旧 P8/P9 门禁需要迁移当前事实源，否则验收可能继续要求历史的不安全 payload preview 行为，或把旧 story / acceptance 当成阻断事实源。

## 6. 拆分后的范围边界

Step 4C 最终接受范围：

- Step 4C-1 ScreenshotStore。
- Step 4C-2 ShortcutStore。
- Step 4C-3 Settings shell split。
- 相关 P11A / P11C / P11D 和 P3 / P6 / P7 / P8G 门禁迁移。
- Step 4C-4 go/no-go 评估本身。

Step 4C 不接受范围：

- Clipboard hardening 实现。
- P11E 通过。
- 默认列表 / 普通面板 / Settings summary / CLI 默认输出不读取完整 payload。
- redacted list、repository unavailable 产品化、explicit payload read allowlist / denylist。
- Clipboard payload 读取日志、verification JSON、验收记录的完整低敏闭环。
- helper 生产写库、App Group、CLI 默认完整 payload、OCR、provider call、网络外发或 Keychain 相关新能力。

## 7. 下一步

- 写 Step 4D handoff record，明确未接受范围、拆分原因、后续 PRD / P11E / UX / 安全 / 测试门禁。
- 写 Step 4C 最终接受记录，仅接受 core。
- 提交本轮 4C-4 评估文档、Step 4D handoff、Step 4C 最终接受记录和项目索引更新。
- 下一阶段从 Step 4D PRD 开始，不直接派开发改 Clipboard 业务代码。
