# GitHub Issues 修复（2026-09-07）

交付状态：#1–#5 已验证修复（#1 采用明确签名前提的文档路径）；#6/#7 已有局部补丁，但专项视觉、Dock 状态及多屏实测仍未完成，保留开放。最终聚焦回归 121/121 通过，安装版已更新。下文保留失败迭代，不将早期测试通过冒充最终验收。

范围：私有仓库 `winx402/blocks-mac` 未关闭的 #1–#7。报告中的静态根因作为线索，不能当作运行结论。修复和验证在原工作区进行，上传仍使用脱敏源码副本；不删除本机旧安装包或签名材料。

## #1：无证书构建与文档承诺不一致

- 选择 issue 提供的文档/前提修正路径：保留开发版 Keychain 组，不增加功能受损的 ad-hoc 变体。
- `build_and_run.sh` 在无证书或显式禁用稳定签名时，在构建/替换安装包前退出 66，并指向本地配置模板。已安装 App 的 existing 模式不需要重新构建。
- 修正 `Signing.shared.xcconfig` 注释、App README 的普通 `--verify` 与 fresh checkout 说明。
- 系统约束参考：[Apple：Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)。
- 隔离 shell 回归：`python3 tools/verification/stable_app_install_self_test.py`，21 项通过，包含无证书 auto/0/1 三种模式提前拒绝、构建失败保留旧安装及真实 ad-hoc 合成包安装逻辑。不是在第二台无证书 Mac 上进行的完整验收。

## #2：构建副本被 Spotlight 索引

- 默认构建位置迁至 `~/Library/Caches/BlocksDev/DerivedData.noindex/Blocks`；显式覆盖入口为 `BLOCKS_DERIVED_DATA_DIR`。
- README 的手动构建及 CLI 示例同步新路径；稳定安装路径不变。
- 旧构建目录和旧 Launch Services/Spotlight 记录不会自动删除；现存重复条目消退不作为已完成事实。

## #3–#7：交互与窗口修复

- #5 修复前安装版复现：切换剪贴板页后顶部“剪贴板”分区标题不可见，向上滚动后标题出现、启用行下移约 52pt。仅导航与滚动，无业务设置修改。
- #3：侧栏用户选择同步发布路由，之后再发起焦点恢复，防止异步发布期间 SwiftUI 用旧选择回设高亮。
- #5：保存值改为距实际 NSClipView 顶部的非负距离；首次路由恢复到合法顶部（可为 -52pt），已访问路由仍恢复原位置。
- #4：导航行交互背景外扩到 section 边界，由完整 section 的共享圆角裁剪；一般 chip 保持原行为。首/末行仅向 section 外沿扩展，内部边界不外扩，避免跨 divider 的点击区域重叠。真实 NSHostingView 几何测试覆盖三种宽度，不能用纯 Token 断言替代。
- #6：补上 SwiftUI opaque/material fallback 及 AppKit backing 的显式裁剪，保留 shadow 宿主溢出。当前安装版主窗口外缘已观察到圆角，本项不据此宣称主窗口与所有浮层均已消除报告现象。
- #7：底部面板在屏幕参数/所属屏幕变化时重读可视区域并重锚，关闭时移除观察；按显示器 ID 从当前 NSScreen 列表取最新实例。Dock 自动隐藏实际是否触发对应通知、跨显示器 Dock 场景仍需实测。

## 迭代验证记录

- 本机：macOS 26.6.2（25G83）、Xcode 26.6（17F113）。
- `blocks-issues-build-20260907-r1.json`：新增观察器析构 actor 隔离编译错误；修复后 r2 clean 0。r3 编译器 0 但 ibtoold 残留被受控清理，未计通过；r4 clean 0。
- `blocks-issues-tests-20260907-r1.xcresult`：119 项，117 通过、2 超时、0 跳过；失败均为新增导航行几何测试。
- r5：新增探针 NSView.identifier 类型冲突及 resolver 变量遮蔽编译错误；修复后 r6 clean 0。
- `blocks-issues-tests-20260907-r2.xcresult`：9 项，8 通过、1 超时、0 跳过；剩余多行导航测试继续排查，未将重跑前的失败抹除。
- r2 spindump 将失败定位到 `XCTAssertFalse(firstSurface.intersects(lastSurface))` 后的 XCTest 符号化，而非 App 运行死锁。实际问题是相邻行上下外扩导致 hit region 重叠；已修复布局，未放宽断言。
- r7 编译器 0、ibtoold 残留清理未计通过；r8 构建 clean 0。
- **最终聚焦回归** `blocks-issues-tests-20260907-r3.xcresult`：119/119 通过、0 失败、0 跳过、受控进程退出 0。范围为 AppAppearanceTests、三个新增测试类，以及浮层与既有双击粘贴关键回归；不是全项目全量测试。
- `script/test_ui_design_system.sh` 通过；最终 XCTest diagnostics 的 Publishing changes、Invalid frame/geometry、NSCGS、AttributeGraph cycle、TSan、Main Thread Checker 模式扫描无命中。
- 旧 `permission_gate_helpers_self_test.py` 的 `refresh_appmodel_retries_pending_paste` 仍期待授权后重放，与先前自动粘贴契约冲突；该失败不来自本次设置/窗口修改，不为通过测试而恢复旧自动重放行为。
- 已备份当前安装包至本机 Library 的 `Backups.noindex/pre-issues-20260907.u51z11/Blocks.app`，未上传安装包。

## 安装版复验

- 标准入口 `BLOCKS_REQUIRE_STABLE_SIGNING=1 BLOCKS_USE_STABLE_SIGNING=1 ./script/build_and_run.sh --verify` 成功，产物确实位于新 Library `.noindex` 目录，主 App 与 CLI 构建成功。
- 首次更新主 App PID 29629，CDHash `9d1e866d59112a78c1c20ab913d091f7fb722d68`；安装/构建二进制 SHA-256 均为 `ed95c0d1869757cc13b8f33f324146d41fe1f05f8e4a6f6dffe85c3004e069c7`，深度严格签名校验通过。
- 通过 CUA 连续进行截图→剪贴板→翻译三轮（9 次）侧栏选择，最终选中项均匹配请求；这是离散状态采样，不是逐帧录像。
- 标签二级导航可正常进入；没有编辑标签、授权或业务设置。
- **#5 安装复验仍失败**：真实主窗口首次页面标题仍被上方遮挡约52pt，尽管带模拟 inset 的单元测试通过。该项继续修复并补真实标题栏/toolbar fixture，不能凭119项回归关单。
- #6 主窗口当前外缘圆角正常；自定义材质回退路径与多屏视觉尚未全面验收。#7 临时切换系统 Dock 自动隐藏的实测请求尚待用户确认。

## 最终交付验证

- #5 真实数值定位：初始 contentInsets.top 从 32 更新为 52，但 document-only `constrainBoundsRect` 返回的最小 origin 仍为 0；将其直接当作滚动下限会截断合法的负 origin。修复以真实 contentInsets 扩展顶部范围，以 document frame 与 viewport 尺寸计算底部范围，不探测极端坐标作为最大滚动位置。
- 放弃未解决真实窗口问题的 SwiftUI top-anchor 方案；删除临时几何日志及其开关/兼容分支。保留 route-owned 非负相对位置，0 对应实际顶部，非零位置精确恢复。
- 新增真实 NSScrollView 的 52pt inset/20pt 已存位置测试，以及 titled/fullSizeContentView/toolbar 的 NSHostingView fixture。后者测得真实 inset 66pt；不再错误要求 SwiftUI 私有实现一定开启 automaticallyAdjustsContentInsets 布尔属性。
- 相关失败保留：安装 r2 的诊断字符串表达式编译超时；r10 测试引用 private anchor 枚举编译失败；tests r4 中错误的 automaticallyAdjustsContentInsets 断言触发 XCTest 符号化超时。均已修正，不归为产品通过。
- `blocks-issues-build-20260907-r13.json` clean 0；此前 r12 编译器 0 但 ibtoold 残留清理未计通过。
- **最终测试** `/private/tmp/blocks-issues-tests-20260907-r5.xcresult`：121/121 通过、0 失败、0 跳过、受控退出 0。UI design-system 门禁与 21 项安装脚本自测通过；最终诊断中的指定布局/并发异常模式无命中。
- **最终安装** `/private/tmp/blocks-issues-install-20260907-final.log`：标准脚本返回 0，PID 34981，CDHash `9b466d505bb233d364be5dc80104d0986ab31bc6`。安装与构建主二进制 SHA-256 一致：`8f3164a68660701242450e3ae91e423068740aa5017ad8ae2424b38277ee8cae`；深度严格签名校验通过。
- **最终 CUA 验收**：剪贴板首次首分区完整可见；向下滚动一页→切到翻译→返回剪贴板，筛选行为/标签/隐私分区的位置与离开前一致。点击标签卡片左边距区域（不是标题文字）能正常进入二级页。此前截图/剪贴板/翻译首次顶部及九次侧栏选择亦已检查；截图仅在会话内观察，未上传用户界面图片。
- #6 只确认自定义材质裁剪补丁与自动化测试，不声称已复现并解决报告中的所有窗口穿角；#7 的 Dock 自动隐藏切换尚未获得本次确认，多屏场景也未完成。

远端 #1、#2 已以提交 `54e38a8` 修复并关闭；#3–#5 具备同步及关单依据，#6/#7 保留开放。没有改动系统 Dock 设置、签名权限或主 App 沙盒。
