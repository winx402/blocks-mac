---
id: P7-B
title: Settings Sidebar Stability Fix
status: implemented
date: 2026-07-03
sourcePlan: 用户反馈 Settings 页面点击左侧菜单后菜单持续上移
relatedDocs:
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P7-B Settings Sidebar Stability Fix

## Scope

修复 Settings 详情页导致主窗口左侧菜单在反复点击后持续上移的问题。本轮只调整 Settings 详情布局，不新增设置项、不改变 provider、剪贴板、截图或翻译运行边界。

## Root Cause

Settings 详情原来使用一个未约束的 root `Form`，并直接作为 `NavigationSplitView` 的 detail 内容。随着 Settings 内容不断变长，`Form` 的理想高度会参与 split view 根布局计算；在反复切换或点击左侧菜单时，主侧边栏会被超高 detail 布局挤压，出现整体向上漂移。

## Fix

- Settings 详情改为 top-anchored `ScrollView`，让滚动只发生在 Settings detail 内部。
- 原设置内容保留，分组改为 `SettingsSection` 卡片，避免 root `Form` 的平台布局参与 split view 计算。
- 主窗口左侧菜单仍使用原生 `NavigationSplitView` + `List(selection:)`，不改为自绘 sidebar。

## Acceptance Notes

- Given 用户在主窗口左侧菜单反复点击 Screenshot / Clipboard / Translation / Settings，Then 左侧菜单位置不应逐次向上漂移。
- Given Settings 内容高度超过窗口，Then 只有 Settings detail 内部滚动，主侧边栏保持稳定。
- Given Settings 在独立 macOS Settings scene 打开，Then 内容仍可垂直滚动查看。

## Verification

- `python3 tools/verification/p7b_settings_sidebar_stability_checks.py --timeout 180`
- `python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
