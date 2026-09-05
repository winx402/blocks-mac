# P8-I Settings 与 Clipboard 浮层系统化修复验收记录

状态：verified with automated gates / visual screenshot not covered
日期：2026-07-04

## 验收矩阵

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| Settings 不再调用旧 `SettingsSection` | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| `SettingsFormRow` 不渲染行内 icon badge | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| 右侧控件落在统一 trailing column | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| 主要 Settings route 接入统一 table row | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| Clipboard bottom frame 只读保存高度 | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| Clipboard bottom 宽度等于当前 screen visibleFrame | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| Clipboard panel 不可拖动位置 | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| 构建通过 | passed | `xcodebuild ... build` 已通过 |
| 运行验证通过 | passed | `./script/build_and_run.sh --verify` |
| String Catalog 校验 | passed | `python3 -m json.tool ...` 与 `xcstringstool compile --dry-run ...` |
| Action Schema 回归 | passed | `p2_action_smoke.py validate-schemas` 与 `smoke` |
| Markdown 本地链接检查 | passed | 本轮 9 个变更入口文档本地链接检查通过 |
| `git diff --check` | passed | 无 whitespace error |
| 敏感内容扫描 | passed | 未发现 secret / token 形态；验证脚本中的正则字面量不计入凭据 |
| 截图复核：Clipboard Settings | not_covered | 本轮未稳定进入指定 Settings route 截图；不能写成通过 |
| 截图复核：Providers Settings | not_covered | 本轮未稳定进入指定 Settings route 截图；不能写成通过 |
| 截图复核：Clipboard bottom panel | not_covered | 尝试以 `Control + Option + V` 触发后临时截图未出现 Clipboard panel；本轮不伪造视觉通过，需后续人工复核 |

## 说明

P8-H 仍是 partial fix。本记录只覆盖 P8-I 本轮收敛的 Settings 行模型和 Clipboard bottom panel 行为。自动门禁已覆盖结构与构建回归；三张指定视觉截图未完成，不作为通过项。Clipboard 条目内容专项、hover detail 边界避让、真实图片数据链路和 Clipboard 面板人工视觉复核另列后续任务。
