# 003_架构升级

状态：step-5-accepted
最后审阅：2026-07-06
来源级别：project control

本项目承接积木工具 App 的整体架构升级。目标不是继续局部修补，而是在已有多轮迭代基础上重新确定分层、模块边界、状态管理、数据流、平台适配和验证门禁，再按阶段迁移。

当前已完成方案草案、App 架构师评审、Step 2 第一阶段开发、测试、架构复审和验收。第一阶段只做 ClipboardStore 边界迁移，不做功能新增。Step 3 PRD / 方案已完成复审、开发实施、测试/质量独立验收、App 架构师最终实现复审和主 agent 最终接受；Step 4A rebaseline 已完成第一轮回写；Step 4B PermissionStore、Step 4C core 和 Step 4D Clipboard hardening 均已完成开发、复审、验收和主 agent 最终接受。Step 5 门禁、清理与关闭已完成并接受，状态为 `step-5-accepted`。

## 当前文档

- [阶段总览](step.md)：记录架构升级的阶段拆分、进入条件和验收出口。
- [Step 1 架构升级方案 v0](step_1/架构升级方案-v0.md)：当前方案，包含现状判断、目标架构、迁移策略和测试门禁。
- [2026-07-05 App 架构师评审 v0](step_1/2026-07-05-App架构师评审-v0.md)：对方案的 `approve-with-changes` 评审意见。
- [Step 2 第一阶段实施计划 v0](step_2/第一阶段实施计划-v0.md)：按评审意见收敛后的首轮开发计划。
- [Step 2 开发记录 v0](step_2/开发记录-v0.md)：第一阶段实现范围、验证记录和剩余风险。
- [2026-07-05 App 架构师复审 v0](step_2/2026-07-05-App架构师复审-v0.md)：对 Step 2 实现的 `approve-for-acceptance` 复审意见。
- [Step 2 验收记录 v0](step_2/验收记录-v0.md)：第一阶段最终验收记录。
- [Step 3 核心状态拆分与 Provider 契约 PRD / 实施方案 v0](step_3/PRD-核心状态拆分与Provider契约-v0.md)：核心状态拆分、Provider / Translation 边界、route/runtime 契约和角色流程协议。
- [2026-07-05 App 架构师方案复审 v0](step_3/2026-07-05-App架构师方案复审-v0.md)：对 Step 3 PRD 的 `approve-with-changes` 复审意见，必改项已回写方案。
- [2026-07-05 安全合规方案复审 v0](step_3/2026-07-05-安全合规方案复审-v0.md)：对 Step 3 PRD 的 `approve-with-changes` 安全边界复审意见，必改项已回写方案。
- [Step 3 开发记录 v0](step_3/开发记录-v0.md)：开发实施范围、验证命令结果、未完成项和残余风险。
- [Step 3 验收记录 v0](step_3/验收记录-v0.md)：测试/质量独立验收记录，结论为 `accepted`。
- [2026-07-05 App 架构师复审 v0](step_3/2026-07-05-App架构师复审-v0.md)：对 Step 3 最终实现的 `approve-for-acceptance` 复审意见。
- [Step 3 最终接受记录 v0](step_3/最终接受记录-v0.md)：主 agent 最终接受记录，限定 Step 3 接受范围并列出转入 Step 4 的风险。
- [Step 4 Feature 模块迁移预初始化 PRD v0](step_4/PRD-Feature模块迁移预初始化-v0.md)：Step 4 候选范围、进入条件、角色预审和 Step 3 accepted 后 rebaseline。
- [2026-07-05 App 架构师预审 v0](step_4/2026-07-05-App架构师预审-v0.md)：对 Step 4 预初始化 PRD 的 `approve-with-changes` 预审意见，切片拆分和 store 依赖边界已回写预案。
- [2026-07-05 安全合规预审 v0](step_4/2026-07-05-安全合规预审-v0.md)：对 Step 4 预初始化 PRD 的 `approve-with-changes` 预审意见，敏感 API token、preview-only 和低敏验收边界已回写预案。
- [2026-07-05 测试质量预审 v0](step_4/2026-07-05-测试质量预审-v0.md)：对 Step 4 预初始化 PRD 的 `approve-with-changes` 预审意见，P11、切片门禁和实物证据必改项已回写预案。
- [2026-07-05 UI 交互预审 v0](step_4/2026-07-05-UI交互预审-v0.md)：对 Step 4 预初始化 PRD 的 `approve-with-changes` 预审意见，Settings shell UX contract 和体验验收门槛已回写预案。
- [Step 4B PermissionStore 单切片 PRD v0](step_4/PRD-Step4B-PermissionStore-v0.md)：基于 Step 3 accepted 基线选择 PermissionStore 单切片，当前状态为 `accepted`。
- [2026-07-05 App 架构师 Step4B 方案复审 v0](step_4/2026-07-05-App架构师Step4B方案复审-v0.md)：对 Step 4B PRD 的 `approve-for-development` 复审意见，未发现 P0/P1。
- [2026-07-05 安全合规 Step4B 方案复审 v0](step_4/2026-07-05-安全合规Step4B方案复审-v0.md)：对 Step 4B PRD 的 `approve-with-changes` 安全复审意见，系统动作 token 和用户触发验证已回写 PRD。
- [2026-07-05 测试质量 Step4B 方案复审 v0](step_4/2026-07-05-测试质量Step4B方案复审-v0.md)：对 Step 4B PRD 的 `approve-with-changes` 复审意见，P11B 统一入口、fail closed 和旧门禁事实源要求已回写 PRD。
- [2026-07-05 UI 交互 Step4B 方案复审 v0](step_4/2026-07-05-UI交互Step4B方案复审-v0.md)：对 Step 4B PRD 的 `approve-with-changes` 复审意见，体验验收补充项已回写 PRD。
- [Step 4B PermissionStore 开发记录 v0](step_4/开发记录-Step4B-PermissionStore-v0.md)：Step 4B 开发完成记录，包含改动范围、验证结果、未覆盖项和安全隐私声明。
- [2026-07-06 App 架构师 Step4B 实现复审 v0](step_4/2026-07-06-App架构师Step4B实现复审-v0.md)：对 Step 4B 实现的 `approve-for-acceptance` 复审意见，P0/P1 为 0。
- [Step 4B PermissionStore 验收记录 v0](step_4/验收记录-Step4B-PermissionStore-v0.md)：测试/质量独立验收记录，结论为 `changes-requested`，P1 为 P7R 旧归档事实源仍作为阻断输入。
- [Step 4B PermissionStore P1 修复开发记录 v0](step_4/开发记录-Step4B-PermissionStore-P1修复-v0.md)：修复 P7R 旧归档阻断事实源问题，P7R 阻断证据切换到 Step 4B 当前 PRD 和开发记录。
- [Step 4B PermissionStore P1 修复补充复验记录 v0](step_4/验收记录-Step4B-PermissionStore-P1复验-v0.md)：测试/质量补充复验记录，结论为 `accepted-with-residual-risk`，P1 已关闭且未发现新增 P0/P1。
- [2026-07-06 安全合规 Step4B 实现复审 v0](step_4/2026-07-06-安全合规Step4B实现复审-v0.md)：对 Step 4B 实现的 `approve-for-acceptance` 安全复审意见，P0/P1 为 0。
- [Step 4B PermissionStore 最终接受记录 v0](step_4/最终接受记录-Step4B-PermissionStore-v0.md)：主 agent 最终接受记录，限定接受范围和残余风险。
- [Step 4C 剩余 Feature 收口 PRD v0](step_4/PRD-Step4C-剩余Feature收口-v0.md)：统一评估 ScreenshotStore、ShortcutStore、Settings shell split 和 conditional Clipboard hardening 的收口方案，core 子批次已接受。
- [2026-07-06 App 架构师 Step4C 方案复审 v0](step_4/2026-07-06-App架构师Step4C方案复审-v0.md)：对 Step 4C PRD 的 `approve-with-changes` 复审意见，P1 已回写 PRD。
- [2026-07-06 UI 交互 Step4C 方案复审 v0](step_4/2026-07-06-UI交互Step4C方案复审-v0.md)：对 Step 4C PRD 的 `changes-requested` 复审意见，P1 已回写 PRD。
- [2026-07-06 测试质量 Step4C 方案复审 v0](step_4/2026-07-06-测试质量Step4C方案复审-v0.md)：对 Step 4C PRD 的 `changes-requested` 复审意见，P1 已回写 PRD。
- [2026-07-06 安全合规 Step4C 方案复审 v0](step_4/2026-07-06-安全合规Step4C方案复审-v0.md)：对 Step 4C PRD 的 `approve-with-changes` 复审意见，P1 已回写 PRD。
- [2026-07-06 App 架构师 Step4C P1 回写复审 v0](step_4/2026-07-06-App架构师Step4C-P1回写复审-v0.md)：结论 `p1-closed-with-notes`，无新增 P0/P1。
- [2026-07-06 UI 交互 Step4C P1 回写复审 v0](step_4/2026-07-06-UI交互Step4C-P1回写复审-v0.md)：结论 `p1-closed-with-notes`，无新增 P0/P1。
- [2026-07-06 测试质量 Step4C P1 回写复审 v0](step_4/2026-07-06-测试质量Step4C-P1回写复审-v0.md)：结论 `p1-closed-with-notes`，无新增 P0/P1。
- [2026-07-06 安全合规 Step4C P1 回写复审 v0](step_4/2026-07-06-安全合规Step4C-P1回写复审-v0.md)：结论 `p1-closed-with-notes`，无新增 P0/P1。
- [Step 4C-1 ScreenshotStore 主会 Stop/Go 记录 v0](step_4/主会Stop-Go-Step4C-1-ScreenshotStore-v0.md)：主会接受 ScreenshotStore 子批次，结论 `go-after-commit`。
- [Step 4C-2 ShortcutStore 主会 Stop/Go 记录 v0](step_4/主会Stop-Go-Step4C-2-ShortcutStore-v0.md)：主会接受 ShortcutStore 子批次，结论 `go-after-commit`。
- [Step 4C-3 Settings shell 主会 Stop/Go 记录 v0](step_4/主会Stop-Go-Step4C-3-SettingsShell-v0.md)：主会接受 Settings shell split 子批次，结论 `go-after-commit`。
- [Step 4C-4 Clipboard hardening 主会 Stop/Go 记录 v0](step_4/主会Stop-Go-Step4C-4-ClipboardHardening-v0.md)：主会选择 `no-go-split-to-step4d`，不在 Step 4C 内启动 Clipboard hardening 开发。
- [Step 4D Clipboard hardening handoff v0](step_4/Step4D-Handoff-ClipboardHardening-v0.md)：Clipboard hardening 拆出后的 PRD / P11E / UX / 安全 / 测试交接记录。
- [Step 4C core 最终接受记录 v0](step_4/最终接受记录-Step4C-Core-v0.md)：主 agent 最终接受 Step 4C core，明确 Clipboard hardening 未完成并转 Step 4D。
- [Step 4D Clipboard hardening PRD v0](step_4/PRD-Step4D-ClipboardHardening-v0.md)：默认 read model、payload allowlist / denylist、summary 敏感级别、P11E、UX 状态和低敏验收矩阵。
- [Step 4D Clipboard hardening 开发记录 v0](step_4/开发记录-Step4D-ClipboardHardening-v0.md)：Step 4D 实现范围、P11E-first 结果、purpose-keyed cache、pinned displayName P1 修复和验证记录。
- [2026-07-06 App 架构师 Step4D 实现复审 v0](step_4/2026-07-06-App架构师Step4D实现复审-v0.md)：结论 `approve-for-acceptance`，P0/P1 为 0。
- [2026-07-06 安全合规 Step4D 实现复审 v0](step_4/2026-07-06-安全合规Step4D实现复审-v0.md)：结论 `accepted-with-residual-risk`，P0/P1 为 0。
- [2026-07-06 UI 交互 Step4D 实现复审 v0](step_4/2026-07-06-UI交互Step4D实现复审-v0.md)：初审结论 `changes-requested`，P1 为 default search 仍使用 historical pinned `displayName`。
- [2026-07-06 UI 交互 Step4D P1 修复补充复审 v0](step_4/2026-07-06-UI交互Step4D-P1修复补充复审-v0.md)：结论 `p1-closed`，UI/交互侧 P0/P1 清零。
- [Step 4D Clipboard hardening 验收记录 v0](step_4/验收记录-Step4D-ClipboardHardening-v0.md)：测试/质量独立验收记录，结论 `accepted-with-residual-risk`，P0/P1 为 0。
- [Step 4D Clipboard hardening 最终接受记录 v0](step_4/最终接受记录-Step4D-ClipboardHardening-v0.md)：主 agent 最终接受 Step 4D，限定接受范围与残余风险。
- [Step 4 Feature 模块迁移最终接受记录 v0](step_4/最终接受记录-Step4-v0.md)：主 agent 最终接受 Step 4，明确进入 Step 5。
- [Step 5 门禁、清理与关闭 PRD v0](step_5/PRD-Step5-门禁清理关闭-v0.md)：定义 AppModel 替换、helper/debug target 删除、P12 门禁和低敏实物证据阻断项。
- [Step 5 门禁、清理与关闭开发记录 v0](step_5/开发记录-Step5-门禁清理关闭-v0.md)：Step 5 实现范围、自动化门禁和 fresh build 记录。
- [Step 5 门禁、清理与关闭验收记录 v0](step_5/验收记录-Step5-门禁清理关闭-v0.md)：验收结论 `accepted-with-residual-risk`，P0/P1 为 0。
- [Step 5 最终接受记录 v0](step_5/最终接受记录-Step5-v0.md)：主 agent 接受记录，状态 `step-5-accepted`。

## 项目目标

- 让 App 从“多轮迭代累积的功能集合”收敛为清晰的分层架构。
- 降低 `AppState`、大型 SwiftUI View、通用 `Service` 和跨域状态耦合带来的维护成本。
- 建立 feature module、domain store、use case、platform adapter、repository 和 app shell 的职责边界。
- 在不为了兼容历史包袱牺牲合理性的前提下，保持用户可见行为可回归、可验收。
- 让后续子 agent 的方案、开发、评审和验收输出都沉淀在本项目目录。

## 当前状态

- 已完成第一版方案草案。
- App 架构师已评审，结论为 `approve-with-changes`。
- 已将有价值意见回写方案，并形成第一阶段实施计划。
- Step 2 第一阶段已完成开发、回归、架构师复审和验收。
- Step 3 已产出 PRD / 实施方案，已回写 App 架构师与安全合规方案复审意见，并已完成开发、测试/质量独立验收、App 架构师最终实现复审和主 agent 最终接受。
- Step 4A rebaseline 已完成第一轮回写；Step 4B PermissionStore、Step 4C core 和 Step 4D Clipboard hardening 已完成开发、复审、验收和主 agent 最终接受。
- Step 5 门禁、清理与关闭已完成开发、自动化回归、低敏 UI/TCC evidence、验收记录和最终接受，状态为 `step-5-accepted`。
- Step 4 已完成预初始化、B/C/D 子阶段开发、复审、验收和最终接受。

## 目录规则

- 本项目按阶段管理，`step.md` 是阶段总览。
- `step_1/`：架构盘点、目标方案、评审记录。
- `step_2/`：第一阶段实施计划、开发输出、测试记录、架构复看和验收记录。
- `step_3/`：核心状态拆分、Provider / Translation 契约、开发记录、复审和验收记录。
- `step_4/`：Feature 模块迁移预案、角色预审、最终 PRD、开发记录、复审和验收记录。
- 后续如进入新的专项阶段，继续按阶段目录沉淀方案、子 agent 输出、评审和验收记录。
- 不在项目根层散落临时结论；所有子 agent 输出必须进入对应阶段目录。

## 关联入口

- [项目管理库](../index.md)
- [正式 App Scaffold 架构](../../技术知识库/正式AppScaffold架构-v0.md)
- [App 数据存储架构规范](../002_剪贴板持久化/数据存储架构规范-v0.md)
