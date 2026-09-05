# Step 1 项目负责人 PRD v1 复核 v0

状态：prd-accepted
日期：2026-07-07
角色：项目负责人
对象：`产品经理-PRD-v1.md`

## 1. 结论

Step 1 PRD v1 接受，可以进入 App 架构师技术方案拆解。当前仍不进入开发实现。

复核依据：

- `产品经理-PRD-v1.md`
- `项目负责人-PRD复审收敛-v0.md`
- Step 1 四份角色复审文档

v1 已按项目负责人收敛意见补齐搜索状态、OCR 重试与生命周期、搜索索引契约、明文预览性能边界、富文本/URL/file URL 标准化、设置页负向清单、日志/CLI/provider/自动化输出边界、回归门禁与低敏验收证据。非目标保持在 Step 1 范围内，没有把 Step 2-6 需求写成 Step 1 交付。

## 2. 收敛问题覆盖核对

| 收敛项 | 复核结论 |
| --- | --- |
| 搜索无结果 / 索引中 / 部分结果仍索引中的状态 | 已覆盖，包含 `VISION-004` 完成前后验收 |
| 时间搜索最小输入格式 | 已覆盖，限定 `YYYY-MM-DD`、可见日期片段、`today/yesterday/今天/昨天` |
| OCR 失败与重试入口 | 已覆盖，入口至少在图片条目状态中 |
| OCR 权限和数据流边界 | 已覆盖，不新增 ScreenCapture / Accessibility / Automation / Full Disk Access / TCC reset，不扫描本地文件系统图片 |
| OCR 派生数据生命周期 | 已覆盖，per-record 派生数据，随删除/清理/裁剪失效，需可持久化或可恢复 |
| 搜索索引契约 | 已覆盖，定义独立 index/read model、最小搜索文档字段和更新/删除触发点 |
| 明文预览性能边界 | 已覆盖，列表默认有界预览，不同步加载所有完整 payload |
| 富文本 / URL / file URL 标准化 | 已覆盖，富文本 plain text、URL token、file name token 和降级边界明确 |
| 设置页移除负向清单 | 已覆盖，列出冲突文案/设置范围和允许保留设置 |
| 日志 / CLI / provider / 自动化边界 | 已覆盖，默认低敏、有界输出，不因面板/搜索/OCR 触发外发 |
| 回归门禁与验收证据 | 已覆盖，要求更新 Step 1 verifier，旧 Step 4D 默认 payload 不可见不得阻止本阶段目标 |

## 3. 技术方案输入

App 架构师进入技术方案时，需要重点回答：

1. 搜索 index/read model 的实体、存储位置、更新事务和删除/裁剪一致性。
2. 面板 bounded preview 的来源、缓存、截断和性能阈值。
3. Vision OCR 队列、状态持久化、重试限流、失败低敏错误和 App 重启恢复。
4. 富文本 plain text 提取、URL token、file URL token 标准化实现边界。
5. 设置页负向 token / setting key / String Catalog 的移除或隐藏清单。
6. 日志、CLI、verification JSON 的默认低敏输出格式。
7. Step 1 verifier 的命名、断言集合和旧 Step 4D 门禁迁移方式。

## 4. 进入下一环节条件

下一步由 App 架构师产出 Step 1 技术方案。技术方案通过项目负责人和必要角色复审后，才允许派发开发实现。

技术方案不得扩大到以下范围：

- 标签 / 收藏数据模型和标签管理。
- 详情编辑和富文本编辑。
- 隐私页真实 App 清单与 CLI 广义对象管理。
- 面板专项布局打磨。
- 外部 OCR provider、复杂权限开关或全局过滤系统。
