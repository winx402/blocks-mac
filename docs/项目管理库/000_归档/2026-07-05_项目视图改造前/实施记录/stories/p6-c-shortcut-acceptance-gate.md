# P6-C Shortcut Acceptance Gate

状态：implemented
日期：2026-07-03
来源：P6-B 后续低敏验收与稳定化

## 目标

把 `Option+A`、`Option+V`、`Option+D` 的可配置快捷键从“能注册”推进到“可诊断、可重新注册、可人工验收”：

- Settings 显示已注册、已禁用、失败数量。
- Settings 提供重新注册快捷键入口。
- 人工验收清单明确覆盖 Option+A 区域截图、Option+V 剪贴板浮层、Option+D 翻译浮层。
- 自动化只验证 wiring 和状态展示，不伪造真实系统按键触发结果。

## 实现范围

- AppState 新增快捷键注册统计和刷新状态。
- Settings 新增 `ShortcutDiagnosticsSummary`。
- 新增 P6-C 验证脚本，回归 P6-B 并检查本地化、隐私边界和 story 记录。

## 边界

- 不实现系统保留快捷键检测或冲突自动修复。
- 不读取剪贴板完整历史、不调用 provider、不执行 CLI。
- 真实热键触发仍需要用户在低敏屏幕环境做低敏人工验收。

## 验证

- `python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py --timeout 180`
- `python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py --timeout 180`
