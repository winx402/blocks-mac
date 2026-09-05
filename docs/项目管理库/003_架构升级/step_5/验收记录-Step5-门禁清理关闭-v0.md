# Step 5 门禁、清理与关闭验收记录 v0

结论：`accepted-with-residual-risk`

## P0 / P1

- P0：0。
- P1：0。

## 接受判断

接受 Step 5 本轮实现，状态可进入 `step-5-accepted`。接受范围限定为：

- 删除旧 `AppState` facade、`SettingsView` wrapper、`ClipboardHistoryView`、Clipboard helper/debug target 和长期兼容分支。
- 建立 `AppModel` 组合根和一次性 migration。
- P12 / P11A-E / P3 / P6 / P7 / P8 / P9 / P10 自动化门禁全部迁移到当前事实源并通过。
- fresh `DerivedData/Step5` App / CLI build 通过，最终 app bundle 无 Login Item helper。
- 低敏 UI / TCC evidence 已覆盖 Settings、Clipboard redacted/filtered、Shortcut、Permission、Provider、窄宽度和当前 TCC 授权状态。

## 残余风险

- Screenshot Result copy/save/retake/close 未做真实点击验收。
- VoiceOver 未真实朗读，仅检查 accessibility tree。
- 英文/日文长句未通过系统语言切换实测。
- Clipboard paste/copy/hover/translation preview 的真实 payload read 未触发；自动化门禁已确认默认 denylist 与 purpose allowlist。

这些风险不恢复旧兼容层，不影响 Step 5 cleanup 接受；建议作为后续体验验收专项或发布前 checklist 处理。
