# Step 4 项目负责人开发复审派发 v0

状态：implementation-review-assigned
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 4 开发实现

## 1. 结论

Step 4 开发实现已通过项目负责人独立验证，现进入角色实现复审。

本轮只复审 Step 4，不进入 Step 5，也不启动 Step 6。

## 2. 派发对象

已派发：

- 代码审查：输出 `step_4/代码审查-Step4开发复审-v0.md`
- App 架构师：输出 `step_4/App架构师-Step4开发复审-v0.md`
- UI/交互设计师：输出 `step_4/UI-交互设计师-Step4开发复审-v0.md`
- 测试/质量：输出 `step_4/测试-质量-Step4开发复审-v0.md`
- 安全合规顾问：输出 `step_4/安全合规顾问-Step4开发复审-v0.md`

## 3. 通用约束

所有角色均按只读复审处理：

- 不修改业务代码、PRD 或技术方案。
- 不触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 可以读取文档、静态抽查、运行低敏 verifier / build / CLI help / `git diff --check`。
- 完成后优先写入指定复审文档；项目负责人通过读取文档收敛，不依赖会话回调。

## 4. 通用输入

- `AGENTS.md`
- 对应角色职责文档。
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发验收-v0.md`

## 5. 收敛规则

- 若任一角色发现 P0/P1，项目负责人形成复审收敛并派发开发返工。
- 若所有角色均无 P0/P1，项目负责人形成 Step 4 最终验收。
- P2 residual 需进入最终验收记录，不能被静默丢弃。
