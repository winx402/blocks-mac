# P7-S Alpha Readiness Final Record

日期：2026-07-03
状态：`alpha readiness baseline updated`
运行 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`
Bundle ID：`com.jdtool.app`

## 关闭项

| 来源 | 项目 | 结果 |
| --- | --- | --- |
| P7-O | Stable signing / Screen Recording / Accessibility / Region screenshot / Clipboard paste / Translation shortcut | `passed` |
| P7-P | Existing TCC gate、P7-O facts、stale docs cleanup | `passed` |
| P7-Q | Screenshot Window hover/cancel/capture | `passed` |
| P7-Q | Screenshot Fullscreen capture | `passed` |
| P7-R | Permission Assist granted close condition and static UX gate | `passed` |

## 当前 Alpha 基线

- `Control + Option + A/V/D` 是当前可靠默认快捷键。
- Screenshot Region / Window / Fullscreen 都已在当前稳定 App 上真实触发，并出现结果浮层。
- Clipboard 浮层、Return / 双击低敏 fixture 自动粘贴核心路径已通过 P7-O。
- Translation 浮层、Local Mock 自动翻译和结果展示已通过 P7-O/P7-M/P5-Q 前置门禁。
- Settings 权限页可以展示稳定签名、Team ID、App path、TCC 状态和 Permission Assist 入口。

## 剩余 not covered / deferred

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| Permission Assist revoked-flow | `not_covered_environment` | 当前 TCC 已 granted；不使用 `tccutil reset`，因此完整引导动画和目标页视觉需在撤销授权或新 bundle id 环境复测。 |
| Multi-display screenshot | `not_covered_environment` | 当前验收环境只覆盖单屏。 |
| Permission revoke/regrant | `not_covered_policy` | 本轮不修改系统隐私数据库。 |
| Real OCR/provider runtime | `deferred` | 当前只开放 route-ready / translation runtime gate；截图图片/OCR 内容外发仍未进入 Alpha baseline。 |
| Long-running Login Item recorder | `deferred` | 当前只验证 helper/debug recorder path，不启用开机常驻。 |
| App Group/provisioning final pass | `deferred` | P4-H 只做 readiness gate，正式共享容器签名和 provisioning 还未落地。 |
| Packaging/notarization | `deferred_to_p8` | P7 不做分发包、notarization 或外部测试安装流。 |

## 下一阶段建议

进入 P8-A：Alpha Packaging / Tester Readiness。先解决安装包、签名/notarization 策略、测试员安装路径、日志/崩溃收集边界、Alpha bug backlog，而不是继续扩展新功能。
