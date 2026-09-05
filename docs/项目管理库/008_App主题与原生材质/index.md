# 008_App主题与原生材质

状态：historical-superseded-by-017
最后审阅：2026-07-23
来源级别：project control

## 项目目标

- 为 Blocks 提供“跟随系统 / 浅色 / 深色”三种 App 内外观，默认跟随系统并即时生效。
- 主题只设置 `NSApplication.appearance`，不修改 macOS 全局外观。
- 建立全 App 唯一的视觉 Token、表面角色和材质适配入口。
- macOS 26+ 使用 Apple Liquid Glass；macOS 14-25 使用原生 Material / `NSVisualEffectView` 回退。

## 已确认边界

- 覆盖主窗口、设置、剪贴板、翻译、权限辅助、截图工具面板和 HUD。
- 截图画布、图片像素、选区遮罩、用户标注颜色和最终导出不受主题影响。
- 设置导航壳层已由 012 项目迁移为带独立 Detail `ScrollView` 的原生
  `NavigationSplitView + List(selection:)`；旧固定宽度手动侧栏口径废止。
- 不保留启动参数强制 Aqua/Dark 的另一套运行逻辑。

## 当前事实

- 本轮实施前发现并退出了一个仍带 `-AppleInterfaceStyle Aqua -NSRequiresAquaSystemAppearance YES` 参数运行的旧验收实例。
- 读取到的 macOS 全局 `AppleInterfaceStyle` 仍为 Dark；问题来源是残留 App 进程，不是系统全局偏好被持久化修改。
- 三态 App 外观、统一表面角色和原生材质适配已经实现，并通过自动化测试、静态门禁、Debug 构建和安装版真实操作验收。
- 验收结束后 App 偏好已恢复为“跟随系统”，macOS 全局外观仍为 Dark。
- 低敏证据和残余验证边界记录在[开发与验收记录](开发与验收记录.md)中。
- 原生导航、统一 AppKit Glass 宿主和全局动效的当前口径见
  [012_全局原生玻璃与动效收口](../012_全局原生玻璃与动效收口/index.md)。
- 当前唯一 UI 与交互设计原则、Token、组件和治理口径见
  [017_全局 UI 与交互设计系统](../017_全局UI与交互设计系统/index.md)。与本历史记录冲突时以 017 为准。

## 当前文档

- [全局外观与材质规范](全局外观与材质规范.md)
- [开发与验收记录](开发与验收记录.md)

## 关联入口

- [项目管理库](../index.md)
- [Blocks 正式 macOS App](../../../apps/Blocks/README.md)
