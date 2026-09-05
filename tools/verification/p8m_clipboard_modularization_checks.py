#!/usr/bin/env python3
"""Fail-closed architecture checks for the current clipboard panel module boundary."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"

CLIPBOARD_ROOT = APP / "Views/ClipboardFloatingPanelView.swift"
CLIPBOARD_SESSION = APP / "Features/Clipboard/ClipboardPanelSessionModel.swift"
CLIPBOARD_FOCUS = APP / "Features/Clipboard/ClipboardPanelFocusCoordinator.swift"
CLIPBOARD_STORE = APP / "Features/Clipboard/ClipboardStore.swift"
CLIPBOARD_HISTORY_READ_PIPELINE = APP / "Features/Clipboard/ClipboardHistoryReadPipeline.swift"
CLIPBOARD_OCR_SCHEDULER = APP / "Features/Clipboard/ClipboardOCRScheduler.swift"
CLIPBOARD_PANEL_PRESENTATION = APP / "Features/Clipboard/ClipboardFeatureCoordinator+PanelPresentation.swift"
CLIPBOARD_CAPTURE_PERSISTENCE = APP / "Features/Clipboard/ClipboardFeatureCoordinator+CapturePersistence.swift"
APP_STORE_BINDINGS = APP / "App/AppModel+StoreBindings.swift"
COLOR_SAMPLER = APP / "Features/Plugins/ScreenshotColorSampleCoordinator.swift"
CLIPBOARD_HEADER = APP / "Features/Clipboard/Panel/ClipboardPanelHeader.swift"
CLIPBOARD_LAYOUT = APP / "Features/Clipboard/Panel/ClipboardPanelLayout.swift"
CLIPBOARD_RECORD_CONTENT = APP / "Features/Clipboard/Records/ClipboardPanelRecordContent.swift"
CLIPBOARD_FILTER_CONTROLS = APP / "Features/Clipboard/Filters/ClipboardFilterControls.swift"
DETAIL_LAYER = APP / "Features/Clipboard/Detail/ClipboardDetailPresentationLayer.swift"
DETAIL_VIEW = APP / "Features/Clipboard/Detail/ClipboardDetailPresentationView.swift"
DETAIL_PANEL = APP / "Features/Clipboard/Detail/ClipboardDetailPanel.swift"
TRANSLATION_PRESENTER = APP / "Services/TranslationPanelPresenter.swift"
TRANSLATION_VIEW = APP / "Views/TranslationFloatingPanelView.swift"
TRANSLATION_SESSION = APP / "Features/Translation/TranslationPanelSessionModel.swift"

PANEL_APP_MODEL_BOUNDARIES = [
    APP / "Features/Clipboard/ClipboardFeatureCoordinator.swift",
    CLIPBOARD_CAPTURE_PERSISTENCE,
    APP / "Services/ClipboardHistoryPanelPresenter.swift",
    CLIPBOARD_ROOT,
    APP / "Features/Translation/TranslationFeatureCoordinator.swift",
    TRANSLATION_PRESENTER,
    TRANSLATION_VIEW,
]

DETAIL_SOURCES = [DETAIL_LAYER, DETAIL_VIEW, DETAIL_PANEL]
MODULARIZATION_SOURCES = [
    CLIPBOARD_CAPTURE_PERSISTENCE,
    APP_STORE_BINDINGS,
    COLOR_SAMPLER,
    CLIPBOARD_HISTORY_READ_PIPELINE,
    CLIPBOARD_SESSION,
    CLIPBOARD_FOCUS,
    CLIPBOARD_OCR_SCHEDULER,
    CLIPBOARD_PANEL_PRESENTATION,
    TRANSLATION_SESSION.parent / "TranslationServiceRuntime.swift",
    *DETAIL_SOURCES,
]

# These are the current measured sizes of modules that still combine multiple
# responsibilities. They are deliberate non-growth baselines, not acceptance
# thresholds: an existing debt must remain visible without blocking this refresh.
ARCHITECTURE_DEBT_NON_GROWTH_BASELINES = {
    APP / "App/AppModel.swift": 1489,
    APP / "Features/Clipboard/ClipboardFeatureCoordinator.swift": 768,
    CLIPBOARD_ROOT: 813,
    APP / "Features/Translation/TranslationFeatureCoordinator.swift": 634,
    TRANSLATION_VIEW: 962,
}

RETIRED_CLIPBOARD_SYMBOLS = [
    "ClipboardHover",
    "ClipboardFilterClickGroup",
    "detailPrefetchTask",
    "pendingFilterCollapseTask",
]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def relative(path: Path) -> str:
    return str(path.relative_to(ROOT))


def declaration_block(source: str, signature: str) -> str:
    """Return a Swift declaration block using its brace-balanced body."""
    start = source.find(signature)
    if start < 0:
        return ""
    opening_brace = source.find("{", start)
    if opening_brace < 0:
        return ""
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


def swift_without_comments(source: str) -> str:
    """Strip Swift line/block comments before looking for real type dependencies."""
    without_block_comments = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", without_block_comments)


def app_model_references(source: str) -> list[str]:
    return sorted(set(re.findall(
        r"\b(?:AppModel|appModel)\b",
        swift_without_comments(source),
    )))


def missing(source: str, required: list[str]) -> list[str]:
    return [needle for needle in required if needle not in source]


def source_membership_missing(project: str, paths: list[Path]) -> list[str]:
    return [
        path.name
        for path in paths
        if path.name not in project or f"{path.name} in Sources" not in project
    ]


def architecture_contracts(sources: dict[str, str]) -> dict[str, bool]:
    root = sources["root"]
    session = sources["session"]
    focus = sources["focus"]
    header = sources["header"]
    layout = sources["layout"]
    record_content = sources["record_content"]
    filter_controls = sources["filter_controls"]
    detail_layer = sources["detail_layer"]
    detail_view = sources["detail_view"]
    detail_panel = sources["detail_panel"]
    translation_presenter = sources["translation_presenter"]
    translation_view = sources["translation_view"]
    translation_session = sources["translation_session"]
    clipboard_store = sources["clipboard_store"]
    history_read_pipeline = sources["history_read_pipeline"]
    ocr_scheduler = sources["ocr_scheduler"]
    clipboard_coordinator = sources["clipboard_coordinator"]
    clipboard_panel_presentation = sources["clipboard_panel_presentation"]
    clipboard_presenter = sources["clipboard_presenter"]
    translation_coordinator = sources["translation_coordinator"]
    app_model = swift_without_comments(sources["app_model"])
    repository_reload = declaration_block(
        clipboard_store,
        "func loadRepositoryState(limit: Int) -> Bool",
    )

    root_view = declaration_block(root, "struct ClipboardFloatingPanelView: View")
    header_actions = declaration_block(root_view, "private var headerActions")
    pagination = declaration_block(root_view, "private func loadNextPageIfNeeded(")
    detail_monitor_lifecycle = all(
        needle in detail_view
        for needle in [
            "enum ClipboardDetailPresentationMonitoringPolicy",
            "hasWindow && presentedRecordID != nil",
            "private var mouseDownMonitor: Any?",
            "private func startMouseDownMonitor()",
            "guard mouseDownMonitor == nil else",
            "NSEvent.addLocalMonitorForEvents",
            "private func stopMouseDownMonitor()",
            "NSEvent.removeMonitor(mouseDownMonitor)",
            "self.mouseDownMonitor = nil",
            "private func updateInteractionMonitorLifecycle()",
            "startMouseDownMonitor()",
            "stopMouseDownMonitor()",
            "override func viewWillMove(toWindow newWindow: NSWindow?)",
            "override func viewDidMoveToWindow()",
            "func shutdown()",
            "deinit",
            "NSWindow.willCloseNotification",
        ]
    )

    return {
        "root_session_focus_pagination_ownership": all(
            needle in root_view
            for needle in [
                "@StateObject private var session = ClipboardPanelSessionModel()",
                "@FocusState private var searchFocused: Bool",
                "ClipboardPanelRecordFocusAnchor(focusCoordinator: focusCoordinator)",
                "onRecordAppeared: onRecordAppearedForPagination",
                "private func onRecordAppearedForPagination(_ offset: Int)",
                "private func loadNextPageIfNeeded(offset: Int)",
                "session.beginNextPage() != nil",
                "focusCoordinator.presentDetail(recordID: recordID)",
                "focusCoordinator.dismissDetail(recordID: recordID)",
            ]
        ) and all(
            needle in session
            for needle in [
                "final class ClipboardPanelSessionModel: ObservableObject",
                "@Published var query",
                "@Published var selectedRecordID",
                "@Published var detailRecordID",
                "@Published private(set) var visibleRecordLimit",
                "@Published private(set) var paginationRequestInFlight",
                "func beginNextPage() -> Int?",
                "func shutdown()",
            ]
        ) and all(
            needle in focus
            for needle in [
                "final class ClipboardPanelFocusCoordinator: ObservableObject",
                "@Published private(set) var target",
                "func beginSession(sessionID: UUID)",
                "func endSession()",
                "func registerDetailWindow(_ window: NSWindow)",
                "func unregisterDetailWindow(_ window: NSWindow)",
            ]
        ) and "session.beginNextPage() != nil" in pagination,
        "layout_is_pure_assembly": all(
            needle in layout
            for needle in [
                "struct ClipboardPanelLayoutValues",
                "struct ClipboardPanelLayoutActions",
                "struct ClipboardPanelLayout<Header: View, BottomRecord: View, SideRecord: View>: View",
                "let bottomRecordBuilder:",
                "let sideRecordBuilder:",
                "bottomRecordBuilder(record, offset, cardHeight, bodyLineLimit)",
                "sideRecordBuilder(record, offset, rowHeight, bodyLineLimit)",
            ]
        ) and all(
            forbidden not in layout
            for forbidden in [
                "ClipboardStore",
                "clipboardStore",
                "ViewState",
                "@EnvironmentObject",
                "@State",
                "@AppStorage",
                "@FocusState",
                "Task {",
                ".task(",
                ".onAppear",
                "onRecordAppeared",
                "Pagination",
            ]
        ),
        "record_builders_are_injected": all(
            needle in root_view
            for needle in [
                "ClipboardPanelRecordContent(",
                "onRecordAppeared: onRecordAppearedForPagination",
                "bottomRecordBuilder: recordContent.bottomRecordCard",
                "sideRecordBuilder: recordContent.sideRecordRow",
            ]
        ) and all(
            needle in record_content
            for needle in [
                "struct ClipboardPanelRecordContent",
                "let clipboardStore: ClipboardStore",
                "let onRecordAppeared: (Int) -> Void",
                "func bottomRecordCard(",
                "func sideRecordRow(",
                ".onAppear { onRecordAppeared(offset) }",
            ]
        ),
        "pin_uses_injected_actions": (
            header.count("action: actions.onTogglePin") >= 2
            and "onTogglePin: {" in header_actions
            and "guard dismissFloatingDetail() else { return }" in header_actions
            and "onTogglePin()" in header_actions
        ),
        "current_filter_component": (
            "struct ClipboardFilterMenuGroup: View" in filter_controls
            and header.count("ClipboardFilterMenuGroup(") >= 2
        ),
        "current_detail_presentation_chain": all(
            needle in root_view
            for needle in [
                "ClipboardPanelDetailPresentationLayer(",
                "presentedRecordID: session.detailRecordID",
                "onOutsideInteraction: { _ = dismissFloatingDetail() }",
            ]
        ) and all(
            needle in detail_layer
            for needle in [
                "struct ClipboardDetailPresentationOverlay: NSViewRepresentable",
                "func makeNSView(context: Context) -> ClipboardDetailPresentationView",
                "func updateNSView(_ nsView: ClipboardDetailPresentationView, context: Context)",
                "static func dismantleNSView(_ nsView: ClipboardDetailPresentationView, coordinator: ())",
                "nsView.shutdown()",
            ]
        ) and all(
            needle in detail_view
            for needle in [
                "final class ClipboardDetailPresentationView: NSView",
                "ClipboardDetailPanelCoordinator()",
                "struct ClipboardPanelDetailPresentationLayer: View",
                "ClipboardDetailPresentationOverlay(",
            ]
        ) and all(
            needle in detail_panel
            for needle in [
                "final class ClipboardDetailPanelCoordinator: NSObject, NSWindowDelegate",
                "final class ClipboardDetailPanel: NSPanel",
                "item.focusCoordinator.registerDetailWindow(panel)",
                "focusCoordinator?.unregisterDetailWindow(detailPanel)",
            ]
        ),
        "detail_monitor_lifecycle": detail_monitor_lifecycle,
        "translation_presenter_notification_and_result_state": all(
            needle in translation_presenter
            for needle in [
                "private let notificationPresenter =",
                "BlocksAnchoredNotificationPanelPresenter()",
                "notificationState: notificationPresenter.state",
                "notificationPresenter.attach(to: panel)",
            ]
        ) and all(
            needle in translation_view
            for needle in [
                "@ObservedObject var notificationState:",
                "BlocksNotificationPresentationState",
                "if let snapshot = model.snapshot,",
                "!model.resultStates.isEmpty",
                "let resultStates = model.resultStates",
                "TranslationPanelResultStateReader(",
                "Array(resultStates.enumerated())",
            ]
        ) and all(
            needle in translation_session
            for needle in [
                "@Published private(set) var resultStates:",
                "[TranslationPanelResultState] = []",
            ]
        ) and "@StateObject private var notificationState" not in translation_view
        and "ForEach(snapshot.results)" not in translation_view,
        "history_reads_are_serialized_and_generation_guarded": all(
            needle in history_read_pipeline
            for needle in [
                "private let queue = DispatchQueue(",
                'label: "app.blocks.clipboard.history-read"',
                "queue.async",
                "repository.loadRecent(limit: safeLimit)",
                "repository.searchDocuments(",
                "filteringBatch: { candidates in",
            ]
        ) and all(
            needle in clipboard_store
            for needle in [
                "private let historyReadPipeline: ClipboardHistoryReadPipeline",
                "self.historyReadPipeline = ClipboardHistoryReadPipeline(repository: repository)",
                "historyReadGeneration &+= 1",
                "historyReadTask?.cancel()",
                "let snapshot = await pipeline.read(request)",
                "!Task.isCancelled",
                "snapshot.generation == self.historyReadGeneration",
                "self.applyHistoryReadSnapshot(snapshot)",
            ]
        ),
        "repository_reload_uses_async_history_pipeline_only": all(
            needle in repository_reload
            for needle in [
                "lastLoadLimit = safeLimit",
                "refreshSearchResult(",
                "activeSearchLimit ?? safeLimit",
            ]
        ) and all(
            forbidden not in repository_reload
            for forbidden in [
                "repository.loadRecent",
                "repository.loadPreviewSnapshots",
                "tagStore.load",
                "loadPreviewSnapshots(",
                "loadRecordTags(",
            ]
        ),
        "ocr_scheduler_is_store_owned_and_shutdown": all(
            needle in clipboard_store
            for needle in [
                "private var ocrScheduler: ClipboardOCRScheduler?",
                "ocrScheduler = ClipboardOCRScheduler(queue: resolvedOCRQueue)",
                "ocrScheduler?.requestShutdown()",
            ]
        ) and all(
            needle in ocr_scheduler
            for needle in [
                "final class ClipboardOCRScheduler",
                "private var processingTask: Task<Void, Never>?",
                "private var retryTasks: [String: Task<Void, Never>] = [:]",
                "func shutdown()",
                "processingTask?.cancel()",
                "retryTasks.values.forEach { $0.cancel() }",
            ]
        ),
        "clipboard_and_translation_actions_follow_coordinator_presenter_view": all(
            needle in clipboard_coordinator
            for needle in [
                "let clipboardHistoryPanelPresenter: ClipboardHistoryPanelPresenter",
                "clipboardHistoryPanelPresenter: ClipboardHistoryPanelPresenter? = nil",
                "clipboardHistoryPanelPresenter ?? ClipboardHistoryPanelPresenter()",
                "let autoPasteCoordinator: ClipboardAutoPasteCoordinator",
                "let actions = makeClipboardPanelActions()",
                "clipboardHistoryPanelPresenter.present(",
                "actions: actions,",
            ]
        ) and all(
            needle in clipboard_panel_presentation
            for needle in [
                "extension ClipboardFeatureCoordinator",
                "func resolvedFloatingPanelPosition() -> FloatingPanelPosition",
                'UserDefaults.standard.string(forKey: "clipboard.panel.position")',
                "func makeClipboardPanelActions() -> ClipboardPanelActions",
                "ClipboardPanelActions(",
                "pasteQuickRecord: { [weak self]",
                "pasteRecord: { [weak self]",
                "translateRecord: { [weak self]",
                "copyRecordAsPlainText: { [weak self]",
                "deleteHistoryItem: { [weak self]",
                "toggleFavorite: { [weak self]",
                "setTagFilter: { [weak self]",
            ]
        ) and all(
            needle in clipboard_presenter
            for needle in [
                "func present(",
                "actions: ClipboardPanelActions,",
                "ClipboardFloatingPanelView(",
                "actions: actions,",
            ]
        ) and all(
            needle in translation_coordinator
            for needle in [
                "var presenters: [UUID: TranslationPanelPresenter] = [:]",
                "TranslationPanelPresenter(",
                "actions: TranslationPanelActions(",
            ]
        ) and "private let actions: TranslationPanelActions" in translation_presenter
        and "TranslationFloatingPanelView(" in translation_presenter
        and "actions: actions," in translation_presenter
        and not re.search(
            r"\b(?:ClipboardHistoryPanelPresenter|TranslationPanelPresenter|"
            r"ClipboardAutoPasteCoordinator|ClipboardPanelSessionModel|"
            r"TranslationPanelSessionModel|pasteTask|clipboardReadExecution)\b",
            app_model,
        ),
    }


def mutations_fail_closed(sources: dict[str, str]) -> bool:
    """Ensure critical assertions reject a representative architectural regression."""
    mutations = [
        ("root_session_focus_pagination_ownership", "root", "@StateObject private var session = ClipboardPanelSessionModel()"),
        ("layout_is_pure_assembly", "layout", "let bottomRecordBuilder:"),
        ("record_builders_are_injected", "root", "bottomRecordBuilder: recordContent.bottomRecordCard"),
        ("pin_uses_injected_actions", "header", "action: actions.onTogglePin"),
        ("current_filter_component", "header", "ClipboardFilterMenuGroup("),
        ("current_detail_presentation_chain", "root", "ClipboardPanelDetailPresentationLayer("),
        ("detail_monitor_lifecycle", "detail_view", "hasWindow && presentedRecordID != nil"),
        ("translation_presenter_notification_and_result_state", "translation_presenter", "notificationState: notificationPresenter.state"),
        ("history_reads_are_serialized_and_generation_guarded", "clipboard_store", "historyReadGeneration &+= 1"),
        ("repository_reload_uses_async_history_pipeline_only", "clipboard_store", "activeSearchLimit ?? safeLimit"),
        ("ocr_scheduler_is_store_owned_and_shutdown", "clipboard_store", "ocrScheduler?.requestShutdown()"),
        ("clipboard_and_translation_actions_follow_coordinator_presenter_view", "clipboard_panel_presentation", "func makeClipboardPanelActions() -> ClipboardPanelActions"),
    ]
    for contract, source_name, token in mutations:
        source = sources[source_name]
        if token not in source:
            return False
        mutated = dict(sources)
        mutated[source_name] = source.replace(token, "__p8m_mutation__", 1)
        if architecture_contracts(mutated)[contract]:
            return False

    mutated = dict(sources)
    mutated["layout"] += "\nlet clipboardStore: ClipboardStore\n"
    if architecture_contracts(mutated)["layout_is_pure_assembly"]:
        return False

    return app_model_references(
        sources["translation_view"] + "\nlet appModel: AppModel\n"
    ) == ["AppModel", "appModel"]


def main() -> int:
    failures: list[dict[str, object]] = []
    observations: dict[str, object] = {}
    warnings: list[str] = []
    project = text(PROJECT)
    sources = {
        "root": text(CLIPBOARD_ROOT),
        "session": text(CLIPBOARD_SESSION),
        "focus": text(CLIPBOARD_FOCUS),
        "header": text(CLIPBOARD_HEADER),
        "layout": text(CLIPBOARD_LAYOUT),
        "record_content": text(CLIPBOARD_RECORD_CONTENT),
        "filter_controls": text(CLIPBOARD_FILTER_CONTROLS),
        "detail_layer": text(DETAIL_LAYER),
        "detail_view": text(DETAIL_VIEW),
        "detail_panel": text(DETAIL_PANEL),
        "translation_presenter": text(TRANSLATION_PRESENTER),
        "translation_view": text(TRANSLATION_VIEW),
        "translation_session": text(TRANSLATION_SESSION),
        "clipboard_store": text(CLIPBOARD_STORE),
        "history_read_pipeline": text(CLIPBOARD_HISTORY_READ_PIPELINE),
        "ocr_scheduler": text(CLIPBOARD_OCR_SCHEDULER),
        "clipboard_panel_presentation": text(CLIPBOARD_PANEL_PRESENTATION),
        "clipboard_coordinator": text(APP / "Features/Clipboard/ClipboardFeatureCoordinator.swift") + "\n" + text(CLIPBOARD_CAPTURE_PERSISTENCE),
        "clipboard_presenter": text(APP / "Services/ClipboardHistoryPanelPresenter.swift"),
        "translation_coordinator": text(APP / "Features/Translation/TranslationFeatureCoordinator.swift"),
        "app_model": "\n".join(text(path) for path in [APP / "App/AppModel.swift", APP_STORE_BINDINGS, COLOR_SAMPLER]),
    }

    missing_files = [relative(path) for path in [
        CLIPBOARD_ROOT,
        CLIPBOARD_SESSION,
        CLIPBOARD_FOCUS,
        CLIPBOARD_STORE,
        CLIPBOARD_HISTORY_READ_PIPELINE,
        CLIPBOARD_OCR_SCHEDULER,
        CLIPBOARD_PANEL_PRESENTATION,
        CLIPBOARD_CAPTURE_PERSISTENCE,
        APP_STORE_BINDINGS,
        COLOR_SAMPLER,
        CLIPBOARD_HEADER,
        CLIPBOARD_LAYOUT,
        CLIPBOARD_RECORD_CONTENT,
        CLIPBOARD_FILTER_CONTROLS,
        *DETAIL_SOURCES,
        TRANSLATION_PRESENTER,
        TRANSLATION_VIEW,
        TRANSLATION_SESSION,
    ] if not path.exists()]
    if missing_files:
        failures.append({"code": "current_clipboard_module_missing", "detail": missing_files})

    contracts = architecture_contracts(sources)
    invalid_contracts = [name for name, valid in contracts.items() if not valid]
    if invalid_contracts:
        failures.append({"code": "clipboard_modularization_contract_missing", "detail": invalid_contracts})

    retired_scan = "\n".join([project, *sources.values()])
    retired_symbols = [symbol for symbol in RETIRED_CLIPBOARD_SYMBOLS if symbol in retired_scan]
    if retired_symbols:
        failures.append({"code": "retired_clipboard_boundary_retained", "detail": retired_symbols})

    missing_modularization_membership = source_membership_missing(project, MODULARIZATION_SOURCES)
    if missing_modularization_membership:
        failures.append({"code": "clipboard_modularization_sources_membership_missing", "detail": missing_modularization_membership})

    real_appmodel_dependencies: dict[str, list[str]] = {}
    for path in PANEL_APP_MODEL_BOUNDARIES:
        references = app_model_references(text(path))
        if references:
            real_appmodel_dependencies[relative(path)] = references
    if real_appmodel_dependencies:
        failures.append({"code": "panel_uses_appmodel_directly", "detail": real_appmodel_dependencies})

    if not mutations_fail_closed(sources):
        failures.append({
            "code": "clipboard_modularization_mutation_guard_failed",
            "detail": "ownership, injection, detail lifecycle, and translation contracts must fail closed",
        })

    debt_lines = {
        relative(path): len(text(path).splitlines())
        for path in ARCHITECTURE_DEBT_NON_GROWTH_BASELINES
    }
    debt_baselines = {
        relative(path): baseline
        for path, baseline in ARCHITECTURE_DEBT_NON_GROWTH_BASELINES.items()
    }
    debt_growth = {
        relative(path): {"lines": debt_lines[relative(path)], "baseline": baseline}
        for path, baseline in ARCHITECTURE_DEBT_NON_GROWTH_BASELINES.items()
        if debt_lines[relative(path)] > baseline
    }
    if debt_growth:
        failures.append({"code": "architecture_debt_line_growth", "detail": debt_growth})
    for path, baseline in ARCHITECTURE_DEBT_NON_GROWTH_BASELINES.items():
        warnings.append(
            f"architecture debt: {relative(path)} has {debt_lines[relative(path)]} lines; non-growth baseline is {baseline}"
        )

    observations["clipboard_modularization_contracts"] = contracts
    observations["retired_clipboard_symbols"] = retired_symbols
    observations["real_appmodel_dependencies_after_comment_stripping"] = real_appmodel_dependencies
    observations["clipboard_modularization_sources_membership"] = {
        path.name: path.name not in missing_modularization_membership
        for path in MODULARIZATION_SOURCES
    }
    observations["architecture_debt"] = {
        "current_lines": debt_lines,
        "non_growth_baselines": debt_baselines,
        "status": "warning: existing concentrated responsibilities remain and must not grow",
    }

    output = {
        "ok": not failures,
        "suite": "p8m_clipboard_modularization_checks",
        "failures": failures,
        "observations": observations,
        "warnings": warnings,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
