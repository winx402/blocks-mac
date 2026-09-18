# 剪贴板 CLI 管理与迁移 v1

实现入口为 `blocks clipboard`，底层动作是 `blocks.clipboard.manage`。源码开发版使用 `blocks-dev`，不要混用两套安装的数据目录。

需要运行对应版本的 Blocks，并由用户在“本地自动化”设置中明确启用“剪贴板管理”模块。自 Beta 5 起，各模块默认关闭，旧全局开关不会自动转换成模块授权。CLI 校验 Broker 身份，通过 App 的存储队列执行操作；没有离线直写 SQLite 的降级路径。旧 App/Broker 不支持新接口时，应整包更新后重启，不修改数据库 schema 绕过错误。

开启模块会启用动作代理并配置命令：源码版默认使用 `~/.local/bin/blocks-dev`；官方沙盒版首次需要授权命令目录，之后自动更新已管理的 `blocks`。不修改 shell 配置，不覆盖其他工具；若终端找不到命令，按设置提示检查终端 PATH。`blocks list` 通过已认证服务返回当前已启用的动作；关闭剪贴板模块后执行会返回 `module_disabled`，不影响已启用的截图等模块。总开关为断路开关，保留模块选择；卸载命令不撤销模块授权，后续启动也不会自动装回。

## 命令

隐私边界：`list/search/pinboard list` 遵守“允许读取摘要”开关。`show/export` 每次必须在 Blocks 普通窗口中确认本次范围，45 秒超时或取消均拒绝；请先打开 Blocks 窗口再执行。批准后会重新核对数据库快照，期间变化需重试。`--dry-run` 不返回全文，不弹确认。全文授权不复用，设置中的默认范围/时长暂不可调整；CLI 开关本身不是全文授权。

```sh
blocks clipboard --help
blocks clipboard list --limit 50 --offset 0
blocks clipboard search --query "示例"
blocks clipboard show --record-id RECORD_ID

blocks clipboard pinboard list
blocks clipboard pinboard create --name "常用网址" --dry-run
blocks clipboard pinboard create --name "常用网址"
blocks clipboard pinboard rename --pinboard-id BOARD_ID --name "工作网址"
blocks clipboard move --record-id RECORD_ID --pinboard-id BOARD_ID
blocks clipboard pin --record-id RECORD_ID
blocks clipboard unpin --record-id RECORD_ID
blocks clipboard tag add --record-id RECORD_ID --tag "工作"
blocks clipboard tag remove --record-id RECORD_ID --tag "工作"

blocks clipboard import --file migration.json --dry-run
blocks clipboard import --file migration.json
blocks clipboard export --pinboard-id BOARD_ID --output board.json
blocks clipboard export --tag "工作" --output work.json
blocks clipboard export --all --output clipboard.json
```

也支持 `blocks run blocks.clipboard.manage import --file migration.json --dry-run` 等通用动作形式。`show` 是显式内容读取，会在 JSON 结果中返回所选条目的文档；普通列表返回 ID、类型、标题、标签等元数据。导出的完整文档只写指定文件，不重复打印到终端。

`pin` 会收藏条目，已有分组保持不变；无分组时归入未分组。`unpin` 同时解除 Pinboard 归属并移除收藏标签。若只想取消收藏而保留分组，使用 `tag remove --tag favorite`。暂不提供原文改写、全局标签删除或分组删除，避免将这次迁移入口扩大为未定义的数据编辑语义。

只有 `list`、`search` 接受 `--limit` / `--offset`。列表还可使用 `--record-id`、`--pinboard-id`、`--tag`、`--query` 筛选；多个筛选条件取交集，`--all` 不能与筛选条件混用。导出必须显式指定筛选条件或 `--all`，并给出 `--output`。目标文件必须不存在，不支持覆盖；临时文件权限为 0600，成功后才发布到目标路径。不要把导出文件自动上传到第三方服务，它包含剪贴板内容。

## 删除先预览再确认

```sh
blocks clipboard delete --record-id RECORD_ID
blocks clipboard delete --record-id RECORD_ID --confirm PREVIEW_TOKEN
```

第一次只预览，返回 `confirmation_token` 和将删除的条目数。第二次核对相同请求、数据库快照及实际匹配的记录 ID 后才提交；状态变化（包括相对日期筛选跨日后范围变化）返回 `revision_conflict`，需要重新预览。令牌是状态确认，不是用户身份凭据，不能替代 Broker 的身份校验。不要在脚本里跳过预览并伪造令牌；也不要把真实令牌当作固定配置长期保存。

令牌采取保守的全局快照校验，其他剪贴板写入或标签/分组变更也可能使其失效。自动化脚本可以读取 JSON 返回值传给下一条命令，避免通过系统剪贴板复制确认令牌。删除会删除条目及关联标签/索引，图片附件经已有清理队列处理；预览不删除附件。

## 导入文件格式

正式结构定义：[clipboard-import-v1.schema.json](clipboard-import-v1.schema.json)。示例：

```json
{
  "schema_version": 1,
  "pinboards": ["常用网址", "工作资料"],
  "records": [
    {
      "kind": "url",
      "url": "https://example.com/",
      "text": "https://example.com/",
      "pinboard": "常用网址",
      "tags": ["迁移"],
      "title": "示例网站"
    },
    {
      "kind": "text",
      "text": "这是合成的迁移示例。",
      "pinboard": "工作资料",
      "tags": ["迁移"],
      "created_at": "2026-09-01T00:00:00Z",
      "last_copied_at": "2026-09-02T00:00:00Z",
      "is_favorite": false
    }
  ]
}
```

| kind | 内容字段 |
| --- | --- |
| `text` | `text` |
| `url` | `url` 或 `text` 中的有效非 file URL；可同时保留文本表示 |
| `rich_text` | `rtf_base64`；`text` 可选，无文本表示时从 RTF 提取 |
| `image` | `png_base64`，实际可解码的单帧 PNG |
| `file_url` | `file_urls`，必须恰好一个 file URL；不读取指向文件的内容 |

可选日期使用 ISO 8601。日期不得早于 1970 或超过导入时刻 5 分钟，`last_copied_at` 不得早于 `created_at`。省略创建日期时使用当前时间，因此导入历史日期时应同时提供两个日期。未知字段、未知版本或不支持的类型会拒绝，不能把第三方原始 JSON 不经转换直接当成该格式。

## 合并和安全规则

- 同名 pinboard 创建或复用，名称会去除首尾空白；已有重名歧义或同一内容跨多个不同分组时整批拒绝，不擅自覆盖原归组。当前模型每条记录只保存一个 pinboard。
- Blocks 自己计算内容签名，不接受外部 record ID、hash 或数据库列。重复内容复用已有 ID，不覆盖旧 payload、自定义标题、日期或 OCR；标签合并。批内重复项的基础元数据取首项。
- 已存截图原样导出后导回同库，还会使用已有 PNG payload hash 识别，保留原截图身份。多个旧记录同时命中而无法安全确定时拒绝，不悄悄合并旧记录。
- 有分组且省略 `is_favorite` 的新条目默认收藏；显式 `false` 会保留非收藏状态。分组与收藏标签不是同一概念。导入不会剪裁已有历史；非收藏条目之后仍服从正常保留策略。
- `--dry-run` 在 App 中进行真实数据库预览，不是仅打印参数；不写记录、分组、标签或附件。整批提交使用同一事务，失败回滚数据与索引，并清理本次创建的附件。
- 导入不写系统剪贴板、不自动粘贴、不触发内容插件。CLI 未启用、身份校验失败或应用正在更新时安全拒绝。

## v1 范围与限制

- 每个文档最多 1000 条记录、1000 个声明分组，完整 JSON 最多 32 MiB。超限会失败，不会静默截断。更大迁移应分文件；更大导出先通过列表分页取 ID，再显式分批导出。
- 文本最多 4 MiB（UTF-8），RTF 最多 16 MiB，PNG 最多 25 MiB 且最多 4000 万像素；编码后的整份 JSON 仍受 32 MiB 限制。
- RTF v1 只支持无附件、无对象、无 field/HTML 的安全子集；复杂 RTF 明确拒绝，不降级丢失格式，不加载远程或本地引用。
- 这是内容迁移格式，不是整个 App 数据库备份：不导出 OCR、原应用/截图来源、复制次数、设置、钥匙串或权限；系统截图标签不跨库迁移。无法表示的已有 payload 会使该次导出失败，不静默丢弃。
- pinboard 元数据通过这些 CLI 命令管理。当前 App 面板使用标签导航；导入的自定义标签会同步到现有界面，不将 pinboard 名字暗中转换成标签。若需要在 App 中按来源分组筛选，可在转换文件时明确同时写入 `"pinboard":"常用网址"` 和 `"tags":["常用网址"]`；这是显式映射选择，不是导入器的隐藏合并规则。
- 不包含 PasteEasy 私有数据库读取器。需要先将它的公开导出转换为本格式；未提供或验证其导出样本前，不能宣称已完成该产品的实际迁移。
