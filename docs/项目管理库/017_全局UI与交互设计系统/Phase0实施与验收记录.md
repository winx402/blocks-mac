# Phase 0 实施与验收记录

日期：2026-08-01

## 代码交付

- 将共享基础拆分为 `DesignSystemFoundation.swift` 与 `DesignSystemComponents.swift`，并接入 Blocks target；`GlassPanel.swift` 继续承载唯一 Surface 渲染入口。
- 扩展唯一 `BlocksVisualTokens`，新增规范间距、圆角、密度、字体、层级、描边和布局基线。
- 新增 `BlocksInteractionState` 及可测试的状态外观解析。
- 扩展 `BlocksMotionRole`，增加 press、hover/focus、selection、reveal/reflow、panel、confirmation 和 direct manipulation；减少动态效果时最多 100ms 且禁止位移和玻璃形变。
- 扩展 `BlocksSurfaceRole` 的结构、内容、交互和浮层分层，保留单一系统内的阶段性源码别名。
- 新增 Action Button、Toolbar Container、Panel Chrome、State View 和 Debug-only Gallery。
- 将设置现有几何常量连接到全局 Token，数值保持不变，未改造设置页面。
- 新增 `script/test_ui_design_system.sh`，遗留样式计数只能减少，禁止新的模块私有 ButtonStyle。

## 验证结果

| 验证 | 结果 | 证据 |
|---|---|---|
| 设计系统定向测试 | 30/30 通过 | `/tmp/blocks-design-appappearance-final.log` |
| 完整 BlocksAppTests | 914 执行，4 项环境依赖跳过，0 失败 | `/tmp/blocks-phase0-app-tests-final.log` |
| BlocksScreenshotCoreTests | 220/220 通过 | `/tmp/blocks-phase0-screenshot-tests-final.log` |
| BlocksCore | 无独立 `BlocksCoreTests` target；Debug/Release App 依赖构建和 AppTests 中的 Core 测试通过 | Xcode build/test logs |
| Debug build | 通过 | `/tmp/blocks-phase0-debug-build-final.log` |
| Release build | 通过 | `/tmp/blocks-phase0-release-build-final.log` |
| Xcode Analyze | 通过 | `/tmp/blocks-phase0-analyze-final.log` |
| 设计门禁 | 通过，遗留数量未增长 | `script/test_ui_design_system.sh` |
| 插件架构门禁 | 通过 | `script/test_plugin_architecture.sh` |
| 翻译源 CLI 门禁 | 通过 | `script/test_translation_source_cli.sh` |
| diff check | 通过 | `git diff --check` |

Analyze 输出包含一条本机 CoreSimulator 版本落后的环境警告，但 macOS Analyze 本身成功。该警告与 Blocks macOS 代码无关，本轮不修改系统环境。

## 现实边界

- Phase 0 不会改变功能页面的主要视觉，因此未用“重新安装后界面改善”作为交付结论。
- 当前安装版证据只用于建立改造前基线；剪贴板/翻译浮窗、全主题矩阵和 VoiceOver 等仍列为待验证。
- 下一步是 Phase 1 设置样板，未经用户确认不进入实施。
