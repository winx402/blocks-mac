import Foundation

public enum BlocksPluginPermissionToken {
    public static let privateStorage = "storage:private"
    public static let userGrantedFiles = "data:user_granted_files"
}

/// Versioned host action registry for Manifest v4. Plugins may only request
/// actions in this registry; adding an action is a host contract change and
/// therefore requires a new app release and renewed package approval.
public enum BlocksPluginHostActionRegistryV1 {
    public static let version = 1
    public static let actionIDs: Set<String> = [
        "clipboard.copy_text",
        "clipboard.paste_record",
        "clipboard.record.bring_to_front",
        "clipboard.record.delete",
        "clipboard.record.favorite",
        "clipboard.record.ocr",
        "clipboard.record.read",
        "clipboard.record.update",
        "clipboard.tag.attach",
        "clipboard.tag.delete",
        "clipboard.tag.detach",
        "clipboard.tag.ensure",
        "clipboard.tag.ensure_and_attach",
        "clipboard.tag.list",
        "clipboard.tag.rename",
        "provider.capabilities.query",
        "provider.request",
        "screenshot.annotation.add_text",
        "screenshot.annotation.delete",
        "screenshot.annotation.update_text",
        "screenshot.capture.start",
        "screenshot.corner_radius.set",
        "screenshot.document.snapshot",
        "screenshot.ocr",
        "screenshot.output.archive",
        "screenshot.output.complete",
        "screenshot.output.copy",
        "screenshot.output.pin",
        "screenshot.output.save",
        "screenshot.watermark.apply_default",
        "system.notification",
        "system.open_plugin_page",
        "system.schedule.set_enabled",
        "system.shortcut.execute",
        "translation.cancel",
        "translation.copy",
        "translation.favorite",
        "translation.retry",
        "translation.run",
    ]

    /// Every public host action must have an explicit risk classification.
    /// Unknown IDs are intentionally not silently treated as safe.
    public enum Risk: String, Codable, Sendable {
        case ordinary
        case destructive
        case unknown
    }

    public static func risk(for actionID: String) -> Risk {
        switch actionID {
        case "clipboard.record.delete", "clipboard.tag.delete":
            return .destructive
        case "screenshot.color_sample.begin":
            // V2 adds this public action outside the V1 ID set.  Keep its
            // classification explicit so the fail-closed registry does not
            // reject a declared host capability as unknown.
            return .ordinary
        case let id where actionIDs.contains(id):
            return .ordinary
        default:
            return .unknown
        }
    }
}

/// Current public host API exposed to every approved plugin.
///
/// Keep this registry capability-based: entries describe reusable host
/// behavior and must never be tied to one bundled or third-party plugin ID.
public enum BlocksPluginHostAPIV2 {
    public static let version = 2
    public static let actionIDs: Set<String> =
        BlocksPluginHostActionRegistryV1.actionIDs.union([
            "screenshot.color_sample.begin",
        ])
}

public struct BlocksPluginHostCapabilityDescriptor:
    Codable,
    Equatable,
    Sendable,
    Identifiable
{
    public let id: String
    public let apiVersion: Int
    public let inputSchema: [String: JSONValue]
    public let outputSchema: [String: JSONValue]
    public let requiredPermissions: [String]
    public let risk: BlocksPluginHostActionRegistryV1.Risk

    public init(
        id: String,
        apiVersion: Int = BlocksPluginHostAPIV2.version,
        inputSchema: [String: JSONValue] = [:],
        outputSchema: [String: JSONValue] = [:],
        requiredPermissions: [String] = [],
        risk: BlocksPluginHostActionRegistryV1.Risk? = nil
    ) {
        self.id = id
        self.apiVersion = apiVersion
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.requiredPermissions = requiredPermissions
        self.risk = risk ?? BlocksPluginHostActionRegistryV1.risk(for: id)
    }
}

// MARK: - Event contract

public enum BlocksPluginModule: String, Codable, CaseIterable, Sendable {
    case clipboard
    case screenshot
    case translation
    case provider
    case automation
    case app
    case plugin
}

public enum BlocksPluginEventPhase: String, Codable, Sendable {
    case will
    case did
    case failed
    case manual
    case scheduled

    public var canMutateTransaction: Bool { self == .will }
}

public enum BlocksPluginEventName: String, Codable, CaseIterable, Sendable {
    case clipboardWillPersistCapture = "clipboard.will_persist_capture"
    case clipboardDidPersistCapture = "clipboard.did_persist_capture"
    case clipboardCaptureFailed = "clipboard.capture_failed"
    case clipboardWillWritePasteboard = "clipboard.will_write_pasteboard"
    case clipboardDidDispatchPaste = "clipboard.did_dispatch_paste"
    case clipboardPasteFailed = "clipboard.paste_failed"
    case clipboardRecordUpdated = "clipboard.record_updated"
    case clipboardRecordDeleted = "clipboard.record_deleted"
    case clipboardTagChanged = "clipboard.tag_changed"
    case clipboardOCRCompleted = "clipboard.ocr_completed"

    case screenshotCaptureCompleted = "screenshot.capture_completed"
    case screenshotCaptureFailed = "screenshot.capture_failed"
    case screenshotEditorOpened = "screenshot.editor_opened"
    case screenshotElementCommitted = "screenshot.element_committed"
    case screenshotWillFinalizeOutput = "screenshot.will_finalize_output"
    case screenshotOutputFinished = "screenshot.output_finished"
    case screenshotOutputFailed = "screenshot.output_failed"
    case screenshotOCRCompleted = "screenshot.ocr_completed"
    case screenshotLongCaptureAssembled = "screenshot.long_capture_assembled"

    case translationInputResolved = "translation.input_resolved"
    case translationWillRunSession = "translation.will_run_session"
    case translationSessionCompleted = "translation.session_completed"
    case translationSessionFailed = "translation.session_failed"
    case translationSourceStatus = "translation.source_status"
    case translationSourceResult = "translation.source_result"
    case translationSourceFailed = "translation.source_failed"
    case translationWillCommitResult = "translation.will_commit_result"
    case translationFavoriteChanged = "translation.favorite_changed"
    case translationCopyCompleted = "translation.copy_completed"

    case providerRouteResolved = "provider.route_resolved"
    case providerWillSendRequest = "provider.will_send_request"
    case providerRequestCompleted = "provider.request_completed"
    case providerRequestFailed = "provider.request_failed"

    case automationWillExecuteShortcut = "automation.will_execute_shortcut"
    case automationDidExecuteShortcut = "automation.did_execute_shortcut"
    case automationManualTrigger = "automation.manual_trigger"
    case automationScheduledTrigger = "automation.scheduled_trigger"

    case appLaunched = "app.launched"
    case appWillTerminate = "app.will_terminate"
    case pluginLifecycleChanged = "plugin.lifecycle_changed"
    case pluginSharedStateChanged = "plugin.shared_state_changed"
    case pluginHostActionCompleted = "plugin.host_action_completed"
    case pluginHostActionFailed = "plugin.host_action_failed"

    public var module: BlocksPluginModule {
        switch self {
        case .clipboardWillPersistCapture, .clipboardDidPersistCapture,
             .clipboardCaptureFailed, .clipboardWillWritePasteboard,
             .clipboardDidDispatchPaste, .clipboardPasteFailed,
             .clipboardRecordUpdated, .clipboardRecordDeleted,
             .clipboardTagChanged, .clipboardOCRCompleted:
            return .clipboard
        case .screenshotCaptureCompleted, .screenshotCaptureFailed,
             .screenshotEditorOpened, .screenshotElementCommitted,
             .screenshotWillFinalizeOutput, .screenshotOutputFinished,
             .screenshotOutputFailed, .screenshotOCRCompleted,
             .screenshotLongCaptureAssembled:
            return .screenshot
        case .translationInputResolved, .translationWillRunSession,
             .translationSessionCompleted, .translationSessionFailed,
             .translationSourceStatus, .translationSourceResult,
             .translationSourceFailed, .translationWillCommitResult,
             .translationFavoriteChanged, .translationCopyCompleted:
            return .translation
        case .providerRouteResolved, .providerWillSendRequest,
             .providerRequestCompleted, .providerRequestFailed:
            return .provider
        case .automationWillExecuteShortcut, .automationDidExecuteShortcut,
             .automationManualTrigger, .automationScheduledTrigger:
            return .automation
        case .appLaunched, .appWillTerminate:
            return .app
        case .pluginLifecycleChanged, .pluginSharedStateChanged,
             .pluginHostActionCompleted, .pluginHostActionFailed:
            return .plugin
        }
    }

    public var phase: BlocksPluginEventPhase {
        if rawValue.contains(".will_") { return .will }
        if rawValue.hasSuffix("_failed") { return .failed }
        if self == .automationManualTrigger { return .manual }
        if self == .automationScheduledTrigger { return .scheduled }
        return .did
    }

    /// Only these transaction fields may be changed by a `will.*` hook.
    /// Identity, revision, authorization and resource handles are immutable.
    public var mutablePayloadFields: Set<String> {
        switch self {
        case .clipboardWillPersistCapture:
            ["summary", "excluded"]
        case .clipboardWillWritePasteboard:
            ["text", "plain_text"]
        case .screenshotWillFinalizeOutput:
            ["format", "watermark_preset_id", "corner_radius_enabled"]
        case .translationWillRunSession:
            ["source_text", "source_language", "target_language"]
        case .translationWillCommitResult:
            ["translated_text"]
        case .providerWillSendRequest:
            ["model", "temperature", "maximum_tokens", "metadata"]
        case .automationWillExecuteShortcut:
            ["input"]
        default:
            []
        }
    }
}

public struct BlocksPluginAuthorizationContext: Codable, Equatable, Sendable {
    public let approvedPermissionTokens: [String]
    public let approvedDomains: [String]
    public let userInitiated: Bool

    public init(
        approvedPermissionTokens: [String] = [],
        approvedDomains: [String] = [],
        userInitiated: Bool = false
    ) {
        self.approvedPermissionTokens = approvedPermissionTokens
        self.approvedDomains = approvedDomains
        self.userInitiated = userInitiated
    }

    private enum CodingKeys: String, CodingKey {
        case approvedPermissionTokens = "approved_permission_tokens"
        case approvedDomains = "approved_domains"
        case userInitiated = "user_initiated"
    }
}

public enum BlocksPluginResourceKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case file
    case screenshot
    case binary
}

public struct BlocksPluginResourceReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: BlocksPluginResourceKind
    public let mediaType: String?
    public let byteCount: Int64?
    public let sha256: String?
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        kind: BlocksPluginResourceKind,
        mediaType: String? = nil,
        byteCount: Int64? = nil,
        sha256: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, metadata
        case mediaType = "media_type"
        case byteCount = "byte_count"
        case sha256
    }
}

public struct BlocksPluginEventEnvelope: Codable, Equatable, Sendable {
    /// Schema v2 adds the complete, permission-filtered content snapshot to
    /// post-persistence clipboard events. Existing plugins remain compatible
    /// because the additions are optional payload fields and resources.
    public static let currentSchemaVersion = 2

    public let eventID: UUID
    public let schemaVersion: Int
    public let name: BlocksPluginEventName
    public let occurredAt: Date
    public let sessionID: String?
    public let requestID: String?
    public let revision: Int64?
    public let causationID: UUID
    public let source: [String: JSONValue]
    public let authorization: BlocksPluginAuthorizationContext
    public let payload: [String: JSONValue]
    public let resources: [BlocksPluginResourceReference]

    public init(
        eventID: UUID = UUID(),
        name: BlocksPluginEventName,
        occurredAt: Date = Date(),
        sessionID: String? = nil,
        requestID: String? = nil,
        revision: Int64? = nil,
        causationID: UUID? = nil,
        source: [String: JSONValue] = [:],
        authorization: BlocksPluginAuthorizationContext = .init(),
        payload: [String: JSONValue] = [:],
        resources: [BlocksPluginResourceReference] = []
    ) {
        self.eventID = eventID
        schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.occurredAt = occurredAt
        self.sessionID = sessionID
        self.requestID = requestID
        self.revision = revision
        self.causationID = causationID ?? eventID
        self.source = source
        self.authorization = authorization
        self.payload = payload
        self.resources = resources
    }

    public var module: BlocksPluginModule { name.module }
    public var phase: BlocksPluginEventPhase { name.phase }

    private enum CodingKeys: String, CodingKey {
        case name, source, authorization, payload, resources
        case eventID = "event_id"
        case schemaVersion = "schema_version"
        case occurredAt = "occurred_at"
        case sessionID = "session_id"
        case requestID = "request_id"
        case revision
        case causationID = "causation_id"
    }
}

// MARK: - Hook output and host actions

public enum BlocksPluginHookDisposition: String, Codable, Sendable {
    case allow
    case block
}

public struct BlocksPluginMutation: Codable, Equatable, Sendable {
    public let field: String
    public let value: JSONValue

    public init(field: String, value: JSONValue) {
        self.field = field
        self.value = value
    }
}

public struct BlocksPluginActionInvocation: Codable, Equatable, Sendable {
    public let actionID: String
    public let input: [String: JSONValue]
    public let idempotencyKey: String?
    public let expectedRevision: Int64?

    public init(
        actionID: String,
        input: [String: JSONValue] = [:],
        idempotencyKey: String? = nil,
        expectedRevision: Int64? = nil
    ) {
        self.actionID = actionID
        self.input = input
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case input
        case idempotencyKey = "idempotency_key"
        case expectedRevision = "expected_revision"
    }
}

public enum BlocksPluginUIStatePatchOperation: String, Codable, Sendable {
    case replace
    case append
    case remove
}

public struct BlocksPluginUIStatePatch: Codable, Equatable, Sendable {
    public let componentID: String
    public let property: String
    public let operation: BlocksPluginUIStatePatchOperation
    public let value: JSONValue?

    public init(
        componentID: String,
        property: String,
        operation: BlocksPluginUIStatePatchOperation = .replace,
        value: JSONValue? = nil
    ) {
        self.componentID = componentID
        self.property = property
        self.operation = operation
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case property, operation, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        componentID = try container.decode(String.self, forKey: .componentID)
        property = try container.decode(String.self, forKey: .property)
        operation = try container.decodeIfPresent(
            BlocksPluginUIStatePatchOperation.self, forKey: .operation
        ) ?? .replace
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value)
    }
}

public enum BlocksPluginDiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct BlocksPluginDiagnostic: Codable, Equatable, Sendable {
    public let level: BlocksPluginDiagnosticLevel
    public let code: String
    public let message: String
    public let metadata: [String: JSONValue]

    public init(
        level: BlocksPluginDiagnosticLevel,
        code: String,
        message: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.level = level
        self.code = code
        self.message = message
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case level, code, message, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decode(BlocksPluginDiagnosticLevel.self, forKey: .level)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        metadata = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .metadata
        ) ?? [:]
    }
}

public struct BlocksPluginHookResult: Codable, Equatable, Sendable {
    public let disposition: BlocksPluginHookDisposition
    public let reason: String?
    public let mutations: [BlocksPluginMutation]
    public let actions: [BlocksPluginActionInvocation]
    public let uiStatePatches: [BlocksPluginUIStatePatch]
    public let diagnostics: [BlocksPluginDiagnostic]

    public init(
        disposition: BlocksPluginHookDisposition = .allow,
        reason: String? = nil,
        mutations: [BlocksPluginMutation] = [],
        actions: [BlocksPluginActionInvocation] = [],
        uiStatePatches: [BlocksPluginUIStatePatch] = [],
        diagnostics: [BlocksPluginDiagnostic] = []
    ) {
        self.disposition = disposition
        self.reason = reason
        self.mutations = mutations
        self.actions = actions
        self.uiStatePatches = uiStatePatches
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case disposition, reason, mutations, actions, diagnostics
        case uiStatePatches = "ui_state_patches"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disposition = try container.decodeIfPresent(
            BlocksPluginHookDisposition.self,
            forKey: .disposition
        ) ?? .allow
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        mutations = try container.decodeIfPresent(
            [BlocksPluginMutation].self,
            forKey: .mutations
        ) ?? []
        actions = try container.decodeIfPresent(
            [BlocksPluginActionInvocation].self,
            forKey: .actions
        ) ?? []
        uiStatePatches = try container.decodeIfPresent(
            [BlocksPluginUIStatePatch].self,
            forKey: .uiStatePatches
        ) ?? []
        diagnostics = try container.decodeIfPresent(
            [BlocksPluginDiagnostic].self,
            forKey: .diagnostics
        ) ?? []
    }
}

// MARK: - Manifest v4 declarations

public enum BlocksPluginFailurePolicy: String, Codable, Sendable {
    case failOpen = "fail_open"
    case failClosed = "fail_closed"
}

public struct BlocksPluginHookSubscription: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let event: BlocksPluginEventName
    public let entryFunction: String
    public let timeoutMilliseconds: Int
    public let failurePolicy: BlocksPluginFailurePolicy
    public let runsInBackground: Bool

    public init(
        id: String,
        event: BlocksPluginEventName,
        entryFunction: String = "handleHook",
        timeoutMilliseconds: Int = 500,
        failurePolicy: BlocksPluginFailurePolicy = .failOpen,
        runsInBackground: Bool = true
    ) {
        self.id = id
        self.event = event
        self.entryFunction = entryFunction
        self.timeoutMilliseconds = timeoutMilliseconds
        self.failurePolicy = failurePolicy
        self.runsInBackground = runsInBackground
    }

    /// A non-background hook is a synchronous foreground-only preflight for
    /// the current Blocks workflow. It is never an app-activity check and may
    /// not be used for termination.
    public var isForegroundOnlyPreflight: Bool {
        !runsInBackground
            && event.phase == .will
            && event != .appWillTerminate
    }

    /// The single declaration-level execution eligibility rule shared by
    /// package validation and the runtime, including historical manifests.
    public var isExecutionEligible: Bool {
        runsInBackground || isForegroundOnlyPreflight
    }

    private enum CodingKeys: String, CodingKey {
        case id, event
        case entryFunction = "entry_function"
        case timeoutMilliseconds = "timeout_ms"
        case failurePolicy = "failure_policy"
        case runsInBackground = "runs_in_background"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        event = try container.decode(BlocksPluginEventName.self, forKey: .event)
        entryFunction = try container.decodeIfPresent(
            String.self, forKey: .entryFunction
        ) ?? "handleHook"
        timeoutMilliseconds = try container.decodeIfPresent(
            Int.self, forKey: .timeoutMilliseconds
        ) ?? 500
        failurePolicy = try container.decodeIfPresent(
            BlocksPluginFailurePolicy.self, forKey: .failurePolicy
        ) ?? .failOpen
        runsInBackground = try container.decodeIfPresent(
            Bool.self, forKey: .runsInBackground
        ) ?? true
    }
}

public struct BlocksPluginActionDeclaration: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let entryFunction: String
    public let inputSchema: [String: JSONValue]
    public let outputSchema: [String: JSONValue]

    public init(
        id: String,
        displayName: String,
        entryFunction: String = "performAction",
        inputSchema: [String: JSONValue] = [:],
        outputSchema: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.entryFunction = entryFunction
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case entryFunction = "entry_function"
        case inputSchema = "input_schema"
        case outputSchema = "output_schema"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        entryFunction = try container.decodeIfPresent(
            String.self, forKey: .entryFunction
        ) ?? "performAction"
        inputSchema = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .inputSchema
        ) ?? [:]
        outputSchema = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .outputSchema
        ) ?? [:]
    }
}

/// Permission to invoke one action exported by another installed plugin.
/// The relationship is explicit so installation can show the producer and
/// action before any cross-plugin call is permitted.
public struct BlocksPluginImportedActionDeclaration: Codable, Equatable, Sendable {
    public let pluginID: String
    public let actionID: String

    public init(pluginID: String, actionID: String) {
        self.pluginID = pluginID
        self.actionID = actionID
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case actionID = "action_id"
    }
}

public enum BlocksPluginUISlot: String, Codable, CaseIterable, Hashable, Sendable {
    case pluginPage = "plugin.page"
    case clipboardRecordBadge = "clipboard.record_badge"
    case clipboardDetailSection = "clipboard.detail_section"
    case clipboardContextAction = "clipboard.context_action"
    case clipboardHeaderAction = "clipboard.header_action"
    case screenshotTool = "screenshot.tool"
    case screenshotInspectorSection = "screenshot.inspector_section"
    case screenshotStatusItem = "screenshot.status_item"
    case screenshotOutputAction = "screenshot.output_action"
    case translationPanelAction = "translation.panel_action"
    case translationResultDetail = "translation.result_detail"
    case providerDiagnosticCard = "provider.diagnostic_card"
    case settingsStatusCard = "settings.status_card"
}

public enum BlocksPluginUIComponentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case page, section, card, list, table, grid
    case title, text, secondaryText = "secondary_text", markdown, image, resourcePreview = "resource_preview"
    case status, progress, badge, keyValue = "key_value", empty, error
    case textField = "text_field", textEditor = "text_editor", secureField = "secure_field"
    case numberField = "number_field", toggle, choice, multiChoice = "multi_choice"
    case slider, color, fileAuthorization = "file_authorization", tagPicker = "tag_picker"
    case button, menu, toolbarAction = "toolbar_action", contextAction = "context_action", confirmation
}

public extension BlocksPluginUISlot {
    var allowedRootComponentKinds: Set<BlocksPluginUIComponentKind> {
        switch self {
        case .pluginPage:
            [.page, .section, .card, .list, .grid]
        case .clipboardRecordBadge, .screenshotStatusItem:
            [.badge, .status, .text, .secondaryText]
        case .clipboardDetailSection, .screenshotInspectorSection,
             .translationResultDetail:
            [.section, .card, .list, .table, .keyValue]
        case .clipboardContextAction, .clipboardHeaderAction,
             .screenshotTool, .screenshotOutputAction,
             .translationPanelAction:
            [.button, .menu, .toolbarAction, .contextAction]
        case .providerDiagnosticCard, .settingsStatusCard:
            [.card, .section, .status, .keyValue]
        }
    }
}

public extension BlocksPluginUIComponentKind {
    var stateProperties: Set<String> {
        var properties: Set<String> = ["enabled", "visible"]
        switch self {
        case .page, .section, .card:
            break
        case .list, .table, .grid:
            properties.insert("items")
        case .title, .text, .secondaryText, .markdown, .status, .badge,
             .keyValue, .empty, .error:
            properties.formUnion(["value", "text", "system_image"])
        case .image, .resourcePreview:
            properties.formUnion(["value", "resource_id", "system_image"])
        case .progress:
            properties.formUnion(["value", "total", "text"])
        case .textField, .textEditor, .secureField, .numberField, .toggle,
             .color, .fileAuthorization, .tagPicker:
            properties.insert("value")
        case .choice, .multiChoice:
            properties.formUnion(["value", "choices"])
        case .slider:
            properties.formUnion(["value", "minimum", "maximum"])
        case .button, .menu, .toolbarAction, .contextAction, .confirmation:
            properties.formUnion(["value", "text", "system_image"])
        }
        return properties
    }
}

public struct BlocksPluginUIComponentLocalization:
    Codable,
    Equatable,
    Sendable
{
    public let title: String?
    public let text: String?

    public init(title: String? = nil, text: String? = nil) {
        self.title = title
        self.text = text
    }
}

public struct BlocksPluginUIComponent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: BlocksPluginUIComponentKind
    public let title: String?
    public let properties: [String: JSONValue]
    public let actionID: String?
    public let children: [BlocksPluginUIComponent]
    public let localizations: [String: BlocksPluginUIComponentLocalization]

    public init(
        id: String,
        kind: BlocksPluginUIComponentKind,
        title: String? = nil,
        properties: [String: JSONValue] = [:],
        actionID: String? = nil,
        children: [BlocksPluginUIComponent] = [],
        localizations: [String: BlocksPluginUIComponentLocalization] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.properties = properties
        self.actionID = actionID
        self.children = children
        self.localizations = localizations
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, properties, children, localizations
        case actionID = "action_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(BlocksPluginUIComponentKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        properties = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .properties
        ) ?? [:]
        actionID = try container.decodeIfPresent(String.self, forKey: .actionID)
        children = try container.decodeIfPresent(
            [BlocksPluginUIComponent].self, forKey: .children
        ) ?? []
        localizations = try container.decodeIfPresent(
            [String: BlocksPluginUIComponentLocalization].self,
            forKey: .localizations
        ) ?? [:]
    }

    public func localized(
        locale: Locale = .current
    ) -> BlocksPluginUIComponentLocalization {
        let identifier = locale.identifier.replacingOccurrences(
            of: "_",
            with: "-"
        )
        if let exact = localizations[identifier] { return exact }
        if let language = locale.language.languageCode?.identifier,
           let match = localizations.first(where: {
               $0.key == language || $0.key.hasPrefix("\(language)-")
           })?.value {
            return match
        }
        return localizations["en"] ?? .init()
    }
}

public struct BlocksPluginUIContribution: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let slot: BlocksPluginUISlot
    public let root: BlocksPluginUIComponent

    public init(id: String, slot: BlocksPluginUISlot, root: BlocksPluginUIComponent) {
        self.id = id
        self.slot = slot
        self.root = root
    }
}

public enum BlocksPluginStorageKind: String, Codable, Sendable {
    case keyValue = "key_value"
    case document
    case queue
}

public struct BlocksPluginStorageDeclaration: Codable, Equatable, Sendable {
    public let kinds: [BlocksPluginStorageKind]
    public let userGrantedFiles: Bool

    public init(
        kinds: [BlocksPluginStorageKind] = [.keyValue],
        userGrantedFiles: Bool = false
    ) {
        self.kinds = kinds
        self.userGrantedFiles = userGrantedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case kinds
        case userGrantedFiles = "user_granted_files"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try container.decodeIfPresent(
            [BlocksPluginStorageKind].self, forKey: .kinds
        ) ?? [.keyValue]
        userGrantedFiles = try container.decodeIfPresent(
            Bool.self, forKey: .userGrantedFiles
        ) ?? false
    }
}

public enum BlocksPluginSharedStateAccess: String, Codable, Sendable {
    case read
    case write
    case readWrite = "read_write"
}

public struct BlocksPluginSharedNamespaceDeclaration: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// Optional ordinary-user label used only in installation disclosure.
    /// It never participates in shared-state authorization.
    public let displayName: String?
    /// Nil means the namespace is owned by this plugin. A value declares
    /// access to another installed plugin's exported namespace.
    public let ownerPluginID: String?
    public let schemaVersion: Int
    public let schema: [String: JSONValue]
    public let access: BlocksPluginSharedStateAccess

    public init(
        id: String,
        displayName: String? = nil,
        ownerPluginID: String? = nil,
        schemaVersion: Int = 1,
        schema: [String: JSONValue] = [:],
        access: BlocksPluginSharedStateAccess
    ) {
        self.id = id
        self.displayName = displayName
        self.ownerPluginID = ownerPluginID
        self.schemaVersion = schemaVersion
        self.schema = schema
        self.access = access
    }

    private enum CodingKeys: String, CodingKey {
        case id, schema, access
        case displayName = "display_name"
        case ownerPluginID = "owner_plugin_id"
        case schemaVersion = "schema_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(
            String.self, forKey: .displayName
        )
        ownerPluginID = try container.decodeIfPresent(
            String.self, forKey: .ownerPluginID
        )
        schemaVersion = try container.decodeIfPresent(
            Int.self, forKey: .schemaVersion
        ) ?? 1
        schema = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .schema
        ) ?? [:]
        access = try container.decode(
            BlocksPluginSharedStateAccess.self, forKey: .access
        )
    }
}

public enum BlocksPluginScheduleKind: String, Codable, Sendable {
    case interval
    case calendar
}

public struct BlocksPluginScheduleDeclaration: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: BlocksPluginScheduleKind
    public let entryFunction: String
    public let configuration: [String: JSONValue]

    public init(
        id: String,
        kind: BlocksPluginScheduleKind,
        entryFunction: String = "handleSchedule",
        configuration: [String: JSONValue]
    ) {
        self.id = id
        self.kind = kind
        self.entryFunction = entryFunction
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, configuration
        case entryFunction = "entry_function"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(BlocksPluginScheduleKind.self, forKey: .kind)
        entryFunction = try container.decodeIfPresent(
            String.self, forKey: .entryFunction
        ) ?? "handleSchedule"
        configuration = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .configuration
        ) ?? [:]
    }
}

public struct BlocksPluginPlatformConfiguration: Codable, Equatable, Sendable {
    public let hooks: [BlocksPluginHookSubscription]
    /// Host-owned actions the plugin may request. These are permissions, not
    /// JavaScript entry points implemented by the plugin.
    public let hostActions: [String]
    /// Actions exported by the plugin for UI, shortcuts, and other plugins.
    public let actions: [BlocksPluginActionDeclaration]
    /// Actions exported by other plugins that this plugin may invoke.
    public let importedActions: [BlocksPluginImportedActionDeclaration]
    public let ui: [BlocksPluginUIContribution]
    public let storage: BlocksPluginStorageDeclaration?
    public let sharedState: [BlocksPluginSharedNamespaceDeclaration]
    public let schedules: [BlocksPluginScheduleDeclaration]

    public init(
        hooks: [BlocksPluginHookSubscription] = [],
        hostActions: [String] = [],
        actions: [BlocksPluginActionDeclaration] = [],
        importedActions: [BlocksPluginImportedActionDeclaration] = [],
        ui: [BlocksPluginUIContribution] = [],
        storage: BlocksPluginStorageDeclaration? = nil,
        sharedState: [BlocksPluginSharedNamespaceDeclaration] = [],
        schedules: [BlocksPluginScheduleDeclaration] = []
    ) {
        self.hooks = hooks
        self.hostActions = hostActions
        self.actions = actions
        self.importedActions = importedActions
        self.ui = ui
        self.storage = storage
        self.sharedState = sharedState
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey {
        case hooks, actions, ui, storage, schedules
        case hostActions = "host_actions"
        case importedActions = "plugin_actions"
        case sharedState = "shared_state"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try container.decodeIfPresent(
            [BlocksPluginHookSubscription].self, forKey: .hooks
        ) ?? []
        hostActions = try container.decodeIfPresent(
            [String].self, forKey: .hostActions
        ) ?? []
        actions = try container.decodeIfPresent(
            [BlocksPluginActionDeclaration].self, forKey: .actions
        ) ?? []
        importedActions = try container.decodeIfPresent(
            [BlocksPluginImportedActionDeclaration].self,
            forKey: .importedActions
        ) ?? []
        ui = try container.decodeIfPresent(
            [BlocksPluginUIContribution].self, forKey: .ui
        ) ?? []
        storage = try container.decodeIfPresent(
            BlocksPluginStorageDeclaration.self, forKey: .storage
        )
        sharedState = try container.decodeIfPresent(
            [BlocksPluginSharedNamespaceDeclaration].self,
            forKey: .sharedState
        ) ?? []
        schedules = try container.decodeIfPresent(
            [BlocksPluginScheduleDeclaration].self, forKey: .schedules
        ) ?? []
    }
}

public enum BlocksPluginRuntimeInvocationKind: String, Codable, Sendable {
    case hook
    case action
    case uiAction = "ui_action"
    case schedule
}

public struct BlocksPluginRuntimeInvocation: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let pluginID: String
    public let kind: BlocksPluginRuntimeInvocationKind
    public let entryFunction: String
    public let event: BlocksPluginEventEnvelope?
    public let input: [String: JSONValue]
    public let configuration: [String: JSONValue]

    public init(
        requestID: UUID = UUID(),
        pluginID: String,
        kind: BlocksPluginRuntimeInvocationKind,
        entryFunction: String,
        event: BlocksPluginEventEnvelope? = nil,
        input: [String: JSONValue] = [:],
        configuration: [String: JSONValue] = [:]
    ) {
        self.requestID = requestID
        self.pluginID = pluginID
        self.kind = kind
        self.entryFunction = entryFunction
        self.event = event
        self.input = input
        self.configuration = configuration
    }
}

public struct BlocksPluginRunnerRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let manifest: BlocksNativePluginManifest
    public let entrySource: String
    public let invocation: BlocksPluginRuntimeInvocation
    public let executionTimeLimitSeconds: Double

    public init(
        protocolVersion: Int = BlocksNativePluginXPC.protocolVersion,
        manifest: BlocksNativePluginManifest,
        entrySource: String,
        invocation: BlocksPluginRuntimeInvocation,
        executionTimeLimitSeconds: Double
    ) {
        self.protocolVersion = protocolVersion
        self.manifest = manifest
        self.entrySource = entrySource
        self.invocation = invocation
        self.executionTimeLimitSeconds = executionTimeLimitSeconds
    }
}

public struct BlocksPluginRuntimeResult: Codable, Equatable, Sendable {
    public let hook: BlocksPluginHookResult?
    public let output: [String: JSONValue]
    public let actions: [BlocksPluginActionInvocation]
    public let uiStatePatches: [BlocksPluginUIStatePatch]
    public let diagnostics: [BlocksPluginDiagnostic]

    public init(
        hook: BlocksPluginHookResult? = nil,
        output: [String: JSONValue] = [:],
        actions: [BlocksPluginActionInvocation] = [],
        uiStatePatches: [BlocksPluginUIStatePatch] = [],
        diagnostics: [BlocksPluginDiagnostic] = []
    ) {
        self.hook = hook
        self.output = output
        self.actions = actions
        self.uiStatePatches = uiStatePatches
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case hook, output, actions, diagnostics
        case uiStatePatches = "ui_state_patches"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hook = try container.decodeIfPresent(
            BlocksPluginHookResult.self, forKey: .hook
        )
        output = try container.decodeIfPresent(
            [String: JSONValue].self, forKey: .output
        ) ?? [:]
        actions = try container.decodeIfPresent(
            [BlocksPluginActionInvocation].self, forKey: .actions
        ) ?? []
        uiStatePatches = try container.decodeIfPresent(
            [BlocksPluginUIStatePatch].self, forKey: .uiStatePatches
        ) ?? []
        diagnostics = try container.decodeIfPresent(
            [BlocksPluginDiagnostic].self, forKey: .diagnostics
        ) ?? []
    }
}

public struct BlocksPluginRunnerResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let status: BlocksNativePluginRunnerStatus
    public let result: BlocksPluginRuntimeResult?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        requestID: UUID,
        status: BlocksNativePluginRunnerStatus,
        result: BlocksPluginRuntimeResult? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct BlocksPluginHostOperationRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let pluginID: String
    public let operation: String
    public let input: [String: JSONValue]

    public init(
        requestID: UUID = UUID(),
        pluginID: String,
        operation: String,
        input: [String: JSONValue] = [:]
    ) {
        self.requestID = requestID
        self.pluginID = pluginID
        self.operation = operation
        self.input = input
    }
}

public struct BlocksPluginHostOperationResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let ok: Bool
    public let value: JSONValue?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        requestID: UUID,
        ok: Bool,
        value: JSONValue? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.value = value
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
