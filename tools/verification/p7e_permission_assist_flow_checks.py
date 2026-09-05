#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from permission_gate_helpers import (
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
)


ROOT = Path(__file__).resolve().parents[2]
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
FLOATING_PANEL_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    presenter = read(PERMISSION_PRESENTER)
    assist_view = read(PERMISSION_VIEW)
    floating_panel_support = read(FLOATING_PANEL_SUPPORT)
    app_model = read(APP_MODEL)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    permission_actions = read(PERMISSION_ACTIONS)
    strings = read(STRINGS)
    owner_chain = permission_assist_owner_chain_checks(presenter, floating_panel_support, assist_view)
    generation = permission_assist_generation_checks(presenter)
    completion = permission_assist_completion_checks(presenter, permission_store)
    contract_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )
    checks = {
        "supports_screen_recording_and_accessibility": "case screenRecording" in presenter and "case accessibility" in presenter,
        "opens_privacy_urls": "Privacy_ScreenCapture" in presenter and "Privacy_Accessibility" in presenter,
        "restores_only_captured_main_settings_window": "final class PermissionAssistMainWindowRestoreSession" in presenter
        and "func mainSettingsWindow() -> NSWindow?" in presenter
        and "func isVisibleRegularMainWindow(_ window: NSWindow) -> Bool" in presenter
        and "window.level == .normal" in presenter
        and "!(window is NSPanel)" in presenter
        and "host.orderOut(window)" in presenter
        and "func restore(for generation: UInt64)" in presenter
        and "host.orderFront(window)" in presenter,
        "locates_system_settings": "SystemSettingsWindowLocator" in presenter and "CGWindowListCopyWindowInfo" in presenter,
        "permission_assist_owner_chain": all(owner_chain.values()),
        "generation_guarded_auto_close_monitor": all(generation.values()),
        "permission_assist_completion_contract": all(completion.values()),
        "permission_assist_contract_mutations_fail_closed": all(contract_mutations.values()),
        "terminal_close_restores_captured_window_once": "func close()" in presenter
        and "guard let generation = activeGeneration else" in presenter
        and "activeGeneration = nil" in presenter
        and "mainWindowRestoreSession.restore(for: generation)" in presenter
        and "private func cancel()" in presenter
        and "func windowWillClose(_ notification: Notification)" in presenter
        and "session.state = .timedOut" in presenter
        and "session.state = .granted" in presenter,
        "animated_arrow_only": "AnimatedPermissionArrow" in assist_view and ".trim(from: 0, to: progress)" in assist_view,
        "appmodel_uses_flow_presenter": "let permissionAssistPanelPresenter = PermissionAssistPanelPresenter()" in app_model
        and "DefaultPermissionAssistPresenter(presenter: permissionAssistPanelPresenter)" in app_model
        and "permissionCoordinator?.requestScreenRecordingPermissionAssist()" in app_model
        and "permissionCoordinator?.presentAccessibilityAssist(onRefresh: onRefresh)" in app_model
        and "store.requestScreenRecordingPermissionAssist" in permission_coordinator
        and "store.requestAccessibilityPermissionAssist" in permission_coordinator
        and "assistPresenter.present(kind: .screenRecording)" in permission_store
        and "assistPresenter.present(kind: .accessibility)" in permission_store
        and "presenter.present(kind: kind, onFlowEnded: onRefresh)" in permission_actions,
        "localized_screen_and_accessibility": "permission.assist.screenRecording.title" in strings and "permission.assist.accessibility.title" in strings,
    }
    ok = all(checks.values())
    print(json.dumps({
        "ok": ok,
        "check": "p7e_permission_assist_flow",
        "checks": checks,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
