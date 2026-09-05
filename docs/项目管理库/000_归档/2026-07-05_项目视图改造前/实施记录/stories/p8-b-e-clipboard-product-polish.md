# P8-B/E Clipboard 产品化打磨纵切

状态：implemented / pending manual UI pass

## Scope

本 story 承接 P8-A 剪贴板产品方案，覆盖 P8-B 数据与展示模型、P8-C 浮层交互、P8-D 设置页重做和 P8-E 自动门禁。目标是把 Clipboard 从“redacted 摘要列表”推进到更接近真实 Paste 风格历史工具：内容优先、筛选清晰、右键管理、隐私排除独立设置、Agent/CLI 授权入口清楚。

本轮仍不启用长期 Login Item recorder，不开放真实用户完整剪贴板内容恢复，不调用 provider，不上传剪贴板内容。

## Product Issues Covered

| P8-A issue | Handling |
| --- | --- |
| 顶部间隙大、核心条目不突出 | Header 压缩为搜索框 + 图标筛选组 + 设置/关闭；移除常驻 footer。 |
| 条目只显示说明，不像内容 | 新增 `ClipboardRecordPreview`，卡片优先展示内容预览、时间和格式缩略。 |
| 格式差异渲染不足 | 文本、富文本、图片、URL、文件、混合、排除项进入差异化 preview；fixture 图片可显示缩略图。 |
| Hover 详情固定且易裁切 | 详情改为卡片/行锚定 popover，脱离原固定角落。 |
| 固定/删除按钮干扰浏览 | 管理动作移入右键菜单：粘贴、复制纯文本、固定、移动分组、重命名候选、删除。 |
| 缺少格式/时间/分组/来源筛选 | 顶部图标筛选组支持 format/time/pinboard/source 叠加过滤和一键清空。 |
| 筛选关闭后保留策略 | 设置增加筛选清空延迟：立即、15 秒、30 秒、1 分钟、永不。默认 30 秒。 |
| 固定内容缺少分组和名称 | 新增 Pinboard 元数据与按组筛选；右键支持移动到分组和用预览标题命名。完整自定义编辑器仍保留为后续细化。 |
| 剪贴板设置页堆叠 | Clipboard 设置重分区为记录策略、面板显示、筛选行为、Pinboards、隐私入口、Agent/CLI、诊断。 |
| 排除 bundleId 不友好 | 新增独立 Clipboard Privacy route，使用 App 列表、图标、名称、bundleId 次级信息和 toggle。 |
| Agent/CLI 授权缺 UI | Settings 增加 Agent CLI / MCP 摘要读取、默认范围/时长和完整内容授权 gate 说明。 |

## Implementation Notes

- `ClipboardFormatFilter`、`ClipboardTimeFilter`、`ClipboardFilterGroup`、`ClipboardFilterState` 成为浮层筛选状态。
- `ClipboardRecordPreview` 将卡片主信息和 hover 详情信息拆开；URL 不联网解析，只使用本地 fixture/payload。
- `ClipboardHistoryPanelPresenter` 在浮层关闭时调用 `scheduleClipboardFilterClearAfterPanelClose()`，避免筛选状态永久影响下一次打开。
- `SettingsView` 新增 `.clipboardPrivacy` 模式和独立 sidebar route。
- 本轮的 Pinboard 和重命名仍是本地内存态元数据；持久存储和完整编辑器不在本 story 内。

## Verification

- `python3 tools/verification/p8_clipboard_product_polish_checks.py --timeout 180`
- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

## Manual Acceptance

- 打开 Clipboard bottom 浮层时，顶部应更紧凑，首屏重点是历史卡片。
- 格式、时间、分组、来源筛选可以叠加；有筛选时可一键清空。
- 卡片右键可见管理动作；常态不再露出 pin/delete 按钮。
- 图片 fixture 在卡片内显示缩略图；URL 不触发联网预览。
- Hover 详情靠近条目出现，不再固定在面板角落。
- Clipboard Settings 和 Clipboard Privacy 两个设置入口语义清楚。

## Deferred

- Pinboard 创建、改名、颜色和排序的完整编辑器。
- 文本/富文本预览内编辑。
- Paste Stack 式顺序粘贴。
- 真实长期 recorder 数据源与持久可恢复历史。
