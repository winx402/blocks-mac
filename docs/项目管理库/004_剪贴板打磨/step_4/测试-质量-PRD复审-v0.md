# 004_剪贴板打磨 Step 4 PRD 测试/质量复审 v0

日期：2026-07-07

角色：测试/质量

复审对象：

- `AGENTS.md`
- `agents/测试-质量.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `step_4/项目负责人-PRD派发-Step4-v0.md`
- `step_4/产品经理-PRD-v0.md`
- `step_4/项目负责人-PRD预审-v0.md`

## 结论

`approve-with-changes`

Step 4 PRD v0 范围控制正确，聚焦详情编辑与元数据组织，没有提前拉入 Step 5 隐私页真实 App 清单 / CLI 广义对象管理，也没有进入 Step 6 集成验收。可编辑类型、不编辑范围、显式保存 / 取消、dirty-navigation、搜索索引更新、不更新系统剪贴板、富文本和 OCR 边界、编辑区高度和元数据布局均已覆盖到 PRD 层。

测试/质量侧不建议退回重写 PRD，但进入技术方案 / 开发派发前需要把下列 P1 补成可执行断言，尤其是保存事务与搜索索引失败、富文本格式保留、OCR retry 覆盖用户编辑、以及“不更新系统剪贴板”的低敏证据格式。否则实现后容易出现“文档说了方向，但验收无法判定 pass/fail”的问题。

## 复审范围

本轮只复审 Step 4 PRD：详情编辑与元数据组织。不进入实现，不修改 PRD 正文，不触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

重点判断：

- 可编辑 / 不可编辑类型矩阵是否可测。
- 保存成功、保存失败、取消、dirty-navigation 是否有可判定路径。
- 搜索索引更新和系统剪贴板不更新是否能产出低敏证据。
- 富文本格式保留是否有可验收边界。
- OCR pending / running / failed / done 与编辑态互斥是否清楚。
- 编辑区高度、元数据长内容、多语言和可访问性是否能形成验收矩阵。

## P0 / P1 / P2 Findings

### P0

无。

### P1

1. 保存事务与搜索索引失败需要补成硬性 pass/fail。

   PRD v0 已写明 payload / 派生字段 / 摘要 / 搜索索引 / 更新时间要一致更新，也把索引失败列为架构待确认项。测试侧认为这不能只停留在“待确认”：进入开发前必须明确同步事务、异步队列或混合模型的用户可见结果。

   推荐验收标准：

   - 保存成功后，同一 synthetic record 的详情正文、列表摘要、搜索新 token 命中、旧 token 不命中、更新时间前进同时成立。
   - `createdAt`、source App、标签、收藏状态保持不变。
   - 如果索引异步更新，必须有可见 pending / rebuild 状态或可恢复机制；不能把索引失败静默吞掉。
   - 保存失败时，草稿保留，已保存内容、摘要、搜索索引和更新时间保持最近一次一致状态。
   - 如果 payload 已写但索引失败，必须定义回滚、补偿或用户可见 pending；否则验收应判 fail。

2. “不更新系统剪贴板”需要明确低敏证据口径。

   PRD v0 已明确不写回系统剪贴板，但验收不能只看用户界面。后续 P13D 或等价门禁应 fail-closed 地证明保存动作没有调用系统剪贴板写入路径。

   推荐验收标准：

   - 使用 fake pasteboard / adapter spy / static call-site scan 或等价低敏证据，不读取真实系统剪贴板内容。
   - P13D 输出至少包含 `pasteboard_write_attempts=0` 或等价字段。
   - 保存 plain text、URL、富文本文本、OCR 文本四类 fixture 后都证明无系统剪贴板写入。
   - 任何验收输出不得包含真实剪贴板正文、真实 home path、真实文件路径、邮箱、secret、Authorization header、二维码或验证码。

3. 富文本格式保留不能只用“尽量保留”作为验收口径。

   PRD v0 已正确写明不能静默丢格式，也要求技术评估。但测试需要最低 fixture 与失败条件，否则无法判断“保留得足够”。

   推荐验收标准：

   - `detail_rtf_format_004` 至少覆盖粗体、斜体或强调、链接、列表、段落 / 换行。
   - 保存后未编辑区段的格式属性仍在；被编辑文本所在区段的降级规则必须有明确说明。
   - 派生纯文本、摘要和搜索索引同步更新。
   - 保存后静默把 rich text 变成 plain text 且没有项目负责人接受记录，判 fail。
   - 若架构确认无法可靠保留格式，必须在 PRD v1、技术方案或项目负责人收敛记录中明确降级范围，再进入开发。

4. OCR retry 与用户编辑 OCR 文本的冲突策略需要闭合。

   PRD v0 已要求 pending / running 不可编辑、failed 不直接编辑、done 可编辑，并提出 retry 不得静默覆盖用户编辑。这里是高风险回归点，需在进入开发前补成可执行状态机。

   推荐验收标准：

   - pending / running：编辑区不可用，保存不可用，展示处理中状态。
   - failed / retry：展示失败和重试入口，不把失败 OCR 文本当成可编辑正文。
   - done with text：允许编辑 OCR 文本；保存只更新 OCR 文本、详情展示、摘要、搜索索引和更新时间，不改图片 payload。
   - done empty：必须明确是只读空态、允许手动新增 OCR 文本，还是留待后续；不能实现时自由发挥。
   - 用户保存过 OCR 文本后，后续 OCR retry 或 late completion 不得静默覆盖；若发生冲突，必须有保留用户编辑、提示冲突或显式替换路径。
   - 验收应记录图片 payload hash 或等价低敏指纹未变化，但不得输出图片/base64/OCR 原始真实内容。

### P2

1. URL 合法性规则需要在技术方案中具体化。

   PRD 建议至少可解析绝对 URL，这足够进入复审，但最终测试需要覆盖 scheme 缺失、空白字符、大小写 host、query / fragment、非法字符和普通文本输入。是否允许 normalization 应提前写清。

2. dirty-navigation 的 UI 形态可以后置给 UI / 技术方案，但最终必须覆盖保存中切换、保存失败后继续原动作、记录被删除或外部更新的处理。

3. 编辑区 2 行默认 / 4 行上限已可验收，但实际 line height、最小宽度、滚动容器和错误提示高度需要 UI / 技术方案给出可复跑尺寸或截图矩阵。

4. 元数据复制、展开、tooltip 或 accessibility label 任选其一可接受，但最终验收不能只写“可查看完整语义”，需要明确哪个入口可用。

5. 真实 UI、真实剪贴板、真实 VoiceOver、多语言真实本地化和真实 TCC 环境不应在 PRD 阶段触发；实现验收时如仍未覆盖，应作为 residual risk 记录。

## 可编辑 / 不可编辑类型矩阵判断

PRD v0 的类型矩阵基本可测，覆盖 plain text、URL、富文本文本内容、图片 OCR 文本，以及图片本体、文件本体、其他非文本 payload 的不可编辑边界。

建议后续 P13D 或技术方案把矩阵扩成以下断言列：

| 类型 | 必须证明 | Fail 条件 |
| --- | --- | --- |
| plain text | 正文 payload、派生纯文本、摘要、搜索索引、更新时间更新；系统剪贴板不更新。 | 保存后搜索旧 token 仍命中当前记录，或失败保存污染摘要 / 更新时间。 |
| URL | URL record kind 保持；合法 URL 可保存；非法 URL 阻止或失败并保留草稿；不发网络请求。 | 普通文本静默保存成 URL、自动改变 record kind、或触发远端访问。 |
| rich text | 格式保留范围有 fixture；派生纯文本和搜索更新；无静默纯文本化。 | 无接受记录就丢格式，或只更新摘要不更新 rich payload / derived text。 |
| OCR text | 只更新 OCR 文本 / 索引 / 详情展示；图片 payload 不变；retry 不覆盖用户编辑。 | pending/running 可编辑，或保存 OCR 文本改写图片 payload。 |
| image body / file body / other payload | 明确只读原因；可复制 / 查看元数据不等于编辑本体。 | 出现本体编辑入口，或保存动作触碰文件 / 图片 payload。 |

## 保存 / 取消 / dirty-navigation 推荐口径

| 场景 | Pass | Fail |
| --- | --- | --- |
| edit-clean | 草稿等于已保存内容；保存禁用或弱化；操作区占位稳定。 | 保存 / 取消区域插入导致页面跳动。 |
| dirty | 修改后保存可用，取消可用，dirty 状态可见且可被 VoiceOver 理解。 | 修改后无状态反馈，或保存自动提交。 |
| cancel | 草稿恢复到最近一次已保存内容；摘要、索引、更新时间不变。 | 取消后仍残留新文本或更新时间变化。 |
| save-success | 详情、摘要、索引、更新时间全部更新；系统剪贴板写入次数为 0。 | 只有 UI 改了但 repository / search 未更新，或写回系统剪贴板。 |
| save-failed | 草稿保留；失败反馈可见；已保存事实源保持一致；可重试或取消。 | 草稿丢失、部分提交不可见、失败被静默吞掉。 |
| dirty-navigation | 保存 / 放弃 / 继续编辑三路明确；不得静默保存或丢弃。 | 切换条目、关闭详情或关闭面板时直接丢草稿。 |
| saving repeat submit | 保存中防重复提交；失败或成功后状态可恢复。 | 多次点击保存产生重复写入或状态乱序。 |

## 搜索索引与系统剪贴板低敏证据

建议 Step 4 专属门禁命名为 `P13D` 或等价 gate，并输出 bounded JSON。最低 evidence 建议：

```json
{
  "ok": true,
  "current_fact_sources": {
    "prd": "docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md",
    "development_record": "docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md"
  },
  "detail_editing": {
    "text_save_updates_search": true,
    "url_save_updates_search": true,
    "rich_text_save_updates_search": true,
    "ocr_text_save_updates_search": true,
    "old_tokens_do_not_match_current_record": true,
    "updated_at_advanced_on_success_only": true
  },
  "system_clipboard": {
    "real_clipboard_read": false,
    "pasteboard_write_attempts": 0
  },
  "sensitive_output_scan": {
    "passed": true,
    "forbidden_patterns": []
  }
}
```

上述 JSON 是推荐口径，不要求 PRD 直接采用该字段名；关键是后续 verifier 不能只输出“已检查”，必须能 fail-closed 地指出缺哪类证据。

## 富文本验收样例

建议吸收到 PRD v1 或技术方案：

| Fixture | 操作 | Pass | Fail |
| --- | --- | --- | --- |
| `detail_rtf_format_004` | 修改一段文字并保存。 | 未编辑段落的粗体 / 链接 / 列表仍存在；派生纯文本与搜索更新。 | 保存后整条记录变纯文本且无接受记录。 |
| `detail_rtf_link_004` | 修改链接前后普通文字。 | link target 和 link attribute 保持，展示文本按规则更新。 | link 丢失或 target 被不相关修改。 |
| `detail_rtf_multiline_004` | 修改多段文本。 | 段落 / 换行结构可预测保留。 | 换行、列表或段落被不可解释地压平成一行。 |

如果实现只能编辑派生纯文本而不能更新 rich payload，应视为产品降级，需要项目负责人明确接受后才能通过。

## OCR 状态验收样例

| OCR 状态 | 编辑态 | Pass | Fail |
| --- | --- | --- | --- |
| pending | 不可编辑 | 展示 pending，保存不可用。 | 可以输入或保存 OCR 文本。 |
| running | 不可编辑 | 展示 running，late completion 不覆盖当前 dirty 草稿。 | OCR 完成后静默覆盖用户已编辑内容。 |
| failed | 不直接编辑 | 失败 / retry 入口可见；不把失败正文当可编辑内容。 | failed 状态仍显示可保存编辑区。 |
| done with text | 可编辑 | 保存只更新 OCR 文本、摘要、搜索和更新时间；图片 payload 不变。 | 图片 payload hash 改变或搜索未更新。 |
| done empty | 待明确 | PRD / 技术方案明确只读空态或允许手动新增。 | 实现自由决定，测试无法判定。 |

## 编辑区、元数据、多语言和可访问性

建议最终验收至少覆盖：

- 编辑区：默认 2 行、最多 4 行、超过内部滚动；read-only、dirty、saving、failed 状态尺寸稳定。
- Viewport：宽、默认、窄、最小可用宽度；记录实际宽度，不能只写 category。
- 长内容：长 URL、长 file URL 摘要、长文件名、长来源 App、长标签、多标签、中文长句、英文长单词、日文长文案。
- 元数据：短项两列，长项单行；窄宽度下降级为单列或长项单行；不挤压正文编辑区。
- 可访问性：保存 / 取消、dirty、saving、failed、不可编辑原因、OCR 状态、元数据复制 / 展开入口均有可理解语义。
- 低敏证据：file URL 使用 synthetic path 或 `<FIXTURE_FILE>` 摘要；截图、JSON、日志不包含真实路径、真实 App 窗口标题、真实剪贴板正文或 OCR 原文。

## 建议最终验收矩阵

实现完成后建议串行记录：

```bash
python3 tools/verification/p13d_clipboard_detail_editing_checks.py
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

职责建议：

- `P13D`：Step 4 专属 detail editing / metadata gate，必须 fail-closed。
- `P13A`：保护 Step 1 搜索 / OCR 状态底座，避免 Step 4 编辑破坏 search document 或 OCR status。
- `P13B`：保护 Step 2 标签 / 收藏事实源，尤其元数据展示和 tag search 不回退。
- `P8`：吸收用户可见 polish，覆盖详情页布局、编辑区高度、dirty controls、长内容。
- `P8I`：若 Step 4 触碰 Settings 或共享设置，保留；若未触碰，可作为轻量回归。
- `P9A / P9B`：repository storage 与 AppState integration，证明保存后事实源一致。
- `P11E`：低敏输出和 clipboard hardening baseline，阻止真实 payload、路径、secret 进入 verifier 输出。

## 是否需要向用户澄清

不需要直接回用户澄清。当前 P1 均可由 PRD v1、技术方案或项目负责人收敛记录解决。

需要项目负责人 / 角色收敛的问题：

- 富文本若无法可靠保留格式，是否降级、暂缓或只编辑派生纯文本。
- OCR done empty 是否允许用户手动新增 OCR 文本。
- 搜索索引失败后的用户可见状态：回滚、pending rebuild 还是补偿重建。
- dirty-navigation 的最终 UI 形态和保存失败后原动作是否继续。

## 残余风险

1. 富文本格式保留和 OCR retry 冲突都依赖技术方案闭合；PRD v0 已识别风险，但未形成最终可执行策略。
2. 真实 UI、真实 VoiceOver、多语言视觉和窄宽度截图在 PRD 阶段未运行，后续实现验收需补低敏截图 / checklist。
3. “不更新系统剪贴板”如果只靠静态搜索，可能漏掉 adapter 间接写入；建议用 spy + static scan 双证据。
4. 元数据完整语义如果只依赖 tooltip，在键盘和 VoiceOver 下可能不可达；后续 UI / 技术方案需明确可访问替代路径。

## 实际读取 / 操作

- 读取 `AGENTS.md`。
- 读取 `agents/测试-质量.md`。
- 读取 `docs/项目管理库/004_剪贴板打磨/step.md`。
- 读取 `step_4/项目负责人-PRD派发-Step4-v0.md`。
- 读取 `step_4/产品经理-PRD-v0.md`。
- 读取 `step_4/项目负责人-PRD预审-v0.md`。
- 仅写入本文档；未修改 PRD、技术方案或业务代码。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。
