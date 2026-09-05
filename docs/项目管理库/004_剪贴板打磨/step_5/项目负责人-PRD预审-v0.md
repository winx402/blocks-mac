# Step 5 PRD 预审 v0

状态：approve-for-role-review
日期：2026-07-07
角色：项目负责人
对象：`step_5/产品经理-PRD-v0.md`

## 1. 结论

结论：`approve-for-role-review`。

产品经理 Step 5 PRD v0 可以进入角色复审。当前没有必须回到用户处澄清的问题。

## 2. 预审判断

PRD v0 已覆盖 Step 5 派发范围：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 下可识别 `.app`。
- 真实系统 App 图标、图标失败 fallback、搜索、过滤、稳定排序、大量 App、局部失败状态均有产品口径。
- 重复名称、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败等边界对象均有首版行为。
- CLI 广义对象管理与 UI 分层，覆盖 app bundle、bundle id、app path、登录项、helper、launch label、command path 等 typed subject。
- CLI 输出、ambiguity、dry-run、confirm、dangerous action blocked 和低敏证据均有验收口径。
- 本地枚举、本地展示、不上传 provider、不静默请求 ScreenCapture / Accessibility / Automation / Full Disk Access、不 TCC reset、不打开 System Settings 的边界清楚。

PRD v0 未越界：

- 未重开 Step 1 明文展示 / 搜索 / OCR。
- 未重开 Step 2 标签 / 收藏。
- 未重开 Step 3 面板布局。
- 未重开 Step 4 详情编辑。
- 未进入技术方案或代码实现。

## 3. 需要复审重点

### UI/交互设计师

- App row 信息密度、长文本、路径摘要、状态与异常标记的布局。
- 搜索 / 过滤 / 排序在大量 App 下是否易用。
- 图标 fallback、duplicate、missing bundle id、damaged、hidden 等状态表达。
- 键盘导航和 VoiceOver 语义。

### App 架构师

- 三目录 `.app` 枚举、真实图标读取、缓存和 identity model 可落地性。
- 重复 bundle id / 无 bundle id / damaged app 的策略事实源边界。
- UI 与 CLI 的策略事实源关系。
- CLI typed subject model、subject_ref、冲突解析、登录项/helper/command path 的本地枚举边界。

### 测试/质量

- UI fixture、CLI fixture、性能和失败态验收是否足够可测。
- 搜索、过滤、稳定排序、大量 App、图标失败、策略失败、低敏输出的 pass/fail 口径。
- 是否需要 Step 5 专属 P13E 或等价门禁。

### 安全合规顾问

- 本地 App 枚举和路径展示的低敏边界。
- CLI 管理登录项、helper、命令行工具的滥用风险。
- dangerous action blocked 是否足够明确。
- provider 不上传、权限不静默请求、TCC / System Settings 不触发是否可验收。

## 4. 下一步

派发 UI/交互设计师、App 架构师、测试/质量、安全合规顾问进行 Step 5 PRD v0 复审。复审完成后由项目负责人收敛是否需要产品经理产出 PRD v1。
