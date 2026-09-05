# 架构升级阶段总览

状态：step-5-accepted
最后审阅：2026-07-06
来源级别：project plan

本项目按“先设计评审，再开发测试，再验收关闭”推进。Step 2 第一阶段已经完成开发、测试、架构师复审和验收；Step 3 PRD / 方案已完成复审、开发、测试/质量验收、App 架构师最终实现复审和主 agent 最终接受；Step 4A rebaseline 已完成第一轮回写，Step 4B PermissionStore、Step 4C core 和 Step 4D Clipboard hardening 已完成开发、复审、验收和主 agent 最终接受。Step 5 门禁、清理与关闭已完成并接受，状态为 `step-5-accepted`。

## 阶段划分

| 阶段 | 状态 | 目标 | 主要产物 | 出口 |
| --- | --- | --- | --- | --- |
| Step 1：架构盘点与目标方案 | reviewed | 明确当前架构问题、目标分层、迁移顺序和验收门禁。 | 架构升级方案 v0、App 架构师评审、方案修订。 | 已形成第一阶段实施计划。 |
| Step 2：Clipboard 架构第一阶段 | accepted | 围绕既有 `ClipboardRepository` 建立 `ClipboardStore` / 用例层和行为保全门禁。 | 实施计划、开发记录、测试记录、架构复看、验收记录。 | 已通过 App / CLI build、P4/P5/P8/P9 门禁和架构师复审。 |
| Step 3：核心状态拆分 | accepted | 将 `AppState` 从跨域业务容器降级为 app shell / coordinator。 | [Step 3 核心状态拆分与 Provider 契约 PRD / 实施方案 v0](step_3/PRD-核心状态拆分与Provider契约-v0.md)、[开发记录 v0](step_3/开发记录-v0.md)、[验收记录 v0](step_3/验收记录-v0.md)、[App 架构师复审 v0](step_3/2026-07-05-App架构师复审-v0.md)、[最终接受记录 v0](step_3/最终接受记录-v0.md)。 | 已通过开发、测试/质量验收、架构复审和主 agent 最终接受。 |
| Step 4：Feature 模块迁移 | accepted | 根据 Step 3 结果迁移 Permission、Screenshot、Shortcut、Settings shell，并完成 Clipboard hardening。 | [Step 4 Feature 模块迁移预初始化 PRD v0](step_4/PRD-Feature模块迁移预初始化-v0.md)、[Step 4B PermissionStore 单切片 PRD v0](step_4/PRD-Step4B-PermissionStore-v0.md)、[Step 4C 剩余 Feature 收口 PRD v0](step_4/PRD-Step4C-剩余Feature收口-v0.md)、[Step 4D Clipboard hardening PRD v0](step_4/PRD-Step4D-ClipboardHardening-v0.md)、[Step 4 Feature 模块迁移最终接受记录 v0](step_4/最终接受记录-Step4-v0.md)。 | 已通过 B/C/D 子阶段开发、复审、验收和主 agent 最终接受。 |
| Step 5：门禁、清理与关闭 | accepted | 清理旧路径、死代码和临时兼容层，补齐自动化和低敏实物证据。 | [Step 5 门禁、清理与关闭 PRD v0](step_5/PRD-Step5-门禁清理关闭-v0.md)、[开发记录 v0](step_5/开发记录-Step5-门禁清理关闭-v0.md)、[验收记录 v0](step_5/验收记录-Step5-门禁清理关闭-v0.md)、[最终接受记录 v0](step_5/最终接受记录-Step5-v0.md)。 | 已接受；是否另开后续专项由最终接受记录判断。 |

## 推进原则

- 每个阶段先有方案或实施计划，再允许开发。
- 架构师评审未完成前，不派开发改核心边界。
- 开发阶段优先拆垂直模块，不做无验收目标的大范围格式化或搬文件。
- 每个阶段验收通过后按项目规则直接提交。
- 如果发现方案假设不成立，先更新本项目文档，再调整实施。

## 子 agent 参与建议

- App 架构师：Step 1 / Step 2 必须评审目标分层、状态边界和迁移风险。
- 开发：只在方案确认后承接明确文件范围的实施任务。
- 测试/质量：在 Step 2 前补自动化门禁策略；在每个迁移阶段做回归验收。
- 安全合规顾问：审查剪贴板、截图、OCR、provider 外发、Keychain、日志和 agent/CLI 默认读取边界。
- 执行助理：整理文件盘点、依赖图、历史文档链接和验证命令，不做架构取舍。

## 当前下一步

1. 按需开启发布前真实 UI / VoiceOver / 多语言专项验收。
2. 按需开启 packaging / notarization、future helper/App Group、真实 OCR/provider 图片外发等独立专项。
3. 后续专项继续遵循先 PRD、再开发、再验收、再提交。
