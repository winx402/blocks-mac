# Step 4C-1 ScreenshotStore 主会 Stop/Go 记录 v0

日期：2026-07-06
角色：主 agent / 项目负责人 / 产品经理
结论：go-after-commit

## 1. 决策

Step 4C-1 ScreenshotStore 子批次接受，允许进入 Step 4C-2 ShortcutStore 准备，但必须先提交当前 Step 4C-1 交付物，保持下一子批次工作区干净。

本结论只覆盖 Step 4C-1 ScreenshotStore 与本轮安全 P1 低敏输出修复；不代表 ShortcutStore、Settings shell、Clipboard hardening 已完成或已验收。

## 2. 接受依据

- App 架构师实现复审：`approve-for-acceptance`，P0=0，P1=0。
- UI/交互实现复审：`approve-for-acceptance`，P0/P1 UI 阻断为 0。
- 测试/质量原始验收：`accepted-with-residual-risk`，P0=0，P1=0；P11A、P3C、P3D、P3E、P3F、P7Q、Blocks build、BlocksCLI build、`blocks --help`、`git diff --check` 均 PASS。
- 安全合规实现复审曾提出 P1：P3C/P3D/P3E/P3F/P5M 失败路径低敏输出不足。
- P1 修复后安全合规补充复审：`accepted-with-residual-risk`，P0=0，P1=0。
- P1 修复后测试/质量补充复验：`accepted-with-residual-risk`，P0=0，P1=0；P3C、P3D、P3E、P5M、P3F、P7Q、P11A、`git diff --check` 串行 PASS。

## 3. 范围确认

已接受范围：

- `ScreenshotStore` 成为截图事实与动作入口的 feature-level 事实源。
- `AppState.lastCaptureSummary` / `recentCaptures` 保持 computed facade，并桥接 `screenshotStore.objectWillChange`。
- Screenshot result presenter/view 通过窄 `routeResolver` closure 取得 AI route preview，不依赖 `EnvironmentObject AppState`。
- AI route preview 保持本地 preview：不上传图片、不调用 provider。
- P11A 覆盖 target membership、AppState facade/objectWillChange、旧事实源处理、forbidden token、权限顺序、narrow presenter/resolver、低敏输出。
- P3C/P3D/P3E/P3F/P5M/P7Q 失败输出接入共享 `verification_sanitizer.py`；P11A 的 `sanitized_failure_output` 对六个脚本 fail closed。

未接受 / 未启动范围：

- Step 4C-2 ShortcutStore。
- Step 4C-3 Settings shell split。
- Conditional Step 4C-4 Clipboard hardening。
- 真实 provider 调用、真实 OCR、图片上传、多模态外发。
- ScreenCaptureKit 低层截图服务重写。

## 4. 残余风险接受

主会接受以下 P2 残余风险，不阻断 Step 4C-1 提交：

- 未覆盖真实 region/window/fullscreen 截图实物验收。
- 未覆盖真实 TCC 缺权、授权撤销、刚授权需重启路径。
- 未实物操作 Screenshot Result 面板 copy/save/retake/close。
- 未做多语言 / VoiceOver 实机验收。
- 既有 `FloatingPanelSupport.swift` MainActor/NSApp warning 与 AppIntents metadata skipped warning 仍存在，但未导致本轮门禁失败。

这些残余风险不得在后续文档中写成已完成实物验收；如后续切片触碰相关路径，必须重新评估是否升级为阻断门禁。

## 5. 下一步协议

- 先提交 Step 4C-1 代码、verifier 和文档交付物。
- 提交完成前不得启动 Step 4C-2 开发。
- Step 4C-2 仍需按 PRD 的子批次硬门禁执行：独立开发记录、必要专项复审、测试/质量验收记录、主会 stop/go；前一子批次 P0/P1 未关闭不得进入后一子批次。
- 若 Step 4C-2 开发或验收发现 4C-1 残余风险实际影响用户路径，主会需重新打开对应风险项，不得用本记录豁免。
