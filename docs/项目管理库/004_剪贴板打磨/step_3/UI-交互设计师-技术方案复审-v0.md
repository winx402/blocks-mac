# Step 3 UI/交互设计师技术方案复审 v0

日期：2026-07-07
角色：UI/交互设计师
对象：`App架构师-技术方案-v0.md`
范围：004_剪贴板打磨 Step 3 面板交互与布局打磨
结论：`approve-with-changes`

## 1. 复审边界

本次只读复审只覆盖 Step 3 技术方案：

- hover 首版参数与收起规则。
- toolbar 窗口矩阵和 trailing action 清单。
- paste activation 显性控件、compact segmented / radio fallback、多语言和可访问性。
- selected / focused / hover / active filter 状态层级与点击反馈顺序。
- side list row / bottom tray card metrics、密度、点击目标和状态槽位。
- P13C 低敏证据门禁是否支撑体验验收。

明确不覆盖：

- Step 1 搜索 / OCR 底座、OCR 队列、输出边界。
- Step 2 标签事实源、标签事务、收藏 built-in identity。
- Step 4 详情编辑。
- Step 5 隐私页真实 App 清单或 CLI 广义对象管理。
- 真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

本复审没有运行 App、没有截图或录屏实测；所有视觉和 VoiceOver 判断均按技术方案可验收性评估。

## 2. 读取材料

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-PRD-v1复核-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/App架构师-技术方案-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-技术方案预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/UI-交互设计师-PRD复审-v0.md`

## 3. 总体判断

技术方案 v0 主线成立，可以进入技术方案收敛，不需要退回重做。

方案已经把 PRD v1 的关键体验要求落到可开发口径：

- hover 不再依赖即时 `onHover(false)`，改为安全桥、短延迟、re-enter cancel、明显离开和立即关闭条件。
- toolbar 明确 search / filter / trailing actions 的空间优先级和四类窗口矩阵。
- paste activation 明确顶部 active `Menu` 必须退出，使用显性互斥控件，并保留同 key 边界。
- selected / focused 明确先写，再触发 paste / detail / OCR retry / async action。
- row/card 分别给出 metrics、固定状态槽位和状态不跳动规则。
- P13C 包含静态检查、fixture manifest、低敏事件、截图 / 录屏 manifest、keyboard / VoiceOver 和 sanitizer。

本轮未发现 P0/P1。建议 v1 主要补强几个 P2 口径，让开发和测试在实现验收时不需要再猜阈值、fallback 和证据模板。

## 4. P0 / P1 / P2 Findings

### P0

无。

### P1

无。

### P2

1. Hover 参数建议补“可调范围”和验收优先级

当前 `collapseDelay: 180 ms`、`safeBridgePadding: 12 pt`、`safeRegionInflation: 16 pt` 适合作为首版默认值。180ms 足够保护轻微移出，又不至于让用户感到弹层长期粘住；12pt / 16pt 对 macOS 指针斜向移动也属于合理缓冲。

建议技术方案 v1 补充：

- 默认值：180ms、12pt、16pt。
- 可调范围：delay 可在约 150-250ms 内按实测微调；safe padding / inflation 可按视觉间距和实际 hover gap 调整。
- 验收优先级：数值可以调，但必须保持 PRD pass/fail，即斜向进入不误收、短暂移出可恢复、明显离开可预测收起、Esc / 失焦 / 点击选项立即收起。

2. 最小可用窗口下的 filter fallback 需要更明确

toolbar 矩阵和 trailing action 清单方向正确。当前最小可用窗口写到 `filter max 160pt 或更多入口`，建议 v1 再明确最小窗口下至少保留：

- `全部` 或等价回到全量路径。
- 收藏的可达路径。
- active filter 清除路径。
- settings、close、paste activation 不被 filter expanded layer 遮挡。

这不是阻断项，但能避免实现时只保留横向滚动，导致最小窗口下用户找不到“全部 / 收藏 / 清除”。

3. Paste activation fallback 需要写触发条件

compact segmented 适合作为默认首版，尤其视觉短标签可以用“单击 / 双击”或英文短词，完整语义交给 accessibility label。radio fallback 也合理，但建议 v1 写清触发条件：

- 当 segmented 在常规或窄窗口发生截断、拥挤、无法读出当前值，或本地化文案不能保持可读时，切换到 radio group / 按钮组。
- 视觉短标签可以使用 compact copy，但 accessibility label 必须读出完整语义和当前值。
- fallback 不得退回 `Menu` / 下拉。

4. Row / card metrics 需要把“点击目标不退化”写成可验收数值或 evidence

方案给出的 `rowMinHeight: 72 pt`、padding、thumbnail、status slot 和 card fixed slots 方向可接受，能兼顾密度和页面质感。建议 v1 补充：

- row 主体可点击区域不得低于当前基线；如需要数值，可用不低于约 44pt 的主要点击高度作为底线。
- context menu target、OCR retry、resize handle 等小目标必须在密度调整后保留可点性。
- before / after evidence 需要使用同一 fixture 和同一 viewport。

5. Keyboard / VoiceOver 证据建议提供记录模板

P13C 已要求 keyboard 和 VoiceOver evidence，但实现验收时如果没有模板，容易变成一句“已检查”。建议 v1 加最小 evidence fields：

- viewport category。
- focused element label。
- action performed。
- expected announcement / state。
- pass/fail。
- failure detail。

这可以作为 P13C manifest 的一部分，不需要真实剪贴板内容。

## 5. 重点问题判断

### 5.1 Hover 首版参数

结论：可接受为首版。

- 180ms：适合作为短延迟，符合“容错但不长期遮挡”的用户感知。
- safe padding 12pt：适合作为 trigger 与 content 之间安全桥的首版缓冲。
- safe inflation 16pt：适合覆盖轻微斜向移动和手抖。

残余：必须允许实现阶段按低敏 hover 录屏 / event 证据微调，不能把默认数值写成唯一正确值。

### 5.2 安全桥和立即收起条件

结论：符合用户感知。

方案覆盖了 trigger/content/safe bridge re-enter、brief leave、obvious leave、option click、group switch、Esc、panel close、window resign key。关键点是 bridge overlay hit-test transparent，避免为了 hover 容错牺牲搜索框和右侧操作。这一点符合面板体验，不需要回用户澄清。

### 5.3 Toolbar 窗口矩阵和 trailing actions

结论：方向正确，可进入开发准备。

四类窗口、search min width、filter max width、fixed trailing action group 能支撑 PRD 的“不重叠、不遮挡、右侧关键操作优先”。右侧关键操作清单覆盖 paste activation、clear filters / show all、settings、close，以及未来已有固定操作入口。

建议 v1 吸收最小窗口 fallback 口径，确保 `全部`、收藏、active clear 和 trailing actions 都有可达路径。

### 5.4 Paste activation compact segmented / radio fallback

结论：可接受。

compact segmented 作为默认首版合理；短视觉标签 + 完整 accessibility label 能覆盖中文、英文、日文长文案。radio group / 按钮组 fallback 也符合 PRD，不需要回退下拉。

建议 v1 写清 fallback 触发条件，避免开发只实现 segmented 后在日文或窄窗口里出现压缩不可读。

### 5.5 Row / card metrics

结论：可接受。

side list row 与 bottom tray card 分开定义是正确方向；固定 status slot 和外部尺寸不随 hover / selected / focused / OCR / indexing / excluded / skipped 改变，也符合页面质感目标。

残余：实际密度是否“更紧但不廉价”、点击目标是否稳定，必须靠 before / after 低敏截图、事件和手工检查确认。技术方案阶段不能声称已通过视觉质感。

## 6. 可吸收到技术方案 v1 的建议口径

可直接回写：

```text
Hover 参数首版默认采用 collapseDelay 180ms、safeBridgePadding 12pt、safeRegionInflation 16pt。实现阶段可在开发记录中按低敏 hover 证据微调：delay 建议保持在 150-250ms 区间，safe padding / inflation 可按实际 trigger-content gap 调整。验收以 PRD pass/fail 为准，而不是以固定数值为准。
```

```text
最小可用窗口下，filter fallback 必须保留“全部/回到全量”、收藏、active filter clear 的可达路径；普通标签可以横向滚动、截断或进入更多入口。filter expanded layer 不得遮挡 paste activation、settings 和 close。
```

```text
Paste activation 默认使用 compact segmented。若任一 supported locale 或窄窗口下出现当前值不可读、互斥关系不清或控件挤压，则切换为 radio group / 按钮组 fallback。视觉标签可以短，但 accessibility label 必须包含完整动作语义、当前值和互斥关系。不得回退为 Menu / 下拉。
```

```text
Row/card 密度验收必须使用同一 fixture、同一 viewport 的 before / after evidence。row 主体点击区域和 context menu target 不得低于当前基线；如需要数值底线，主要点击高度不低于约 44pt。hover / selected / focused / OCR / indexing / excluded / skipped 不改变 row/card 外部尺寸。
```

```text
P13C 的 keyboard / VoiceOver evidence manifest 至少记录 viewport category、focused element label、action performed、expected announcement/state、pass/fail 和 failure detail；不得包含真实剪贴板正文、真实路径或 OCR 原文。
```

## 7. 是否需要回用户澄清

不需要。

本轮问题都可以由技术方案 v1 或开发派发阶段收敛，不需要回用户确认：

- hover 数值是首版工程参数，不是产品取舍。
- segmented / radio fallback 是实现策略，不改变用户目标。
- row/card metrics 是体验验收口径，不改变功能范围。
- 低敏证据模板属于验收执行细节。

## 8. 结论

`approve-with-changes`。

技术方案 v0 可以进入项目负责人收敛。UI/交互侧无 P0/P1；建议 v1 吸收上述 P2 口径后进入开发准备。若项目负责人选择不出 v1，也至少应在开发派发中写入 hover 参数可调范围、最小窗口 fallback、paste activation fallback 条件、row/card 点击目标和 P13C keyboard / VoiceOver 证据模板。
