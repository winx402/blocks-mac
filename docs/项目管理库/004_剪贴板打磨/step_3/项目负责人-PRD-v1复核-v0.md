# Step 3 项目负责人 PRD v1 复核 v0

状态：prd-accepted
日期：2026-07-07
角色：项目负责人
对象：`step_3/产品经理-PRD-v1.md`

## 1. 结论

Step 3 PRD v1 接受，可以进入技术方案阶段。

本阶段继续只覆盖面板交互与布局打磨，不进入 Step 1 搜索/OCR 底座、Step 2 标签事实源、Step 4 详情编辑或 Step 5 隐私页 App 管理。

## 2. 复核结果

PRD v1 已吸收 `项目负责人-PRD复审收敛-v0.md` 的 must-change：

- 已按当前事实写明 Step 1 / Step 2 已验收接受。
- 已移除 Step 1 / Step 2 未闭合时的实现分支。
- 已补 hover 首版规则：安全桥 + 短延迟收起 + 明显离开收起，并给出 pass/fail。
- 已补 toolbar 空间优先级、右侧关键操作清单、宽 / 常规 / 窄 / 最小可用窗口矩阵。
- 已补 selected / focused / hover / active filter 层级和 selected/focused 先写、paste/detail/OCR retry 后做的证据口径。
- 已明确至少替换面板顶部 active 单击 / 双击 `Menu`，不得继续用下拉作为 active 切换入口；设置页如提供同一设置，必须同 key `clipboard.panel.pasteActivationMode`。
- 已拆分 side list row 与 bottom tray card 密度验收。
- 已补 fixture、截图 / 录屏、键盘、VoiceOver 矩阵。
- 已定义 Step 3 专属门禁 P13C 或等价 gate 的最低断言。

## 3. 复核命令

项目负责人本轮执行：

```bash
sed -n '1,320p' docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md
sed -n '320,460p' docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md
rg -n "Step 1|Step 2|安全桥|短延迟|明显离开|右侧关键|最小可用|selected|focused|hover|active filter|clipboard\\.panel\\.pasteActivationMode|Menu|下拉|side list|bottom tray|P13C|真实剪贴板|二维码|Authorization|VoiceOver" docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md
wc -l docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md
git diff --check
```

结果：

- PRD v1 文件存在，共 437 行。
- 关键收敛口径均可定位。
- `git diff --check` 通过。

## 4. 残余边界

PRD v1 仍把以下事项留给技术方案，不影响 PRD 接受：

- hover 延迟毫秒数、hit-test 区域、距离阈值和动画曲线。
- 具体 px 断点、search min width、filter max width 和固定操作区尺寸。
- 显性控件采用 segmented control、radio group、按钮组或等价控件。
- side list row 与 bottom tray card 的 padding、lineLimit、最小高度、缩略图尺寸和状态槽位尺寸。
- P13C 的具体脚本名称和实现方式。

这些均属于技术方案应确认的实现细节，PRD 已给出用户可见结果、pass/fail 和最低门禁。

## 5. 下一步

派发 App 架构师产出 Step 3 技术方案 v0，重点覆盖：

- SwiftUI hover 安全区域 / 延迟收起实现。
- toolbar 空间优先级和窗口矩阵落地方式。
- selected / focused 状态更新顺序与低敏事件证据。
- 面板顶部 active `Menu` 退出和显性控件状态绑定。
- side list row / bottom tray card 密度与尺寸稳定。
- P13C 或等价门禁设计。
