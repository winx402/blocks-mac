#!/bin/bash

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$root/apps/Blocks/BlocksApp"
foundation_files=(
  "$app_root/Support/DesignSystemFoundation.swift"
  "$app_root/Support/DesignSystemComponents.swift"
  "$app_root/Support/GlassPanel.swift"
)
spec_root="$root/docs/项目管理库/017_全局UI与交互设计系统"
ui_standard_root="$root/docs/产品知识库/UI与交互规范"
settings_foundation="$app_root/Features/Settings/SettingsSectionList.swift"
settings_roots=(
  "$app_root/Features/Settings"
  "$app_root/Features/Privacy"
  "$app_root/Features/Screenshot/Settings"
  "$app_root/Features/Translation/TranslationFavoritesPane.swift"
)

fail() {
  echo "UI design-system gate failed: $*" >&2
  exit 1
}

assert_no_matches() {
  local label="$1"
  shift
  local matches
  matches="$(rg -n "$@" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "$matches" >&2
    fail "$label"
  fi
}

required_foundation_symbols=(
  'enum BlocksVisualTokens'
  'enum BlocksInteractionState'
  'enum BlocksMotionRole'
  'enum BlocksSurfaceRole'
  'struct BlocksActionButton'
  'struct BlocksCompactActionGroup'
  'struct BlocksCompactControlGroup'
  'struct BlocksBooleanSwitch'
  'struct BlocksInlineFeedback'
  'struct BlocksSelectableChip'
  'struct BlocksSelectableTile'
  'struct BlocksToolbarContainer'
  'struct BlocksPanelChrome'
  'struct BlocksStateView'
  'final class BlocksImmediateTooltipHostModel'
  'struct BlocksDesignSystemGallery'
)

for symbol in "${required_foundation_symbols[@]}"; do
  rg -q --fixed-strings "$symbol" "${foundation_files[@]}" \
    || fail "missing shared foundation symbol: $symbol"
done

required_settings_symbols=(
  'struct SettingsSectionHeader'
  'struct SettingsSection'
  'struct SettingsValueColumn'
  'struct SettingsFormRow'
  'struct SettingsSegmentedRow'
  'struct SettingsBooleanSwitch'
  'struct SettingsToggleRow'
  'struct SettingsNavigationRow'
  'struct SettingsDangerRow'
  'struct SettingsFeedbackSlot'
  'struct SettingsStateView'
  'struct SettingsSheetScaffold'
  'struct SettingsSecondaryPageHeader'
  'struct SettingsDesignSystemGallery'
)

for symbol in "${required_settings_symbols[@]}"; do
  rg -q --fixed-strings "$symbol" "$settings_foundation" \
    || fail "missing canonical settings component: $symbol"
done

rg -q --fixed-strings \
  '.padding(.horizontal, SettingsLayout.sectionContentHorizontalInset)' \
  "$settings_foundation" \
  || fail "settings header and content must share the canonical horizontal inset"

[[ "$(rg -c --fixed-strings '.padding(.horizontal, SettingsLayout.sectionContentHorizontalInset)' "$settings_foundation")" -ge 2 ]] \
  || fail "settings header and section content must both use the canonical horizontal inset"

rg -q --fixed-strings 'SettingsValueColumn {' \
  "$settings_foundation" \
  || fail "SettingsRowShell must own the shared trailing value column"

assert_no_matches \
  "retired title-line settings alignment must not return" \
  'settingsTitleLineCenter|SettingsTitleLineCenterAlignment' \
  "${settings_roots[@]}" -g '*.swift'

assert_no_matches \
  "retired plugin catalog filters must not return" \
  'PluginCenterFilter|settings\.plugins\.filter|plugin\.center\.filter\.' \
  "$app_root" -g '*.swift' -g '*.xcstrings'

if rg -q 'Settings(TableSection|TrailingControl|LabeledToggle)' \
  "${settings_roots[@]}" -g '*.swift'; then
  fail "legacy settings section, trailing, or toggle compatibility components are forbidden"
fi

raw_settings_toggles="$({
  rg -n '\bToggle\s*\(' "${settings_roots[@]}" -g '*.swift' || true
} | awk '!/\/Features\/Settings\/SettingsSectionList\.swift:/' || true)"
if [[ -n "$raw_settings_toggles" ]]; then
  echo "$raw_settings_toggles" >&2
  fail "settings pages must use SettingsBooleanSwitch or SettingsCheckbox instead of raw Toggle"
fi

assert_no_matches \
  "plugin surfaces must use the shared boolean switch" \
  '\bToggle\s*\(' \
  "$app_root/Features/Plugins" \
  "$app_root/Features/Settings/HooksSettingsPane.swift" \
  -g '*.swift'

assert_no_matches \
  "unused local CLI label setting must not return" \
  'provider\.localCLI\.name' \
  "$app_root" -g '*.swift'

assert_no_matches \
  "generic plugin runtime must not live under the translation feature" \
  'Features/Translation/Plugins/BlocksNativePlugin' \
  "$root/apps/Blocks/Blocks.xcodeproj/project.pbxproj"

if rg -q '\.tag\((true|false)\)|\.tag\(Bool\.' \
  "${settings_roots[@]}" -g '*.swift'; then
  fail "boolean settings must not be represented by picker, radio, or segmented tags"
fi

rg -q 'settingsFormContentMaxWidth: CGFloat = 820' \
  "$app_root/Support/DesignSystemFoundation.swift" \
  || fail "form settings width must use the canonical 820pt token"
rg -q 'settingsCollectionContentMaxWidth: CGFloat = 1120' \
  "$app_root/Support/DesignSystemFoundation.swift" \
  || fail "content settings width must use the canonical 1120pt token"
rg -q 'settingsSheetContentMaxWidth: CGFloat = 640' \
  "$app_root/Support/DesignSystemFoundation.swift" \
  || fail "settings sheets must use the canonical 640pt token"

if rg -q '\.id\(appModel\.selectedSection\)' \
  "$app_root/Views/ContentView.swift" \
  "$app_root/Features/Settings/SettingsShellView.swift"; then
  fail "settings detail must not rebuild from appModel.selectedSection"
fi

if rg -q 'trailingWidth:|SettingsValueColumn\(width:|\.frame\(width:\s*280' \
  "${settings_roots[@]}" -g '*.swift'; then
  fail "settings pages must not override the canonical trailing column"
fi

if rg -q 'ViewThatFits|verticalLayout' "$settings_foundation"; then
  fail "settings title and value controls must remain in one aligned row"
fi

assert_no_matches \
  "literal corner radii are forbidden in settings scope" \
  'cornerRadius:\s*[0-9]+(\.[0-9]+)?|\.cornerRadius\([0-9]+' \
  "${settings_roots[@]}" -g '*.swift'

required_specs=(
  index.md
  当前安装版体验审计.md
  全局设计原则.md
  设计Token与组件规范.md
  动效与交互状态规范.md
  模块改造TODO.md
  验收矩阵.md
)

for spec in "${required_specs[@]}"; do
  [[ -f "$spec_root/$spec" ]] || fail "missing Phase 0 specification: $spec"
done

required_ui_standards=(
  index.md
  布局与对齐.md
  控件语义与交互.md
  状态反馈与动效.md
  验收与证据.md
)

for spec in "${required_ui_standards[@]}"; do
  [[ -f "$ui_standard_root/$spec" ]] \
    || fail "missing long-term UI standard: $spec"
done

rg -q --fixed-strings 'docs/产品知识库/UI与交互规范/index.md' \
  "$root/AGENTS.md" \
  || fail "AGENTS.md must point every UI task to the long-term UI standard"

legacy_alias_pattern='BlocksSurfaceRole\.(settingsSection|floatingPanel)|role:\s*\.(settingsSection|floatingPanel)|\.blocksSurface\(\.(settingsSection|floatingPanel)|BlocksMotionRole\.(microFeedback|stateChange|navigation)|\.blocksAnimation\(\.(microFeedback|stateChange|navigation)|BlocksVisualTokens\.Spacing\.(compact|standard|section|panel)|BlocksVisualTokens\.CornerRadius\.(surface|panel)|settingsContentMaxWidth'
assert_no_matches \
  "legacy visual aliases must be zero" \
  "$legacy_alias_pattern" \
  "$app_root" -g '*.swift'

assert_no_matches \
  "feature modules must not declare private ButtonStyle implementations" \
  'struct [A-Za-z0-9_]+:\s*ButtonStyle' \
  "$app_root/Features" "$app_root/Views" -g '*.swift'

assert_no_matches \
  "screenshot chrome must not restore retired private control paths" \
  'ScreenshotToolbarGroup|ScreenshotFocusableIconNSButton|ScreenshotQuietToolbarButton|ScreenshotParameterControlChrome|ScreenshotImmediateTooltip|screenshotImmediateTooltip|BlocksIconButtonStyle\(|ScreenshotDesignTokens\.(minimumHitTarget|primaryControlHeight|floatingPanelEdgeInset)' \
  "$app_root/Features/Screenshot" "$root/apps/Blocks/BlocksAppTests" -g '*.swift'

assert_no_matches \
  "literal corner radii outside the foundation must be zero" \
  'cornerRadius:\s*[0-9]+(\.[0-9]+)?|\.cornerRadius\([0-9]+' \
  "$app_root" -g '*.swift' \
  -g '!**/Support/GlassPanel.swift' \
  -g '!**/Support/DesignSystemFoundation.swift' \
  -g '!**/Support/DesignSystemComponents.swift'

assert_no_matches \
  "shadows must be rendered by the shared surface foundation" \
  '\.shadow\s*\(' \
  "$app_root" -g '*.swift' \
  -g '!**/Support/GlassPanel.swift' \
  -g '!**/Support/DesignSystemFoundation.swift' \
  -g '!**/Support/DesignSystemComponents.swift'

assert_no_matches \
  "unscoped animation calls outside the foundation must be zero" \
  '^[[:space:]]*\.animation\s*\(' \
  "$app_root" -g '*.swift' \
  -g '!**/Support/GlassPanel.swift' \
  -g '!**/Support/DesignSystemFoundation.swift' \
  -g '!**/Support/DesignSystemComponents.swift'

assert_no_matches \
  "direct native material calls outside the foundation must be zero" \
  '(\.background|\.fill)\s*\(\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|bar)|NSVisualEffectView\.Material' \
  "$app_root" -g '*.swift' \
  -g '!**/Support/GlassPanel.swift' \
  -g '!**/Support/DesignSystemFoundation.swift' \
  -g '!**/Support/DesignSystemComponents.swift'

fixed_structural_colors="$({
  rg -n '\.(background|fill)\s*\((Color\.)?(white|black)\b' \
    "$app_root" -g '*.swift' || true
} | awk '!/\/Features\/Screenshot\// && !/\/Support\/(GlassPanel|DesignSystemFoundation|DesignSystemComponents)\.swift:/' \
  | awk '!/\/Views\/ClipboardRecordViews\.swift:/' \
  | awk '!/\/Features\/Clipboard\/Detail\/ClipboardFloatingDetailCard\.swift:/' \
  | wc -l | tr -d ' ')"
(( fixed_structural_colors == 0 )) \
  || fail "fixed structural black/white colors must be zero outside declared pixel-preview paths"

assert_no_matches \
  "Reduce Motion bypasses must be zero" \
  'reduceMotion:\s*false' \
  "$app_root" -g '*.swift'

assert_no_matches \
  "application chrome must use native system typography" \
  'PingFangSC|Font\.custom\(' \
  "$app_root" -g '*.swift'

echo "UI design-system gate passed. Canonical paths are enforced with zero legacy aliases."
