# Step 5 PRD v1 预审 v0

状态：approve-for-targeted-role-review
日期：2026-07-07
角色：项目负责人
对象：`step_5/产品经理-PRD-v1.md`

## 1. 结论

结论：`approve-for-targeted-role-review`。

产品经理 Step 5 PRD v1 已按 [PRD 复审收敛 v0](项目负责人-PRD复审收敛-v0.md) 回写九个 P1，可以进入 UI/交互、App 架构师、测试/质量、安全合规顾问的定向复审。

本轮预审未发现需要回用户澄清的问题，也未发现 PRD v1 把 Step 1-4 或 Step 6 重新拉入 Step 5。

## 2. 预审判断

PRD v1 已补齐以下关键口径：

- 明确 Step 5 UI 首版支持 App 级策略变更，不是只读状态页。
- 明确策略状态机：pending、saving、saved、failed、retry、cancel、unsupported。
- 明确 duplicate bundle id 共享策略影响范围和 mutation 前说明。
- 明确三目录 `.app` 采用受控递归，`.app` bundle 是枚举叶子。
- 明确 `AppInstance` / `PolicySubject` / `PolicyRule` 三层产品事实模型。
- 明确 UI 与 CLI 必须共享同一隐私策略事实源。
- 明确 CLI typed subject、`subject_ref` opaque / stable、本地解析边界和 ambiguous 不 mutation。
- 明确 CLI / audit / verification JSON 默认低敏，不输出完整真实路径清单。
- 明确 `--confirm` / `--yes` 只确认本 App policy mutation，系统动作 hard-block。
- 将 P13E 或等价 fail-closed gate 写成 Step 5 hard gate。
- 要求技术方案提供性能数值阈值，缺数值不得进入开发。

PRD v1 保留了 Step 5 正确边界：

- UI 默认三目录真实 `.app`。
- CLI 管理 UI 外广义对象，但只管理本 App 隐私策略事实源。
- 不上传 provider。
- 不静默权限。
- 不 TCC reset。
- 不打开 System Settings / Finder。
- 不启动 App。
- 不执行命令。
- 不做登录项 / helper / CLI 工具生命周期管理。

## 3. 定向复审重点

### UI/交互设计师

- UI 首版可写策略是否有足够清晰的行内状态、失败反馈、retry / cancel 和 duplicate bundle id 影响范围体验。
- App row 信息结构、长文本、异常标记、窄宽度、键盘和 VoiceOver 验收是否足够。
- 搜索、过滤、排序、partial / loading 组合状态是否仍有 P1 缺口。

### App 架构师

- 受控递归、`.app` 叶子、单一策略事实源、三层事实模型是否可作为技术方案输入。
- `bundle_id` / `app_path` precedence、path-scoped override、missing bundle id、damaged app 是否仍需产品层再定。
- CLI typed subject、`subject_ref`、本地解析边界是否足够硬。

### 测试/质量

- PRD v1 是否足以转化为 P13E hard gate。
- UI / CLI fixture、edge case matrix、性能阈值要求、低敏输出 fail-closed 是否可测。
- UI 可写策略是否需要额外 pass/fail 矩阵。

### 安全合规顾问

- 低敏输出合同是否覆盖 CLI、audit、verification JSON、日志和验收记录。
- dangerous action hard-block 与 `--confirm` 语义是否足够明确。
- command_path、login item、helper、launch_label 的 CLI 解析边界是否避免系统动作和误操作。

## 4. 需要角色判断的问题

本轮不是全量重审 v0。请角色聚焦：

- v0 复审提出的 P1 是否已关闭。
- 是否出现新的 P0 / P1。
- 若只有 P2，是否可进入 Step 5 技术方案。

## 5. 本轮验证

项目负责人已读取 PRD v1，并运行：

```bash
rg -n "UI 首版支持|受控递归|AppInstance|PolicySubject|PolicyRule|subject_ref|低敏输出|dangerous|P13E|large-list|缺数值不得进入开发|Step 6|不执行命令" docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md
wc -l docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md
git diff --check
```

结果：PASS。
