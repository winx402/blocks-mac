# Step 3 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发
目标：实现 004_剪贴板打磨 Step 3 面板交互与布局打磨

## 1. 背景

Step 1 和 Step 2 已验收接受。Step 3 PRD v1 和 App 架构师技术方案 v1 已由项目负责人接受，现在进入开发实现。

用户最新推进口径：

- 顶层 step 严格串行，Step 3 开发和验收完成前不进入 Step 4。
- 单个 step 内开发内容可以稍大，不必为了形式拆得过细。

本次派发可以按一个较大开发任务推进，但开发记录和验证输出必须保留 Batch A / Batch B 或等价分层，确保项目负责人能判断 hover / toolbar / activation / density / evidence 是否分别闭合。

## 2. 输入文档

- `step_3/产品经理-PRD-v1.md`
- `step_3/项目负责人-PRD-v1复核-v0.md`
- `step_3/App架构师-技术方案-v1.md`
- `step_3/项目负责人-技术方案-v1复核-v0.md`
- `step_3/项目负责人-技术方案复审收敛-v0.md`
- `step_3/UI-交互设计师-技术方案复审-v0.md`
- `step_3/开发-技术方案复审-v0.md`
- `step_3/测试-质量-技术方案复审-v0.md`

## 3. 实现范围

只实现 Step 3：面板交互与布局打磨。

必须覆盖：

1. 筛选组 hover 展开后的安全桥、短延迟收起、re-enter cancel、明显离开收起和立即关闭条件。
2. toolbar 空间优先级：右侧关键动作、搜索框最小可用宽度、筛选组最大可用宽度、bottom / side 真实 viewport matrix。
3. 搜索框适度缩短，为筛选组和右侧关键动作让出空间。
4. 面板顶部 paste activation 退出 `Menu` / 下拉，改为显性互斥控件；如 Settings 有同项，必须共用 `clipboard.panel.pasteActivationMode`。
5. row/card 主激活进入局部 activation handler，不再直接把 tap gesture 接到 paste。
6. selected / focused / 低敏事件记录先写，再触发 paste / detail / OCR retry / copy / async action。
7. rapid A -> B stale completion guard。
8. focused、hover、interaction token 保持 view-local 或局部 view model-local，不进入 AppState / repository / database / persistence。
9. side list row 与 bottom tray card 分别做密度和稳定尺寸约束。
10. hover、selected、focused、OCR pending/failed/retry、indexing、excluded、skipped、favorite、long tag 等状态不导致 row/card 外部尺寸跳动。
11. P13C 专属 verifier、低敏 evidence manifest、selected/focused event log、keyboard checklist、VoiceOver checklist。
12. P13A、P13B、P8、P8I、P9A、P9B、P11E 回归关系保持。

## 4. 明确不做

- 不重做 Step 1 搜索、OCR、bounded preview 或输出边界底座。
- 不修改 Step 2 标签 / 收藏事实源、favorite built-in identity 或标签事务。
- 不做 Step 4 详情编辑。
- 不做 Step 5 隐私页真实 App 清单或 CLI 广义对象管理。
- 不把 UI hover、focused、interaction token 写入 `AppState`、repository、database、UserDefaults 或新的全局事实源。
- 不触发真实用户剪贴板、provider、Keychain、TCC、系统设置或自动化动作作为默认开发验证。
- 不把真实剪贴板正文、OCR 原文、完整路径、真实 App 名、邮箱、secret、Authorization header、验证码、二维码或图片 base64 写入 evidence / logs / verifier 输出 / 开发记录。

如实现阶段认为必须运行真实 App 或采集真实 UI evidence，先回报项目负责人确认范围和低敏方案；不要自行扩大。

## 5. 实现要求

### 5.1 P13C baseline 与 evidence

- 新增 `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` 或等价 Step 3 专属 verifier。
- P13C 必须 fail closed：缺 manifest、缺 artifact、缺必填字段、绝对路径、旧 step 文档作为 ok evidence、敏感内容、row/card 直接 paste、focused/hover/token 进入全局事实源、paste activation 仍是 Menu 等均失败。
- P13C 不启动真实 App，不读取真实剪贴板，不生成截图/录屏，不触发 provider、Keychain、TCC、系统设置或自动化。
- evidence manifest 使用仓库相对路径，建议放在 `docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/`。
- P13C 输出 JSON 至少包含 `ok` / `status`、checked counts、failures、low-sensitive sanitizer summary。

### 5.2 Hover / toolbar / paste activation

- hover 默认参数按技术方案 v1：collapse delay 180ms、safe bridge padding 12pt、safe region inflation 16pt；允许实现记录中说明按 evidence 微调，但 pass/fail 不得降级。
- safe bridge 必须 hit-test transparent，不得遮挡 search、settings、close、paste activation、clear filter 或标签按钮。
- 不引入全局 `NSEvent` monitor。
- toolbar 对 bottom / side 分开处理实际 viewport，不能强造当前 UI 无法达到的断点。
- 最小可用窗口必须保留 all / show all、favorite、active clear、settings、close、paste activation 的可达路径。
- paste activation 主控件不得是 `Menu` / dropdown；fallback 只能是 radio group 或互斥按钮组。

### 5.3 Activation / selected / focused

- row/card 主体点击、键盘主激活、detail open、OCR retry、copy 等路径进入局部 primary activation handler 或等价封装。
- 处理顺序固定为：select、focus、低敏 event record，然后再请求 paste/detail/OCR retry/copy。
- double-click 模式 first click 只 select/focus，不直接 paste；double-click 再 select/focus + paste。
- event log 使用 synthetic id / fixture id、monotonic seq、relative timestamp，不写真实内容。
- P13C 至少验证 `single_click_paste`、`double_click_paste`、`detail_open`、`ocr_retry`、`rapid_click_stale_completion`。

### 5.4 Row / card density

- side list row 和 bottom tray card 分开定义 metrics。
- 状态变化不得改变 row/card 外部尺寸，不得造成列表或 tray 抖动。
- row 主体点击区域和 context menu target 不得低于当前基线；如使用数值底线，主要点击高度不低于约 44pt。
- OCR retry、显式按钮、resize handle、favorite toggle 等小目标仍可达。
- before / after evidence 使用同一 fixture、同一 viewport / panel position、同一 locale 或明确记录 locale 差异。

### 5.5 Keyboard / VoiceOver

- 按技术方案 v1 的 checklist 字段提供低敏 evidence。
- keyboard 至少覆盖 search focus、filter expand/collapse、all/favorite/ordinary tag reachable、active clear、record list focus/selected、paste activation toggle、settings/close、OCR retry visible、detail open、no focus trap。
- VoiceOver 至少覆盖 search label、active filter/all state、expanded/collapsed state、selected/focused semantics、favorite semantics、OCR status、paste activation mutual exclusion、long tag label、settings/close/clear filter。
- 每项必须 pass/fail，不得写“已检查”代替结构化结果。

## 6. 开发记录

请写入：

- `step_3/开发记录-Step3-v0.md`

开发记录必须包含：

- 实现摘要。
- 技术方案 v1 覆盖清单。
- Batch A / Batch B 或等价分层记录。
- P13C baseline red 记录；如果一个开发批次内直接从 red 到 green，也要记录 red 的失败原因和 green 的修复证据。
- hover 参数最终取值和是否微调。
- bottom / side viewport evidence 覆盖情况。
- selected/focused event scenario 覆盖情况。
- keyboard / VoiceOver checklist 覆盖情况。
- 回归矩阵命令和结果。
- 残余风险；不得把未做真实 UI / 真实剪贴板 / TCC / provider 的内容写成已实测。

## 7. 最低验证命令

开发完成前至少运行：

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如果任一命令失败，先定位并修复；不能把失败门禁写成通过。若因环境限制无法运行某项，开发记录必须写清限制、替代证据和 residual risk。

## 8. 完成回报

完成后回复：

- `DONE_WITH_EVIDENCE` 或 `DONE_WITH_CONCERNS`
- 开发记录路径
- 主要改动文件
- 验证命令和结果
- 残余风险
