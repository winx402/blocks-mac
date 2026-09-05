import AppKit
import BlocksCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BlocksPluginDestructiveActionConfirmationPresenter {
    typealias WindowProvider = @MainActor () -> NSWindow?
    typealias SheetPresenter = @MainActor (
        NSAlert,
        NSWindow,
        @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void
    typealias SheetDismisser = @MainActor (NSAlert, NSWindow) -> Void

    private final class PresentationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock {
                cancelled = true
            }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    private struct ActivePresentation {
        let id: UUID
        let alert: NSAlert
        let window: NSWindow
        let state: PresentationState
        let continuation: CheckedContinuation<Bool, Never>
        var closeObserver: NSObjectProtocol?
    }

    private let windowProvider: WindowProvider
    private let sheetPresenter: SheetPresenter
    private let sheetDismisser: SheetDismisser
    private var activePresentation: ActivePresentation?

    init(
        windowProvider: @escaping WindowProvider = {
            let candidates: [NSWindow] = [NSApp.keyWindow, NSApp.mainWindow]
                .compactMap { $0 } + NSApp.windows
            return candidates.first { window in
                return window.isVisible
                    && window.level == .normal
                    && window.styleMask.contains(.titled)
            }
        },
        sheetPresenter: @escaping SheetPresenter = { alert, window, completion in
            alert.beginSheetModal(for: window, completionHandler: completion)
        },
        sheetDismisser: @escaping SheetDismisser = { alert, window in
            guard alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    ) {
        self.windowProvider = windowProvider
        self.sheetPresenter = sheetPresenter
        self.sheetDismisser = sheetDismisser
    }

    func present(
        _ request: BlocksPluginDestructiveActionConfirmationRequest,
        pluginDisplayName: String,
        targetDisplayName: String
    ) async -> Bool {
        guard !Task.isCancelled,
              activePresentation == nil,
              let window = windowProvider() else { return false }
        let presentationID = UUID()
        let state = PresentationState()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.string(
            "plugin.runtime.destructiveConfirmation.title"
        )
        alert.informativeText = String(
            format: L10n.string(
                "plugin.runtime.destructiveConfirmation.message"
            ),
            pluginDisplayName,
            targetDisplayName
        )
        alert.addButton(withTitle: L10n.string("plugin.runtime.destructiveConfirmation.delete"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !state.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                activePresentation = ActivePresentation(
                    id: presentationID,
                    alert: alert,
                    window: window,
                    state: state,
                    continuation: continuation
                )
                activePresentation?.closeObserver = NotificationCenter.default
                    .addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.finishPresentation(
                                id: presentationID,
                                state: state,
                                approved: false
                            )
                        }
                    }
                sheetPresenter(alert, window) { [weak self] response in
                    Task { @MainActor in
                        self?.finishPresentation(
                            id: presentationID,
                            state: state,
                            approved: response == .alertFirstButtonReturn
                        )
                    }
                }
            }
        } onCancel: {
            state.cancel()
            Task { @MainActor [weak self] in
                self?.cancelPresentation(id: presentationID, state: state)
            }
        }
    }

    private func finishPresentation(
        id: UUID,
        state: PresentationState,
        approved: Bool
    ) {
        guard let activePresentation,
              activePresentation.id == id,
              activePresentation.state === state else { return }
        self.activePresentation = nil
        if let closeObserver = activePresentation.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        activePresentation.continuation.resume(
            returning: state.isCancelled ? false : approved
        )
        if state.isCancelled {
            sheetDismisser(activePresentation.alert, activePresentation.window)
        }
    }

    private func cancelPresentation(id: UUID, state: PresentationState) {
        guard let activePresentation,
              activePresentation.id == id,
              activePresentation.state === state else { return }
        self.activePresentation = nil
        if let closeObserver = activePresentation.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        activePresentation.continuation.resume(returning: false)
        sheetDismisser(activePresentation.alert, activePresentation.window)
    }
}

struct BlocksPluginUISlotHost: View {
    private struct HostedContribution: Identifiable {
        let pluginID: String
        let contribution: BlocksPluginUIContribution

        var id: String { "\(pluginID):\(contribution.id)" }
    }

    @ObservedObject var manager: BlocksNativePluginManager
    let runtime: BlocksPluginRuntimeCoordinator
    let slot: BlocksPluginUISlot
    var context: [String: JSONValue] = [:]
    var protectedContext: [String: JSONValue] = [:]
    var requiredDataPermission: BlocksNativePluginDataPermission?

    @State private var actionError: String?

    private var contributions: [HostedContribution] {
        manager.plugins.flatMap { plugin -> [HostedContribution] in
            guard plugin.isEnabled,
                  plugin.approvalStatus == .approved,
                  !plugin.safetyDisabled,
                  plugin.approvedPermissions.contains(
                    "ui:\(slot.rawValue)"
                  ),
                  let manifest = manager.manifest(pluginID: plugin.id) else {
                return []
            }
            return (manifest.platform?.ui ?? [])
                .filter { $0.slot == slot }
                .map {
                    HostedContribution(
                        pluginID: plugin.id,
                        contribution: $0
                    )
                }
        }
    }

    @ViewBuilder
    var body: some View {
        ForEach(contributions) { hosted in
            BlocksPluginUIRuntimeContribution(
                pluginID: hosted.pluginID,
                contribution: hosted.contribution,
                runtime: runtime,
                performAction: { actionID, input in
                    perform(
                        pluginID: hosted.pluginID,
                        actionID: actionID,
                        input: input
                    )
                },
                performFileAuthorization: { actionID, input in
                    authorizeFileAndPerform(
                        pluginID: hosted.pluginID,
                        actionID: actionID,
                        input: input
                    )
                }
            )
        }
        if let actionError {
            BlocksInlineFeedback(
                kind: .error,
                title: L10n.string("plugin.center.error.title"),
                detail: actionError
            )
        }
    }

    private func perform(
        pluginID: String,
        actionID: String,
        input: [String: JSONValue]
    ) {
        actionError = nil
        var actionInput = input
        var authorizedContext = context
        if let requiredDataPermission,
           manager.plugins.first(where: { $0.id == pluginID })?
            .approvedPermissions.contains(
                "data:\(requiredDataPermission.rawValue)"
            ) == true {
            authorizedContext.merge(protectedContext) { _, new in new }
        }
        if !authorizedContext.isEmpty {
            actionInput["context"] = .object(authorizedContext)
        }
        Task { @MainActor in
            do {
                _ = try await runtime.performPluginAction(
                    pluginID: pluginID,
                    actionID: actionID,
                    input: actionInput,
                    kind: .uiAction,
                    origin: .explicitUser
                )
            } catch is CancellationError {
                // A declined host confirmation is an intentional no-op.
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func authorizeFileAndPerform(
        pluginID: String,
        actionID: String,
        input: [String: JSONValue]
    ) {
        actionError = nil
        Task { @MainActor in
            guard manager.plugins.first(where: { $0.id == pluginID })?
                .approvedPermissions.contains(
                    BlocksPluginPermissionToken.userGrantedFiles
                )
                == true else {
                actionError = L10n.string(
                    "plugin.center.userFiles.notApproved"
                )
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let mediaType = UTType(
                    filenameExtension: url.pathExtension
                )?.preferredMIMEType
                let reference = try runtime.resources
                    .registerUserAuthorizedFile(
                        url: url,
                        mediaType: mediaType,
                        metadata: [
                            "display_name": .string(url.lastPathComponent),
                        ]
                    )
                runtime.resources.authorize(
                    pluginID: pluginID,
                    resourceIDs: [reference.id]
                )
                defer {
                    runtime.resources.revoke(
                        pluginID: pluginID,
                        resourceIDs: [reference.id]
                    )
                    runtime.resources.remove(ids: [reference.id])
                }
                var actionInput = input
                actionInput["authorized_file"] = .object([
                    "id": .string(reference.id),
                    "kind": .string(reference.kind.rawValue),
                    "media_type": reference.mediaType.map(JSONValue.string)
                        ?? .null,
                    "byte_count": reference.byteCount.map {
                        .int(Int($0))
                    } ?? .null,
                    "sha256": reference.sha256.map(JSONValue.string)
                        ?? .null,
                    "metadata": .object(reference.metadata),
                ])
                _ = try await runtime.performPluginAction(
                    pluginID: pluginID,
                    actionID: actionID,
                    input: actionInput,
                    kind: .uiAction,
                    origin: .explicitUser
                )
            } catch is CancellationError {
                // A declined host confirmation is an intentional no-op.
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

struct BlocksPluginUIRenderer: View {
    let contribution: BlocksPluginUIContribution
    let runtimeState: [String: [String: JSONValue]]
    let performAction: (String, [String: JSONValue]) -> Void
    var performFileAuthorization:
        ((String, [String: JSONValue]) -> Void)? = nil

    @State private var localState: [String: [String: JSONValue]] = [:]

    var body: some View {
        BlocksPluginUIComponentView(
            component: contribution.root,
            rootComponent: contribution.root,
            runtimeState: runtimeState,
            state: $localState,
            performAction: performAction,
            performFileAuthorization: performFileAuthorization
        )
    }
}

/// Narrows runtime observation to one contribution subtree. Pages that host
/// plugin UI can pass the coordinator without observing its full state map,
/// so a patch from one plugin does not invalidate unrelated page chrome.
struct BlocksPluginUIRuntimeContribution: View {
    let pluginID: String
    let contribution: BlocksPluginUIContribution
    @ObservedObject var runtime: BlocksPluginRuntimeCoordinator
    let performAction: (String, [String: JSONValue]) -> Void
    var performFileAuthorization:
        ((String, [String: JSONValue]) -> Void)? = nil

    var body: some View {
        BlocksPluginUIRenderer(
            contribution: contribution,
            runtimeState: runtime.uiStateByPluginID[pluginID] ?? [:],
            performAction: performAction,
            performFileAuthorization: performFileAuthorization
        )
    }
}

enum BlocksPluginUIStateSnapshot {
    static func make(
        root: BlocksPluginUIComponent,
        runtimeState: [String: [String: JSONValue]],
        localState: [String: [String: JSONValue]]
    ) -> [String: JSONValue] {
        var snapshot: [String: JSONValue] = [:]
        collect(
            root,
            runtimeState: runtimeState,
            localState: localState,
            into: &snapshot
        )
        return snapshot
    }

    private static func collect(
        _ node: BlocksPluginUIComponent,
        runtimeState: [String: [String: JSONValue]],
        localState: [String: [String: JSONValue]],
        into snapshot: inout [String: JSONValue]
    ) {
        let merged = node.properties
            .merging(runtimeState[node.id] ?? [:]) { _, new in new }
            .merging(localState[node.id] ?? [:]) { _, new in new }
        snapshot[node.id] = .object(merged)
        for child in node.children {
            collect(
                child,
                runtimeState: runtimeState,
                localState: localState,
                into: &snapshot
            )
        }
    }
}

private struct BlocksPluginUIComponentView: View {
    let component: BlocksPluginUIComponent
    let rootComponent: BlocksPluginUIComponent
    let runtimeState: [String: [String: JSONValue]]
    @Binding var state: [String: [String: JSONValue]]
    let performAction: (String, [String: JSONValue]) -> Void
    let performFileAuthorization:
        ((String, [String: JSONValue]) -> Void)?

    private var properties: [String: JSONValue] {
        component.properties
            .merging(runtimeState[component.id] ?? [:]) { _, new in new }
            .merging(state[component.id] ?? [:]) { _, new in new }
    }

    private var localization: BlocksPluginUIComponentLocalization {
        component.localized()
    }

    private var localizedTitle: String? {
        localization.title ?? component.title
    }

    var body: some View {
        Group {
            switch component.kind {
            case .page, .section:
                VStack(alignment: .leading, spacing: 10) {
                    if let title = localizedTitle {
                        Text(title).font(.headline)
                    }
                    children
                }
            case .card:
                VStack(alignment: .leading, spacing: 8) {
                    if let title = localizedTitle {
                        Text(title).font(.headline)
                    }
                    children
                }
                .padding(12)
                .blocksSurface(
                    .section,
                    cornerRadius: BlocksVisualTokens.CornerRadius.section
                )
            case .list, .table:
                LazyVStack(alignment: .leading, spacing: 0) {
                    children
                    dynamicItems
                }
            case .grid:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                    spacing: 10
                ) {
                    children
                    dynamicItems
                }
            case .title:
                Text(displayText).font(.title3.weight(.semibold))
            case .text:
                Text(displayText)
            case .secondaryText:
                Text(displayText).foregroundStyle(.secondary)
            case .markdown:
                Text(markdownText)
            case .image:
                Image(systemName: string("system_image") ?? "photo")
                    .accessibilityLabel(localizedTitle ?? displayText)
            case .resourcePreview:
                Label(localizedTitle ?? "Resource", systemImage: "doc.richtext")
                    .foregroundStyle(.secondary)
            case .status:
                Label(
                    displayText,
                    systemImage: string("system_image") ?? "info.circle"
                )
            case .progress:
                ProgressView(value: double("value"), total: double("total") ?? 1) {
                    if let title = localizedTitle { Text(title) }
                }
            case .badge:
                Text(displayText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            case .keyValue:
                HStack(alignment: .firstTextBaseline) {
                    Text(localizedTitle ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text(displayText).multilineTextAlignment(.trailing)
                }
            case .empty:
                ContentUnavailableView(
                    localizedTitle ?? "No content",
                    systemImage: "tray",
                    description: Text(displayText)
                )
            case .error:
                Label(displayText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .textField:
                TextField(
                    localizedTitle ?? "",
                    text: stringBinding("value")
                )
            case .textEditor:
                TextEditor(text: stringBinding("value"))
                    .frame(minHeight: 72)
            case .secureField:
                SecureField(
                    localizedTitle ?? "",
                    text: stringBinding("value")
                )
            case .numberField:
                TextField(
                    localizedTitle ?? "",
                    value: doubleBinding("value"),
                    format: .number
                )
            case .toggle:
                BlocksBooleanSwitch(
                    localizedTitle ?? displayText,
                    isOn: boolBinding("value")
                )
            case .choice:
                Picker(localizedTitle ?? "", selection: stringBinding("value")) {
                    ForEach(choiceValues, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .pickerStyle(.menu)
            case .multiChoice:
                Menu(localizedTitle ?? displayText) {
                    ForEach(choiceValues, id: \.self) { value in
                        Button(value) { toggleMultiChoice(value) }
                    }
                }
            case .slider:
                Slider(
                    value: doubleBinding("value"),
                    in: (double("minimum") ?? 0)...(double("maximum") ?? 1)
                )
            case .color:
                ColorPicker(
                    localizedTitle ?? "",
                    selection: colorBinding("value")
                )
            case .fileAuthorization:
                Button {
                    guard let actionID = component.actionID else { return }
                    performFileAuthorization?(actionID, actionInputSnapshot)
                } label: {
                    Label(
                        localizedTitle ?? displayText,
                        systemImage: "folder.badge.plus"
                    )
                }
                .disabled(performFileAuthorization == nil)
            case .tagPicker:
                Menu {
                    ForEach(choiceValues, id: \.self) { value in
                        Button {
                            state[component.id, default: [:]]["value"] =
                                .string(value)
                            if let actionID = component.actionID {
                                performAction(actionID, actionInputSnapshot)
                            }
                        } label: {
                            if string("value") == value {
                                Label(value, systemImage: "checkmark")
                            } else {
                                Text(value)
                            }
                        }
                    }
                } label: {
                    Label(
                        localizedTitle ?? displayText,
                        systemImage: "tag"
                    )
                }
            case .button:
                actionButton(systemImage: string("system_image"))
            case .menu:
                Menu(localizedTitle ?? displayText) {
                    ForEach(component.children) { child in
                        Button(child.title ?? child.id) {
                            if let actionID = child.actionID {
                                performAction(actionID, actionInputSnapshot)
                            }
                        }
                    }
                }
            case .toolbarAction, .contextAction:
                actionButton(systemImage: string("system_image"))
                    .buttonStyle(.borderless)
            case .confirmation:
                actionButton(systemImage: "checkmark.shield")
            }
        }
        .disabled(bool("enabled") == false && properties["enabled"] != nil)
        .opacity(bool("visible") == false ? 0 : 1)
        .allowsHitTesting(bool("visible") != false)
        .accessibilityHidden(bool("visible") == false)
    }

    private var children: some View {
        ForEach(component.children) { child in
            BlocksPluginUIComponentView(
                component: child,
                rootComponent: rootComponent,
                runtimeState: runtimeState,
                state: $state,
                performAction: performAction,
                performFileAuthorization: performFileAuthorization
            )
        }
    }

    @ViewBuilder
    private var dynamicItems: some View {
        ForEach(Array(dynamicItemValues.enumerated()), id: \.offset) { _, item in
            switch item {
            case let .string(value):
                Text(value)
            case let .object(values):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if case let .string(symbol)? = values["system_image"] {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if case let .string(title)? = values["title"] {
                            Text(title)
                        }
                        if case let .string(detail)? = values["detail"] {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if case let .string(value)? = values["value"] {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.vertical, 5)
            default:
                EmptyView()
            }
        }
    }

    private func actionButton(systemImage: String?) -> some View {
        Button {
            guard let actionID = component.actionID else { return }
            performAction(actionID, actionInputSnapshot)
        } label: {
            if let systemImage {
                Label(localizedTitle ?? displayText, systemImage: systemImage)
            } else {
                Text(localizedTitle ?? displayText)
            }
        }
    }

    private var inputSnapshot: [String: JSONValue] {
        properties
    }

    private var actionInputSnapshot: [String: JSONValue] {
        var input = inputSnapshot
        input["ui_state"] = .object(completeUIStateSnapshot)
        return input
    }

    /// Actions receive one stable snapshot of every declared component, not
    /// only fields the user happened to edit. This keeps untouched defaults,
    /// runtime patches and local input values on the same host-owned contract.
    private var completeUIStateSnapshot: [String: JSONValue] {
        BlocksPluginUIStateSnapshot.make(
            root: rootComponent,
            runtimeState: runtimeState,
            localState: state
        )
    }

    private var dynamicItemValues: [JSONValue] {
        guard case let .array(items)? = properties["items"] else { return [] }
        return items
    }

    private var displayText: String {
        if runtimeState[component.id]?["value"] != nil
            || runtimeState[component.id]?["text"] != nil
            || state[component.id]?["value"] != nil
            || state[component.id]?["text"] != nil {
            return string("value") ?? string("text") ?? localizedTitle ?? ""
        }
        return localization.text
            ?? string("value")
            ?? string("text")
            ?? localizedTitle
            ?? ""
    }

    private var markdownText: AttributedString {
        (try? AttributedString(markdown: displayText))
            ?? AttributedString(displayText)
    }

    private var choiceValues: [String] {
        guard case let .array(values)? = properties["choices"] else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }

    private func string(_ key: String) -> String? {
        guard case let .string(value)? = properties[key] else { return nil }
        return value
    }

    private func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = properties[key] else { return nil }
        return value
    }

    private func double(_ key: String) -> Double? {
        switch properties[key] {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { string(key) ?? "" },
            set: { state[component.id, default: [:]][key] = .string($0) }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { bool(key) ?? false },
            set: { state[component.id, default: [:]][key] = .bool($0) }
        )
    }

    private func doubleBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { double(key) ?? 0 },
            set: { state[component.id, default: [:]][key] = .double($0) }
        )
    }

    private func colorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: string(key) ?? "#007AFF") ?? .accentColor },
            set: { state[component.id, default: [:]][key] = .string($0.blocksHex) }
        )
    }

    private func toggleMultiChoice(_ value: String) {
        let existing: [JSONValue]
        if case let .array(values)? = state[component.id]?["value"] {
            existing = values
        } else {
            existing = []
        }
        if existing.contains(.string(value)) {
            state[component.id, default: [:]]["value"] = .array(
                existing.filter { $0 != .string(value) }
            )
        } else {
            state[component.id, default: [:]]["value"] = .array(
                existing + [.string(value)]
            )
        }
    }
}

private extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var blocksHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return "#007AFF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}
