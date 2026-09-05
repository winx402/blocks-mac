# P8-G Settings Shell Redesign

状态：implemented / pending manual UI review

## Scope

本 story 承接 [P8-F 苹果风格页面布局规范](../../../../调研与验证库/2026-07-03-P8-F苹果风格页面布局规范/README.md)，只处理主窗口设置外壳、左侧分类、页面 header、设置分组视觉和 Clipboard Privacy 子页面关系。

本轮不实现新的剪贴板历史能力、不改截图捕获、不新增 provider runtime、不启用 hook runtime。

## Implementation

- 主窗口左侧栏改为稳定的 Apple-style 分组：
  - Tools：Screenshot / Clipboard / Translation。
  - System：Shortcuts / Permissions。
  - Intelligence：Providers / Agent & CLI / Hooks。
  - Data：Data & Audit。
  - App：General。
- `Clipboard Privacy` 不再作为一级菜单项；它由 Clipboard 设置页中的入口进入，并在详情页显示 “Back to Clipboard”。
- 新增 `Agent & CLI`、`Hooks`、`Data & Audit` 三个设置 route：
  - Agent & CLI 承接 agent/MCP 读取剪贴板摘要、默认范围/时长和本地 CLI 名称。
  - Hooks 只表达 draft / enable confirmation 边界，不执行 hook。
  - Data & Audit 承接 provider audit summary 和本地数据边界说明。
- `SettingsSection` 从厚重 glass card 改成更轻的 group surface；避免 “section 里再放一堆 glass card” 的卡片套卡片问题。
- 新增三语 String Catalog 文案，覆盖 sidebar 分组、新 route、Clipboard Privacy 返回和 Data/Audit 文案。

## Acceptance Criteria

| Item | Status | Evidence |
| --- | --- | --- |
| Sidebar grouped by product/system/intelligence/data/app | passed | `p8g_settings_shell_redesign_checks.py` checks `SidebarGroup` definitions. |
| Clipboard Privacy is a Clipboard child page, not primary sidebar item | passed | Static gate verifies `.clipboardPrivacy` is not in sidebar groups and Clipboard row remains selected for child page. |
| Agent & CLI, Hooks, Data & Audit routes exist | passed | Static gate verifies `AppSection`, `ContentView`, and `SettingsViewMode` wiring. |
| Section surface no longer uses `glassSurface` | passed | Static gate verifies `SettingsSection` body has no `.glassSurface`. |
| zh-Hans / en / ja localization exists | passed | Static gate verifies required String Catalog keys in all three locales. |

## Verification

- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 tools/verification/p8g_settings_shell_redesign_checks.py --timeout 180`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

## Manual Review Notes

- 连续点击所有左侧菜单项，左侧栏应稳定，不应出现旧的 “工具/偏好” 模糊分组。
- Clipboard Privacy 应从 Clipboard 页面进入，并能返回 Clipboard。
- Provider、Agent & CLI、Hooks、Data & Audit 现在是独立信息架构入口；具体内容深度仍留到后续模块打磨。
