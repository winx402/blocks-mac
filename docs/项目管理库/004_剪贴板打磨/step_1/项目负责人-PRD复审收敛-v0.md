# Step 1 项目负责人 PRD 复审收敛 v0

状态：revision-requested
日期：2026-07-07
角色：项目负责人
对象：`产品经理-PRD-v0.md`

## 1. 结论

Step 1 PRD 的阶段范围和产品方向可以接受，但不能直接进入技术方案和开发。四个复审角色结论一致为 `approve-with-changes`，需要产品经理先补一版 `产品经理-PRD-v1.md`。

本次要求修订的问题都属于 Step 1 内部验收契约和边界补强，不改变阶段目标，也不把 Step 2-6 功能提前塞回 Step 1。

## 2. 已完成复审

| 角色 | 结论 | 文档 |
| --- | --- | --- |
| UI/交互设计师 | `approve-with-changes` | `UI-交互设计师-PRD复审-v0.md` |
| App 架构师 | `approve-with-changes` | `App架构师-PRD复审-v0.md` |
| 安全合规顾问 | `approve-with-changes` | `安全合规顾问-PRD复审-v0.md` |
| 测试/质量 | `approve-with-changes` | `测试-质量-PRD复审-v0.md` |

## 3. 产品经理必须回写的问题

### 3.1 搜索状态与时间搜索

必须补清：

- 区分“确定无结果”和“当前无结果但 OCR / 索引仍在后台处理”。
- 搜索已有部分结果但仍有 OCR / 索引排队时，应有非阻塞状态提示。
- OCR 完成前后，搜索 `VISION-004` 这类 OCR fixture 的状态变化要可验收。
- 时间字段必须二选一：
  - 明确 Step 1 支持的最小输入格式，例如 `today`、`yesterday`、`今天`、`昨天`、`2026-07-07`、可见日期文本片段。
  - 或明确 Step 1 只让时间字段参与展示 / 排序 / 索引准备，不把自由文本时间搜索作为必验能力。

### 3.2 OCR 状态、重试和数据边界

必须补清：

- OCR 失败和重试入口的用户可见位置，例如图片条目状态、搜索状态行或等价稳定入口。
- 点击重试后的状态转换和反馈：failed -> pending/running -> done/failed。
- OCR pending/running/failed/retry 需要可复现 fixture 或测试钩子，不能依赖机器速度碰运气。
- OCR 只处理剪贴板历史中的图片 payload，不新增 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset 或系统设置跳转。
- 不扫描本地文件系统图片，不根据 file URL 自动读取文件本体做 OCR。
- OCR text/status 是 per-record 派生数据，需随记录删除、清理、裁剪失效；App 重启后状态不能只靠内存临时队列。
- OCR 失败记录错误类别、耗时、尺寸等低敏字段，不记录图片 base64 或完整识别长文本。

### 3.3 搜索索引契约

必须补清：

- 搜索有独立 index/read model，不是临时 UI filter。
- 每条记录有可重建搜索文档，至少包含 recordID、revision 或 updatedAt、正文纯文本、富文本纯文本、URL tokens、file tokens、来源 App tokens、类型别名 tokens、时间 token 或时间排序字段、OCR text、OCR status。
- payload 新增、删除、裁剪、OCR 完成/失败、后续详情编辑和标签变更都必须触发索引更新或删除。
- Step 2 标签字段后续接入同一索引底座；Step 1 不实现标签，但不能排斥后续 tags。

### 3.4 明文预览性能边界

必须补清：

- 面板列表默认展示有界预览，不同步加载所有完整 payload。
- 长文本、大图、富文本解析、缩略图生成和 OCR 可异步或缓存，不能阻塞首屏、滚动和搜索输入。
- 完整 payload 可由 App 内明确用户路径访问，但不是面板打开时全量同步读取。
- 验收样例覆盖长文本、大图、多记录批量入库时列表先可见。

### 3.5 富文本、URL、file URL 标准化

必须补清：

- 富文本：Step 1 只提取 plain text 用于预览和搜索，不承诺格式保留和编辑；解析失败时降级，记录仍可见。
- URL：至少索引原文、host、path 片段；query 是否完整索引由技术方案按长度和低敏边界决定。
- file URL：至少索引 lastPathComponent / 文件名 / 扩展名；完整路径搜索不作为 Step 1 必验，路径展示需要有界摘要。

### 3.6 设置页移除负向清单

必须补清：

- 列出必须从用户可见设置中消失的内容保护 / 遮挡 / 只显示字符数相关文案、设置项或 key。
- 列出允许保留的容量、保留天数、性能、清理策略类设置。
- 如果内部字段保留，必须说明其不得影响面板明文展示和搜索验收。

### 3.7 日志、CLI、provider、自动化输出边界

必须补清：

- 普通运行日志、verification JSON、开发记录、验收记录默认不写完整正文、完整 URL、完整 file path、完整 OCR 文本、图片 base64 或 provider raw request/response。
- 新增 OCR、索引、搜索日志默认记录状态、长度、类型、耗时、错误码、短 id/hash、队列状态等低敏字段。
- 如确需正文片段用于本地 debug，必须限定为 fixture 或显式 debug 场景，并有长度上限；不得进入仓库文档、CI 或验收记录。
- CLI 若被 Step 1 触及，默认列表、搜索、help、错误输出必须结构化且有界；完整内容输出需要明确命令或参数。
- 面板打开、搜索输入、OCR 入队、OCR 完成、OCR 重试不得触发 provider 或自动化外发。
- Step 1 不新增外部 OCR、多模态 provider 分析、自动化执行器、shell / AppleScript / CGEvent / Accessibility 操作路径。

### 3.8 回归门禁与验收证据

必须补清：

- 新增或更新 Step 1 verifier，证明旧 redacted-only 面板主路径、只显示字符数主路径、只搜 redacted preview 的搜索路径和同步 OCR 阻塞路径不再作为事实源。
- 旧 Step 4D 安全门禁只能作为历史参考，不能继续以默认 payload 不可见作为 Step 1 的通过条件。
- 验收证据只使用低敏 fixture；截图、录屏、verification JSON、开发记录和验收记录不得包含真实剪贴板正文、真实 home 路径、邮箱、secret、Authorization header、二维码、验证码、图片 base64。
- 性能门槛至少要写成可测口径：打开面板不等 OCR、搜索输入不触发同步 OCR 或全量 payload 读取、大图多图进入队列或批处理；具体毫秒阈值可由技术方案补充。

## 4. 保持不变的非目标

产品经理修订时不得把以下内容写入 Step 1 交付：

- 标签 / 收藏数据模型、标签筛选和设置页标签管理。
- 详情编辑、保存 / 取消、富文本格式保留和 OCR 文本编辑。
- 隐私页真实 App 清单和 CLI 广义对象管理。
- 筛选 hover 安全区、搜索框宽度、选中反馈、单/双击显性控件、卡片密度等 Step 3 专项打磨。
- 复杂权限开关、全局过滤系统或外部 OCR provider。

## 5. 下一步

产品经理基于本收敛意见产出 `step_1/产品经理-PRD-v1.md`。项目负责人复核 v1 后，如确认所有必须改问题已回写，将 Step 1 状态改为 `prd-accepted` 并交给 App 架构师做技术方案拆解。
