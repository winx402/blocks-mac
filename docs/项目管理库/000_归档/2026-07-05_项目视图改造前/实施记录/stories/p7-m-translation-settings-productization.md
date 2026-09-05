# P7-M Translation 与 Settings 产品化

状态：implemented / translation shortcut core path passed in P7-O / settings screenshot review pending

## Scope

P7-M 只做 Translation 浮层和 Settings 的产品化收敛，不新增真实 OCR、截图外发、provider 商业策略或费用提示。

## Changes

- Translation 浮层保持左右分栏和自动翻译；route / audit / provider 诊断默认折叠到“连接详情”。
- Translation 设置页只表达默认偏好；浮层表达本次检测源语言和实际目标语言。
- Settings 主导航保持七个设置分类：Screenshot、Clipboard、Translation、Shortcuts、Providers、Permissions、General。
- Providers 页面继续按模型服务、翻译服务、OCR 服务组织，高级诊断保持在页面内但不作为普通用户主任务。

## Verification

- `python3 tools/verification/p7m_translation_settings_productization_checks.py`
- `python3 tools/verification/p5q_translation_language_error_ux_checks.py --timeout 180`
- `python3 tools/verification/p7h_translation_swap_result_sync_checks.py`

## Manual Acceptance

- P7-O 已验证 `Control + Option + D` 能打开翻译浮层，读取剪贴板文本并展示 Local Mock 翻译结果。
- 交换语言后，顶部语言、结果卡片和复制内容一致。
- 普通用户不需要理解 `route`、`audit id`、`adapter` 或工程阶段名即可判断设置状态。
