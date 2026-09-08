# GitHub Issues 修复记录（2026-09-08）

当前实现工作区：`/Users/bot/Documents/blocks-mac`；分支 `codex/issue-fixes-20260908`。
本轮开始时 open issues 为 #6–#21。Issue 中的静态猜测均只作线索，不直接当作根因。

## 实现与验证进展

| Issue | 当前进展 |
| --- | --- |
| #6 / #19 | 背景与前景裁切责任分离；翻译窗口使用 window-owned 表面，不叠加另一套玻璃外轮廓。材质/前景边界测试通过，实机视觉矩阵仍在核验。 |
| #7 | 用户最新要求改为“不管有没有底部 Dock，永远贴屏幕物理底部”。已改 `screen.frame.minY`，保留可用水平范围和菜单栏上界；负坐标测试通过。实机底部 Dock 常显时 actualMinY=0、physicalMinY=0、visibleMinY=90；隐藏时分别为 0/0/0，符合要求。 |
| #8 | 识别真实 Xcode ibtoold、保留清理证据，最多一次完整受控增量重试；第二次仍须通过。真实运行已触发该路径并继续测试，不把首次清理失败冒充首次通过。 |
| #9 | 两个测试显式指定屏幕/锚点，保留产品跟随鼠标屏幕的默认规则；完整测试已通过。 |
| #10 | 本机确认旧签名使子进程约每 0.7 秒被杀，代次超过 19 万。LocalDevelopment 子进程改为空 entitlements，正式沙盒配置不变；EOF/启动失败进入有界熔断，UI 不再伪装为正常无变化。安装版从 TextEdit 复制明确测试文本，已在历史 UI 与数据库中出现；同一子进程稳定超过 7 分钟。 |
| #11 | 统一正文 Token、紧凑间距；固定筛选预算考虑有限选项，来源名保留受限宽度和完整 AX 值。清除按钮使用独立保留槽。最终安装版选择“富文本”后截图确认标签和清除按钮不重叠；其他语言及完整键盘/VoiceOver 场景尚未全部复验。 |
| #12 | 构建/测试 finally 仅注销确切临时产物，保留安装版和其他目录；已处理 -10814 且公开 LS API 确认目标不存在的幂等情况，未知失败仍阻断。 |
| #13 / #14 / #15 | 以同步 SwiftUI Layout 测量完整工具/插件槽，窄屏保留主操作；chips 不再异步改宽/渐隐裁切。完整显示器截图使用 edge-to-edge 画布和内部 chrome，普通区域/长图规则保留。Hosting/几何测试通过。录屏已授权，但自动化不能可靠保证系统截图的前台为受控测试文稿；非测试背景截图已丢弃、不导出、不作验收证据，保留受控实机验收。 |
| #16 | 结构化 CLI 错误与 canonical command；区分无响应、身份不可验证、明确不可信，保留安全文件准入。安装版 `plugin list`/`doctor` 在未启用集成时返回 `broker_unavailable`、明确引导和 exit 5，不再输出内部 Swift 类型地址。 |
| #17 | 等待 launch、active、restoration-complete 与真实 main-window attach，单次呈现，后台不抢焦点。SDK 和时序测试覆盖恢复完成早/晚于启动及临时 visible 状态。安装版六次正常退出后 open 冷启动，CGWindowList 确认主窗口均 onscreen=true；PID 为 85816、85939、86002、86058、86092、86136，未二次点击激活。 |
| #18 | 中/英/日文案明确作用于剪贴板历史中的截图。安装版中文标题与说明已看到新内容。 |
| #20 | 翻译错误使用独立、非 key 的 HUD，不挂子窗口、不随面板移动；状态/action/去重及关闭、暂停清理测试通过，实机核验中。 |
| #21 | 纯文本原文标题使用系统文本行高；带重截图动作的 OCR 来源保留完整点击目标。几何测试通过；安装版手动输入 23 字符测试文本，Apple 本地翻译实际完成，标题与计数为紧凑单行。完整外观/语言矩阵尚未全部复验。 |

## 证据边界

- 完整测试一轮为 1923 pass / 1 fail / 16 skipped；失败是结构预检测试共享失败客户端触发新熔断。改为每种结构独立客户端，不放宽产品恢复策略。
- 下一轮完整测试为 1924 pass / 0 fail / 16 skipped（1940 total）。补充 #11 活跃值布局及用户新 #7 规则后的完整复跑为 **1926 pass / 0 fail / 16 skipped**（1942 total）。
- P006-F、P14-C、UI design-system 静态门禁通过；P14-C 新契约有 15 个内存 mutation 负例。静态通过不替代实机验收。
- 不上报或关闭未验证项，不把 screenshot fixture 当作真实屏幕捕获，也不把 skip 当 pass。

### 2026-09-09 补充复核

- 安装版 CLI 离线真实测试：init 成功 exit 0；重复目录 exit 2/output_exists；包内相对 event 和 expect exit 0/matched_expectation=true；缺失相对文件不回退 cwd，exit 2/event_fixture_read_failed；路径穿越 exit 2/event_fixture_invalid_path；pack 缺输出 exit 2/invalid_arguments，正常 pack exit 0 且哈希匹配。所有错误 command 为规范名称，不含输入路径。CLI self-test 10/10。
- 独立只读审查覆盖 broker 熔断代次去重、可用状态恢复、开发/正式 entitlement 分离、启动恢复时序及玻璃前后景裁剪，未发现可靠阻断性回归。审查不替代未完成实机矩阵。
- 辅助功能系统证据：用户重新添加后，tccd 日志先记录当前开发包 requirement 的 Allowed 写入；随后新进程的 Accessibility preflight 却仍按旧 requirement 检查，报 Failed to match existing code requirement 并返回 authValue=0。当前包 deep/strict 签名有效，录屏检查正常。尚不能确定旧规则来自缓存还是其他记录；请求用户确认仅针对 app.blocks.dev 的 Accessibility 重置，未自行修改 TCC 数据库或绕过系统权限。
- 用户明确允许定向重置后，正常退出开发版并执行系统命令 `tccutil reset Accessibility app.blocks.dev`，系统报告成功。重新启动并通过系统设置恢复授权后，应用自身显示辅助功能已授权；再次正常退出重启后仍已授权，录屏权限保持有效。没有修改 TCC 数据库、重签安装包或重置其他 App 权限。这只证明授权恢复，不替代外部 App 自动粘贴插入验收。

## 工作区与授权

### 后续窗口背景复验

- 2026-09-09 再次打开安装版翻译面板，顶部透明带仍可复现，因此没有关闭 #6/#19。
- 确认 `blocksBackground` 使用 ViewBuilder background 重载，不像 ShapeStyle 重载那样默认忽略安全区；透明标题栏与 full-size content view 仍保留标题栏安全区，结构背景未绘制该区。
- 后续补丁仅让 `.window` 角色的背景忽略 container safe area，其他角色与前景布局保持不变，不增加猜测的圆角或前景遮罩。新增真实 titled NSWindow / NSHostingView 的窗口坐标断言，要求背景到达完整窗口顶部而非停在 contentLayoutRect 上沿。该轮完整测试为 1927 pass / 0 fail / 16 skipped，未把它写作安装版通过。
- 截图后续审查发现：多行 inspector 插件被固定 38pt 属性行压缩；tool/output slot 的内联多行错误会侵入 48pt 工具行；多屏联合源因不等于单屏 frame 而漏算缺口安全区。三项继续补修，不把前一轮提交当最终验收。
- 联合多屏的后续安全区策略：截图像素和窗口覆盖范围不变，仅将 chrome 约束到与源区域相交面积最大的单个真实屏幕安全矩形（面积相同时保持系统屏幕顺序），避免工具条落到屏间空区或物理缺口。单屏保持原安全区语义；负坐标与联合源断言已补，等待统一测试。
- 后续完整测试为 1933 pass / 0 fail / 16 skipped。但新增真实滚动视口断言随后发现 inspector 的 clipView 与 document 都为 698pt，外层 180pt 约束并未形成滚动，因此没有安装该中间版。最终改为有限高度 proposal + ViewThatFits，自然短内容和固定上限的长内容 ScrollView 分支分离；真实滚动、窗口背景、安全区与居中定向复跑 **17 pass / 0 fail / 0 skipped**。P14-C 与 UI 规范门禁通过，包含回退到无界量测/伪裁切的反向用例。
- 远端 ccdebdb 的 CI run 34255108357 仍在手动翻译居中测试失败，因此重新打开 #9。该运行无 artifact，日志无实际/期望几何，根因暂未确认。补充断言几何诊断及 CI failure-only xcresult 摘要和 7 天结果保存，保持原精确断言，不为通过 CI 放宽标准。
- 后续开发版已经通过既有 dev.sh 入口安装，旧包保留供恢复；安装版翻译面板顶部透明带已消失，背景覆盖到系统圆角顶部。没有据此宣布完整视觉矩阵通过。新 ad-hoc 包安装后，应用显示录屏、辅助功能和输入监控未授权；未自行扩大之前仅 Accessibility 的重置许可，也未重置其他 App。录屏和外部 App 验收需要重新授权后继续。

- 一个 CLI 子任务曾误用相对路径写到旧目录；已将精确改动迁入当前仓库，按其自身 hunk 撤销旧目录误写，保留旧目录其他修改。
- 用户随后明确要求删除旧目录代码。已把源码、依赖、构建产物及旧 Git 元数据移入系统废纸篓，保留文档与角色说明；没有永久清空废纸篓，也没有修改当前仓库的未提交修复。
- 用户已允许 Blocks Dev 录屏/辅助功能授权和临时 Dock 测试（原设置：右侧、自动隐藏）。用户在系统界面完成录屏确认后，应用已确认录屏授权生效。
- 用户已在系统界面完成第二次解锁，并通过系统文件选择器重新添加当前安装路径；辅助功能列表开关虽开启，应用重启和刷新后仍显示未授权。此项仍未通过，不能将系统开关状态替代应用实际授权状态。不收集密码、不绕过授权。
- Dock 已完成底部常显/自动隐藏测试并恢复“右侧、自动隐藏”。2026-09-09 再次通过 defaults 只读核对 orientation=right、autohide=1。
