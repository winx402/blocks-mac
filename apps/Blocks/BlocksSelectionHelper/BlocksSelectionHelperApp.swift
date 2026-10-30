import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import Network
import OSLog
import Security
import ServiceManagement
import SwiftUI

private enum SelectionHelperSharedKeychainAccessGroup {
    static func current() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              ) as? [String] else {
            return nil
        }
        let matchingGroups = groups.filter {
            $0.hasSuffix(
                BlocksSelectionHelperProtocol
                    .sharedKeychainAccessGroupSuffix
            )
        }
        guard matchingGroups.count == 1 else { return nil }
        return matchingGroups[0]
    }
}

private final class SelectionHelperCaptureService {
    private let cancellations =
        SelectionAgentCancellationRegistry()
    private let workerQueue = DispatchQueue(
        label: "app.blocks.selection-helper.capture",
        qos: .userInitiated
    )

    func capture(
        _ request: SelectionAgentCaptureRequest,
        completion: @escaping (SelectionAgentCaptureResponse) -> Void
    ) {
        guard SelectionAgentPayloadValidator.isValid(request),
              cancellations.begin(request.requestID) else {
            completion(.failure(
                requestID: "invalid",
                code: .invalidRequest
            ))
            return
        }
        workerQueue.async { [cancellations] in
            defer { cancellations.finish(request.requestID) }

            let response = SelectionAgentCaptureWorker(
                cancellations: cancellations
            ).capture(request)
            if SelectionAgentPayloadValidator.isValid(response) {
                completion(response)
            } else {
                completion(.failure(
                    requestID: request.requestID,
                    code: .internalFailure
                ))
            }
        }
    }

    func permissionStatus() -> Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func cancel(_ requestID: String) -> Bool {
        guard !requestID.isEmpty else { return false }
        return cancellations.cancel(requestID)
    }
}

/// Read-only AX metadata used for the optional paste-target enhancement. This
/// intentionally mirrors the conservative acceptance rules used by the main
/// app without importing its Clipboard types or reading user text.
struct SelectionHelperPasteTargetSemantics: Equatable {
    let role: String
    let enabled: Bool?
    let explicitlyEditable: Bool?
    let valueSettable: Bool?
    let selectedTextSettable: Bool?
    let focusedSettable: Bool?
    let hasTextContentModel: Bool
    let hasTextSelectionModel: Bool
    let hasWebAreaAncestor: Bool
    let hasStableWebNodeIdentity: Bool

    var editability: SelectionHelperPasteTargetEditability {
        guard let enabled else { return .unknown }
        guard enabled else { return .nonEditable }
        guard let explicitlyEditable,
              let valueSettable,
              let selectedTextSettable,
              let focusedSettable else {
            return .unknown
        }
        let supportsTextMutation = valueSettable || selectedTextSettable
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView":
            return explicitlyEditable || supportsTextMutation
                ? .editable : .nonEditable
        case "AXWebArea":
            return explicitlyEditable || (valueSettable && selectedTextSettable)
                ? .editable : .nonEditable
        case "AXGroup":
            return focusedSettable
                && hasTextContentModel
                && hasTextSelectionModel
                && hasWebAreaAncestor
                && hasStableWebNodeIdentity ? .editable : .unknown
        default:
            return .unknown
        }
    }
}

struct SelectionHelperPasteTargetInspectionDeadline: Sendable {
    private let deadlineUptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let normalized = timeout.isFinite && timeout > 0
            ? min(timeout, 0.08) : 0
        deadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ UInt64((normalized * 1_000_000_000).rounded(.up))
    }

    var hasRemainingTime: Bool {
        DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    var remainingMessagingTimeout: Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineUptimeNanoseconds else { return 0 }
        return min(
            0.08,
            Float(deadlineUptimeNanoseconds - now) / 1_000_000_000
        )
    }
}

private struct SelectionHelperPasteTargetInspectionWorker {
    private static let ancestorLimit = 8

    func inspect(
        _ request: SelectionHelperPasteTargetRequest,
        deadline: SelectionHelperPasteTargetInspectionDeadline =
            SelectionHelperPasteTargetInspectionDeadline(timeout: 0.08)
    ) -> SelectionHelperPasteTargetInspection {
        let unknown = response(for: request, editability: .unknown)
        guard request.isValid,
              deadline.hasRemainingTime,
              let target = NSRunningApplication(
                processIdentifier: request.targetPID
              ),
              !target.isTerminated,
              target.bundleIdentifier == request.targetBundleIdentifier,
              isCurrentFrontmostTarget(request),
              AXIsProcessTrusted(),
              deadline.hasRemainingTime else {
            return unknown
        }

        let application = AXUIElementCreateApplication(request.targetPID)
        var focusedValue: CFTypeRef?
        guard copyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            into: &focusedValue,
            deadline: deadline
        ) == .success,
           let focusedElement = focusedValue,
           CFGetTypeID(focusedElement) == AXUIElementGetTypeID(),
           isCurrentFrontmostTarget(request),
           deadline.hasRemainingTime else {
            return unknown
        }

        let element = focusedElement as! AXUIElement
        let editability = semantics(for: element, deadline: deadline)
            .editability
        guard isCurrentFrontmostTarget(request), deadline.hasRemainingTime else {
            return unknown
        }
        return response(for: request, editability: editability)
    }

    private func response(
        for request: SelectionHelperPasteTargetRequest,
        editability: SelectionHelperPasteTargetEditability
    ) -> SelectionHelperPasteTargetInspection {
        SelectionHelperPasteTargetInspection(
            requestID: request.requestID,
            targetPID: request.targetPID,
            targetBundleIdentifier: request.targetBundleIdentifier,
            editability: editability
        )
    }

    private func isCurrentFrontmostTarget(
        _ request: SelectionHelperPasteTargetRequest
    ) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return frontmost.processIdentifier == request.targetPID
            && frontmost.bundleIdentifier == request.targetBundleIdentifier
    }

    private func semantics(
        for element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> SelectionHelperPasteTargetSemantics {
        guard deadline.hasRemainingTime else {
            return unknownSemantics
        }
        let attributeNames = Set(attributeNames(for: element, deadline: deadline))
        guard deadline.hasRemainingTime else { return unknownSemantics }
        let role = stringAttribute(
            kAXRoleAttribute as CFString,
            from: element,
            deadline: deadline
        ) ?? ""
        guard deadline.hasRemainingTime else { return unknownSemantics }
        let identifier = stringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element,
            deadline: deadline
        )
        guard deadline.hasRemainingTime else { return unknownSemantics }
        let domIdentifier = stringAttribute(
            "AXDOMIdentifier" as CFString,
            from: element,
            deadline: deadline
        )
        guard deadline.hasRemainingTime else { return unknownSemantics }
        let chromeNodeID = stringAttribute(
            "ChromeAXNodeId" as CFString,
            from: element,
            deadline: deadline
        )
        guard deadline.hasRemainingTime else { return unknownSemantics }
        return SelectionHelperPasteTargetSemantics(
            role: role,
            enabled: booleanAttribute(
                kAXEnabledAttribute as CFString,
                from: element,
                deadline: deadline
            ),
            explicitlyEditable: booleanAttribute(
                kAXIsEditableAttribute as CFString,
                from: element,
                deadline: deadline
            ),
            valueSettable: attributeIsSettable(
                kAXValueAttribute as CFString,
                on: element,
                deadline: deadline
            ),
            selectedTextSettable: attributeIsSettable(
                kAXSelectedTextAttribute as CFString,
                on: element,
                deadline: deadline
            ),
            focusedSettable: attributeIsSettable(
                kAXFocusedAttribute as CFString,
                on: element,
                deadline: deadline
            ),
            hasTextContentModel: attributeNames.contains("AXNumberOfCharacters")
                && attributeNames.contains(kAXValueAttribute as String),
            hasTextSelectionModel: attributeNames.contains(
                kAXSelectedTextAttribute as String
            ) && (
                attributeNames.contains(kAXSelectedTextRangeAttribute as String)
                    || attributeNames.contains("AXSelectedTextMarkerRange")
            ),
            hasWebAreaAncestor: hasAncestorRole(
                "AXWebArea",
                from: element,
                deadline: deadline
            ),
            hasStableWebNodeIdentity: [identifier, domIdentifier, chromeNodeID]
                .contains { value in value?.isEmpty == false }
        )
    }

    private var unknownSemantics: SelectionHelperPasteTargetSemantics {
        SelectionHelperPasteTargetSemantics(
            role: "",
            enabled: nil,
            explicitlyEditable: nil,
            valueSettable: nil,
            selectedTextSettable: nil,
            focusedSettable: nil,
            hasTextContentModel: false,
            hasTextSelectionModel: false,
            hasWebAreaAncestor: false,
            hasStableWebNodeIdentity: false
        )
    }

    private func attributeNames(
        for element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> [String] {
        var values: CFArray?
        guard configure(element, deadline: deadline),
              AXUIElementCopyAttributeNames(element, &values) == .success,
              deadline.hasRemainingTime else {
            return []
        }
        return values as? [String] ?? []
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> String? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            element,
            attribute,
            into: &value,
            deadline: deadline
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func booleanAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> Bool? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            element,
            attribute,
            into: &value,
            deadline: deadline
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func attributeIsSettable(
        _ attribute: CFString,
        on element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> Bool? {
        var settable: DarwinBoolean = false
        guard configure(element, deadline: deadline),
              AXUIElementIsAttributeSettable(element, attribute, &settable)
                == .success,
              deadline.hasRemainingTime else {
            return nil
        }
        return settable.boolValue
    }

    private func hasAncestorRole(
        _ role: String,
        from element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> Bool {
        var candidate: AXUIElement? = element
        for _ in 0...Self.ancestorLimit {
            guard deadline.hasRemainingTime else { return false }
            guard let current = candidate else { return false }
            if stringAttribute(
                kAXRoleAttribute as CFString,
                from: current,
                deadline: deadline
            ) == role {
                return true
            }
            var parent: CFTypeRef?
            guard copyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                into: &parent,
                deadline: deadline
            ) == .success,
               let parent,
               CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return false
            }
            candidate = parent as! AXUIElement
        }
        return false
    }

    private func configure(
        _ element: AXUIElement,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> Bool {
        guard deadline.hasRemainingTime else { return false }
        AXUIElementSetMessagingTimeout(
            element,
            deadline.remainingMessagingTimeout
        )
        return deadline.hasRemainingTime
    }

    private func copyAttributeValue(
        _ element: AXUIElement,
        _ attribute: CFString,
        into value: UnsafeMutablePointer<CFTypeRef?>,
        deadline: SelectionHelperPasteTargetInspectionDeadline
    ) -> AXError {
        guard configure(element, deadline: deadline) else {
            return .failure
        }
        let result = AXUIElementCopyAttributeValue(element, attribute, value)
        return deadline.hasRemainingTime ? result : .failure
    }
}

final class SelectionHelperPasteTargetInspectionService {
    private let workerQueue = DispatchQueue(
        label: "app.blocks.selection-helper.paste-target-inspection",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let inspector: (
        SelectionHelperPasteTargetRequest,
        SelectionHelperPasteTargetInspectionDeadline
    ) -> SelectionHelperPasteTargetInspection
    private var isInspecting = false

    init(
        timeout: TimeInterval = 0.08,
        inspector: @escaping (
            SelectionHelperPasteTargetRequest,
            SelectionHelperPasteTargetInspectionDeadline
        ) -> SelectionHelperPasteTargetInspection = { request, deadline in
            SelectionHelperPasteTargetInspectionWorker().inspect(
                request,
                deadline: deadline
            )
        }
    ) {
        self.timeout = timeout
        self.inspector = inspector
    }

    func inspect(
        _ request: SelectionHelperPasteTargetRequest,
        completion: @escaping (SelectionHelperPasteTargetInspection) -> Void
    ) {
        guard beginInspection() else {
            completion(unknownInspection(for: request))
            return
        }
        let deadline = SelectionHelperPasteTargetInspectionDeadline(
            timeout: timeout
        )
        workerQueue.async {
            defer { self.endInspection() }
            guard deadline.hasRemainingTime else {
                completion(self.unknownInspection(for: request))
                return
            }
            completion(self.inspector(request, deadline))
        }
    }

    private func beginInspection() -> Bool {
        lock.withLock {
            guard !isInspecting else { return false }
            isInspecting = true
            return true
        }
    }

    private func endInspection() {
        lock.withLock { isInspecting = false }
    }

    private func unknownInspection(
        for request: SelectionHelperPasteTargetRequest
    ) -> SelectionHelperPasteTargetInspection {
        SelectionHelperPasteTargetInspection(
            requestID: request.requestID,
            targetPID: request.targetPID,
            targetBundleIdentifier: request.targetBundleIdentifier,
            editability: .unknown
        )
    }
}

/// Length and String are independently optional AX parameterized attributes.
/// Only an explicit unsupported/no-value response permits a String-only read;
/// malformed lengths and unrelated AX failures remain a refusal.
enum SelectionHelperMarkerLength: Equatable {
    case known(Int)
    case unavailable
    case invalid

    static func decode(status: AXError, value: CFTypeRef?) -> Self {
        switch status {
        case .parameterizedAttributeUnsupported, .attributeUnsupported,
             .notImplemented, .noValue:
            return .unavailable
        case .success:
            guard let value else { return .unavailable }
            guard CFGetTypeID(value) == CFNumberGetTypeID() else {
                return .invalid
            }
            var length = 0
            guard CFNumberGetValue(value as! CFNumber, .cfIndexType, &length),
                  length >= 0 else { return .invalid }
            return .known(length)
        default:
            return .invalid
        }
    }
}

/// The production capture path uses this resolver for one candidate only. Its
/// closures read the current selection, never a document value or cached text.
enum SelectionHelperSelectionTextResolver {
    enum Source: String {
        case direct, range, marker
    }

    enum State: String {
        case notAttempted, unavailable, empty, selected, tooLarge, unstable
    }

    struct Selection<Marker: Equatable>: Equatable {
        let text: String
        let source: Source
        let range: NSRange?
        let marker: Marker?
    }

    enum Outcome<Marker: Equatable>: Equatable {
        case selected(Selection<Marker>)
        case empty
        case unavailable
        case failure(SelectionAgentFailureCode)
    }

    static func resolve<Marker: Equatable>(
        isPasswordField: Bool,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int =
            BlocksSelectionCaptureProtocol.maximumSelectionUTF8Bytes,
        interruption: () -> SelectionAgentFailureCode?,
        directText: () -> String?,
        selectedRange: () -> NSRange?,
        rangeText: (NSRange) -> String?,
        selectedMarker: () -> Marker?,
        markerLength: (Marker) -> SelectionHelperMarkerLength,
        markerText: (Marker) -> String?,
        record: (Source, State) -> Void = { _, _ in }
    ) -> Outcome<Marker> {
        if let failure = interruption() { return .failure(failure) }
        guard !isPasswordField else { return .failure(.passwordField) }
        var sawEmpty = false

        func classify(_ text: String?) -> State {
            guard let text else { return .unavailable }
            guard text.count <= maximumCharacters,
                  text.utf8.count <= maximumUTF8Bytes else {
                return .tooLarge
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? .empty : .selected
        }

        let direct = directText()
        if let failure = interruption() { return .failure(failure) }
        let directState = classify(direct)
        if let failure = interruption() { return .failure(failure) }
        record(.direct, directState)
        switch directState {
        case .selected:
            return .selected(Selection(
                text: direct!, source: .direct, range: nil, marker: nil
            ))
        case .tooLarge:
            return .failure(.selectionTooLarge)
        case .empty:
            sawEmpty = true
        default:
            break
        }

        if let failure = interruption() { return .failure(failure) }
        let range = selectedRange()
        if let failure = interruption() { return .failure(failure) }
        if let range, range.location >= 0, range.length > 0,
           range.location <= Int.max - range.length {
            // AX selected ranges, like marker lengths, use UTF-16 units; a
            // range beyond the byte ceiling cannot yield an accepted string.
            guard range.length <= maximumUTF8Bytes else {
                record(.range, .tooLarge)
                return .failure(.selectionTooLarge)
            }
            let text = rangeText(range)
            if let failure = interruption() { return .failure(failure) }
            let state = classify(text)
            if let failure = interruption() { return .failure(failure) }
            record(.range, state)
            // An oversized fallback is a terminal refusal, not permission to
            // select some other, shorter text from the candidate.
            if state == .tooLarge { return .failure(.selectionTooLarge) }
            if let failure = interruption() { return .failure(failure) }
            let currentRange = selectedRange()
            if let failure = interruption() { return .failure(failure) }
            guard currentRange == range else {
                record(.range, .unstable)
                return .unavailable
            }
            if state == .selected {
                return .selected(Selection(
                    text: text!, source: .range, range: range, marker: nil
                ))
            }
            sawEmpty = sawEmpty || state == .empty
        } else {
            let state: State = range?.length == 0 ? .empty : .unavailable
            record(.range, state)
            sawEmpty = sawEmpty || state == .empty
        }

        if let failure = interruption() { return .failure(failure) }
        let marker = selectedMarker()
        if let failure = interruption() { return .failure(failure) }
        if let marker {
            let length = markerLength(marker)
            if let failure = interruption() { return .failure(failure) }
            switch length {
            case let .known(length):
                guard length > 0 else {
                    let state: State = length == 0 ? .empty : .unavailable
                    record(.marker, state)
                    return sawEmpty || state == .empty ? .empty : .unavailable
                }
                guard length <= maximumUTF8Bytes else {
                    record(.marker, .tooLarge)
                    return .failure(.selectionTooLarge)
                }
            case .invalid:
                record(.marker, .unavailable)
                return .unavailable
            case .unavailable:
                // String-only providers retain the same trust boundary as a
                // direct AXSelectedText read: allocation cannot be bounded by
                // a preflight Length, so both text limits are enforced after
                // the native call. The process-wide AX timeout still applies.
                break
            }
            if let failure = interruption() { return .failure(failure) }
            let text = markerText(marker)
            if let failure = interruption() { return .failure(failure) }
            let state = classify(text)
            if let failure = interruption() { return .failure(failure) }
            record(.marker, state)
            if state == .tooLarge { return .failure(.selectionTooLarge) }
            if let failure = interruption() { return .failure(failure) }
            let currentMarker = selectedMarker()
            if let failure = interruption() { return .failure(failure) }
            guard currentMarker == marker else {
                record(.marker, .unstable)
                return .unavailable
            }
            if state == .selected {
                return .selected(Selection(
                    text: text!, source: .marker, range: nil, marker: marker
                ))
            }
            sawEmpty = sawEmpty || state == .empty
        } else {
            record(.marker, .unavailable)
        }
        return sawEmpty ? .empty : .unavailable
    }
}

/// Only fixed states and allowlisted roles enter capture diagnostics. The cap
/// applies to the entire request, not independently to each candidate strategy.
struct SelectionHelperCaptureDiagnostics {
    static let maximumCandidateRecords = 8

    enum HitTest: String {
        case noPoint, unavailable, interrupted, pidMismatch, matched
    }

    enum Role: String {
        case webArea = "AXWebArea"
        case document = "AXDocument"
        case pdfView = "AXPDFView"
        case textArea = "AXTextArea"
        case textField = "AXTextField"
        case staticText = "AXStaticText"
        case group = "AXGroup"
        case scrollArea = "AXScrollArea"
        case other

        init(_ rawRole: String?) {
            self = rawRole.flatMap(Self.init(rawValue:)) ?? .other
        }
    }

    struct Trace {
        var role = Role.other
        var direct = SelectionHelperSelectionTextResolver.State.notAttempted
        var range = SelectionHelperSelectionTextResolver.State.notAttempted
        var marker = SelectionHelperSelectionTextResolver.State.notAttempted

        mutating func record(
            _ source: SelectionHelperSelectionTextResolver.Source,
            _ state: SelectionHelperSelectionTextResolver.State
        ) {
            switch source {
            case .direct: direct = state
            case .range: range = state
            case .marker: marker = state
            }
        }
    }

    var hitTest = HitTest.noPoint
    private(set) var inspectedCandidates = 0
    private(set) var records: [String] = []
    var omittedCandidates: Int { inspectedCandidates - records.count }

    mutating func record(strategy: SelectionAgentCaptureStrategy, trace: Trace) {
        inspectedCandidates += 1
        guard records.count < Self.maximumCandidateRecords else { return }
        records.append(
            "\(strategy.rawValue):\(trace.role.rawValue):\(trace.direct.rawValue)/\(trace.range.rawValue)/\(trace.marker.rawValue)"
        )
    }
}

/// The native hit-test closure receives the target application, never the
/// system-wide element, and the returned element still has to match its PID.
enum SelectionHelperTargetHitTest {
    static func read<Element>(
        targetApplication: Element,
        targetPID: pid_t,
        isAllowed: () -> Bool,
        hitTest: (Element) -> Element?,
        processIdentifier: (Element) -> pid_t?
    ) -> (element: Element?, status: SelectionHelperCaptureDiagnostics.HitTest) {
        guard isAllowed() else { return (nil, .interrupted) }
        let element = hitTest(targetApplication)
        guard isAllowed() else { return (nil, .interrupted) }
        guard let element else { return (nil, .unavailable) }
        let actualPID = processIdentifier(element)
        guard isAllowed() else { return (nil, .interrupted) }
        guard let actualPID else { return (nil, .unavailable) }
        guard actualPID == targetPID else { return (nil, .pidMismatch) }
        return (element, .matched)
    }
}

/// An application element's timeout does not cover returned descendants. The
/// system-wide handle sets the current process's default AX messaging timeout;
/// it is used only for this bounded scope, never for candidate hit-testing.
enum SelectionHelperAXMessagingTimeoutPolicy {
    static let maximumTimeout: Float = 0.1

    static func timeout(deadline: Date, now: Date = Date()) -> Float {
        Float(min(max(0.05, deadline.timeIntervalSince(now)),
                  Double(maximumTimeout)))
    }

    static func withProcessWideTimeout<Handle, Output>(
        systemWideElement: Handle,
        deadline: Date,
        now: Date = Date(),
        setTimeout: (Handle, Float) -> Void,
        operation: () throws -> Output
    ) rethrows -> Output {
        setTimeout(systemWideElement, timeout(deadline: deadline, now: now))
        defer { setTimeout(systemWideElement, 0) }
        return try operation()
    }
}

struct SelectionHelperTextMarkerSnapshot: Equatable {
    let value: AXTextMarkerRange
    let start: Data
    let end: Data

    init?(_ value: CFTypeRef) {
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        let range = value as! AXTextMarkerRange
        let startMarker = AXTextMarkerRangeCopyStartMarker(range)
        let endMarker = AXTextMarkerRangeCopyEndMarker(range)
        let startLength = AXTextMarkerGetLength(startMarker)
        let endLength = AXTextMarkerGetLength(endMarker)
        // These opaque identities are local to this candidate/read only. They
        // are never logged, serialized, or retained across capture requests.
        guard (1...4_096).contains(startLength),
              (1...4_096).contains(endLength) else { return nil }
        self.value = range
        start = Data(bytes: AXTextMarkerGetBytePtr(startMarker), count: startLength)
        end = Data(bytes: AXTextMarkerGetBytePtr(endMarker), count: endLength)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }
}

private struct SelectionAgentCaptureWorker {
    private static let maximumAncestorDepth = 8
    private static let maximumDocumentDepth = 8
    private static let maximumDocumentNodes = 192
    private static let maximumChildrenPerNode = 48
    private static let candidateRoles: Set<String> = [
        "AXWebArea",
        "AXDocument",
        "AXPDFView",
        "AXTextArea",
        "AXTextField",
        "AXStaticText",
        "AXGroup",
        "AXScrollArea",
    ]
    private static let logger = Logger(
        subsystem: "app.blocks.selection-helper",
        category: "SelectionCapture"
    )

    private struct Candidate {
        let element: AXUIElement
        let strategy: SelectionAgentCaptureStrategy
        let depth: Int
    }

    private enum CandidateReadOutcome {
        case selected(SelectionAgentSelection)
        case empty
        case unavailable
        case passwordField
        case interrupted(SelectionAgentCaptureResponse)
    }

    let cancellations: SelectionAgentCancellationRegistry

    func capture(
        _ request: SelectionAgentCaptureRequest
    ) -> SelectionAgentCaptureResponse {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard SelectionAgentPayloadValidator.isValid(request) else {
            return .failure(
                requestID: request.requestID,
                code: .invalidRequest
            )
        }
        guard !isExpired(request) else {
            return .failure(
                requestID: request.requestID,
                code: .timedOut
            )
        }
        guard !cancellations.isCancelled(request.requestID) else {
            return .failure(
                requestID: request.requestID,
                code: .cancelled
            )
        }
        guard let target = NSRunningApplication(
            processIdentifier: request.targetProcessIdentifier
        ), !target.isTerminated else {
            return .failure(
                requestID: request.requestID,
                code: .targetUnavailable
            )
        }
        if let expectedBundleIdentifier =
            request.targetBundleIdentifier,
           target.bundleIdentifier != expectedBundleIdentifier {
            return .failure(
                requestID: request.requestID,
                code: .targetIdentityChanged
            )
        }
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        guard AXIsProcessTrusted() else {
            return .failure(
                requestID: request.requestID,
                code: .accessibilityPermissionDenied
            )
        }
        if let failure = interruptionFailure(for: request) {
            return failure
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        return SelectionHelperAXMessagingTimeoutPolicy.withProcessWideTimeout(
            systemWideElement: systemWideElement,
            deadline: request.deadline,
            setTimeout: { element, timeout in
                _ = AXUIElementSetMessagingTimeout(element, timeout)
            },
            operation: { captureSelection(request, startedAt: startedAt) }
        )
    }

    private func captureSelection(
        _ request: SelectionAgentCaptureRequest,
        startedAt: CFAbsoluteTime
    ) -> SelectionAgentCaptureResponse {
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        let applicationElement = AXUIElementCreateApplication(
            request.targetProcessIdentifier
        )
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        AXUIElementSetMessagingTimeout(
            applicationElement,
            messagingTimeout(for: request)
        )
        let focusedElement = axElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: applicationElement,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        let response = readSelection(
            applicationElement: applicationElement,
            focusedElement: focusedElement,
            request: request
        )
        let duration = Int(
            (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        )
        if let selection = response.selection {
            Self.logger.info(
                "capture succeeded request=\(request.requestID, privacy: .public) strategy=\(selection.captureStrategy.rawValue, privacy: .public) depth=\(selection.candidateDepth, privacy: .public) chars=\(selection.text.count, privacy: .public) duration_ms=\(duration, privacy: .public)"
            )
        } else {
            Self.logger.info(
                "capture unavailable request=\(request.requestID, privacy: .public) code=\(response.failureCode?.rawValue ?? "unknown", privacy: .public) duration_ms=\(duration, privacy: .public)"
            )
        }
        return response
    }

    private func readSelection(
        applicationElement: AXUIElement,
        focusedElement: AXUIElement?,
        request: SelectionAgentCaptureRequest
    ) -> SelectionAgentCaptureResponse {
        var candidates: [Candidate] = []
        var seen: Set<CFHashCode> = []
        var sawEmptySelection = false
        var diagnostics = SelectionHelperCaptureDiagnostics()
        defer {
            Self.logger.info(
                "capture paths request=\(request.requestID, privacy: .public) focused=\(focusedElement != nil, privacy: .public) candidates=\(candidates.count, privacy: .public) inspected=\(diagnostics.inspectedCandidates, privacy: .public) omitted=\(diagnostics.omittedCandidates, privacy: .public) hit=\(diagnostics.hitTest.rawValue, privacy: .public) states=\(diagnostics.records.joined(separator: ";"), privacy: .public)"
            )
        }

        if let focusedElement {
            appendAncestorCandidates(
                from: focusedElement,
                strategy: .focusedElement,
                into: &candidates,
                seen: &seen,
                request: request
            )
            if let failure = interruptionFailure(for: request) {
                return failure
            }
        }
        if let point = request.mouseScreenPoint {
            let hit = element(
                at: point,
                applicationElement: applicationElement,
                targetPID: request.targetProcessIdentifier,
                request: request
            )
            diagnostics.hitTest = hit.status
            if let failure = interruptionFailure(for: request) {
                return failure
            }
            if let hitElement = hit.element {
                appendAncestorCandidates(
                    from: hitElement,
                    strategy: .mouseHitTest,
                    into: &candidates,
                    seen: &seen,
                    request: request
                )
                if let failure = interruptionFailure(for: request) {
                    return failure
                }
            }
        }
        let focusedWindow = axElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: applicationElement,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return failure
        }
        if let focusedWindow {
            appendDocumentCandidates(
                from: focusedWindow,
                into: &candidates,
                seen: &seen,
                request: request
            )
            if let failure = interruptionFailure(for: request) {
                return failure
            }
        }

        guard !candidates.isEmpty else {
            return .failure(
                requestID: request.requestID,
                code: focusedElement == nil
                    ? .focusedElementUnavailable
                    : .selectionUnavailable
            )
        }

        for candidate in candidates {
            if let failure = interruptionFailure(for: request) {
                return failure
            }
            var trace = SelectionHelperCaptureDiagnostics.Trace()
            let outcome = readSelection(
                in: candidate,
                request: request,
                trace: &trace
            )
            diagnostics.record(strategy: candidate.strategy, trace: trace)
            switch outcome {
            case let .selected(selection):
                return .success(
                    requestID: request.requestID,
                    selection: selection
                )
            case .empty:
                sawEmptySelection = true
            case .unavailable:
                break
            case .passwordField:
                return .failure(
                    requestID: request.requestID,
                    code: .passwordField
                )
            case let .interrupted(response):
                return response
            }
        }

        return .failure(
            requestID: request.requestID,
            code: sawEmptySelection
                ? .emptySelection
                : .selectionUnavailable
        )
    }

    private func readSelection(
        in candidate: Candidate,
        request: SelectionAgentCaptureRequest,
        trace: inout SelectionHelperCaptureDiagnostics.Trace
    ) -> CandidateReadOutcome {
        let element = candidate.element
        let role = stringAttribute(
            kAXRoleAttribute as CFString,
            from: element,
            request: request
        )
        trace.role = .init(role)
        if let failure = interruptionFailure(for: request) {
            return .interrupted(failure)
        }
        let subrole = stringAttribute(
            kAXSubroleAttribute as CFString,
            from: element,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return .interrupted(failure)
        }
        let isPasswordField = subrole == kAXSecureTextFieldSubrole as String
        if isPasswordField, candidate.strategy == .focusedWindowDocument {
            return .unavailable
        }

        let resolved = SelectionHelperSelectionTextResolver.resolve(
            isPasswordField: isPasswordField,
            maximumCharacters: request.maximumCharacters,
            interruption: { interruptionFailure(for: request)?.failureCode },
            directText: { directSelectedText(from: element, request: request) },
            selectedRange: { selectedTextRange(from: element, request: request) },
            rangeText: { string(for: $0, in: element, request: request) },
            selectedMarker: {
                selectedTextMarkerRange(from: element, request: request)
                    .flatMap(SelectionHelperTextMarkerSnapshot.init)
            },
            markerLength: {
                length(forTextMarkerRange: $0.value, in: element, request: request)
            },
            markerText: {
                string(forTextMarkerRange: $0.value, in: element, request: request)
            },
            record: { trace.record($0, $1) }
        )
        let selection: SelectionHelperSelectionTextResolver.Selection<
            SelectionHelperTextMarkerSnapshot
        >
        switch resolved {
        case let .selected(value): selection = value
        case .empty: return .empty
        case .unavailable: return .unavailable
        case .failure(.passwordField): return .passwordField
        case let .failure(code):
            return .interrupted(.failure(requestID: request.requestID, code: code))
        }
        let selectedText = selection.text
        var range = selection.range
        var markerRange: CFTypeRef? = selection.marker?.value
        // Fallback metadata belongs to the exact range/marker checked by the
        // resolver. Only the direct path needs a separate best-effort anchor.
        if selection.source == .direct {
            range = selectedTextRange(from: element, request: request)
            if let failure = interruptionFailure(for: request) {
                return .interrupted(failure)
            }
            markerRange = selectedTextMarkerRange(from: element, request: request)
            if let failure = interruptionFailure(for: request) {
                return .interrupted(failure)
            }
        }

        var selectionBounds: CGRect?
        if let range {
            selectionBounds = bounds(
                for: range,
                in: element,
                request: request
            )
            if let failure = interruptionFailure(for: request) {
                return .interrupted(failure)
            }
        }
        if selectionBounds == nil, let markerRange {
            selectionBounds = bounds(
                forTextMarkerRange: markerRange,
                in: element,
                request: request
            )
            if let failure = interruptionFailure(for: request) {
                return .interrupted(failure)
            }
        }
        if selectionBounds == nil {
            selectionBounds = elementBounds(element, request: request)
            if let failure = interruptionFailure(for: request) {
                return .interrupted(failure)
            }
        }
        let identifier = stringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return .interrupted(failure)
        }
        let domIdentifier = stringAttribute(
            "AXDOMIdentifier" as CFString,
            from: element,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return .interrupted(failure)
        }
        let chromeNodeIdentifier = stringAttribute(
            "ChromeAXNodeId" as CFString,
            from: element,
            request: request
        )
        if let failure = interruptionFailure(for: request) {
            return .interrupted(failure)
        }
        return .selected(
            SelectionAgentSelection(
                text: selectedText,
                range: range.map {
                    SelectionAgentRange(
                        location: $0.location,
                        length: $0.length
                    )
                },
                accessibilityScreenBounds: selectionBounds.map {
                    SelectionAgentRect(
                        x: $0.minX,
                        y: $0.minY,
                        width: $0.width,
                        height: $0.height
                    )
                },
                captureStrategy: candidate.strategy,
                candidateDepth: candidate.depth,
                role: boundedMetadata(
                    role,
                    maximumBytes:
                        BlocksSelectionCaptureProtocol
                            .maximumRoleBytes
                ),
                subrole: boundedMetadata(
                    subrole,
                    maximumBytes:
                        BlocksSelectionCaptureProtocol
                            .maximumSubroleBytes
                ),
                identifier: boundedMetadata(
                    identifier,
                    maximumBytes:
                        BlocksSelectionCaptureProtocol
                            .maximumIdentifierBytes
                ),
                domIdentifier: boundedMetadata(
                    domIdentifier,
                    maximumBytes:
                        BlocksSelectionCaptureProtocol
                            .maximumDOMIdentifierBytes
                ),
                chromeNodeIdentifier: boundedMetadata(
                    chromeNodeIdentifier,
                    maximumBytes:
                        BlocksSelectionCaptureProtocol
                            .maximumChromeNodeIdentifierBytes
                )
            )
        )
    }

    private func appendAncestorCandidates(
        from element: AXUIElement,
        strategy: SelectionAgentCaptureStrategy,
        into candidates: inout [Candidate],
        seen: inout Set<CFHashCode>,
        request: SelectionAgentCaptureRequest
    ) {
        var current: AXUIElement? = element
        for depth in 0...Self.maximumAncestorDepth {
            guard canAccessAccessibility(for: request) else { return }
            guard let candidate = current else { return }
            let hash = CFHash(candidate)
            if seen.insert(hash).inserted {
                candidates.append(Candidate(
                    element: candidate,
                    strategy: strategy,
                    depth: depth
                ))
            }
            current = axElementAttribute(
                kAXParentAttribute as CFString,
                from: candidate,
                request: request
            )
        }
    }

    private func appendDocumentCandidates(
        from window: AXUIElement,
        into candidates: inout [Candidate],
        seen: inout Set<CFHashCode>,
        request: SelectionAgentCaptureRequest
    ) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var visited = 0
        while cursor < queue.count,
              visited < Self.maximumDocumentNodes,
              !isExpired(request),
              !cancellations.isCancelled(request.requestID) {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1
            let role = stringAttribute(
                kAXRoleAttribute as CFString,
                from: element,
                request: request
            )
            if depth > 0,
               role.map(Self.candidateRoles.contains) == true {
                let hash = CFHash(element)
                if seen.insert(hash).inserted {
                    candidates.append(Candidate(
                        element: element,
                        strategy: .focusedWindowDocument,
                        depth: depth
                    ))
                }
            }
            guard depth < Self.maximumDocumentDepth else {
                continue
            }
            for child in children(of: element, request: request)
                .prefix(Self.maximumChildrenPerNode) {
                queue.append((child, depth + 1))
            }
        }
    }

    private func element(
        at point: SelectionAgentPoint,
        applicationElement: AXUIElement,
        targetPID: pid_t,
        request: SelectionAgentCaptureRequest
    ) -> (element: AXUIElement?, status: SelectionHelperCaptureDiagnostics.HitTest) {
        SelectionHelperTargetHitTest.read(
            targetApplication: applicationElement,
            targetPID: targetPID,
            isAllowed: { canAccessAccessibility(for: request) },
            hitTest: { application in
                // Application-scoped hit-testing cannot be redirected into a
                // Blocks skeleton covering the frozen mouse point.
                var element: AXUIElement?
                guard canAccessAccessibility(for: request),
                      AXUIElementCopyElementAtPosition(
                        application, Float(point.x), Float(point.y), &element
                      ) == .success else { return nil }
                return element
            },
            processIdentifier: { element in
                var actualPID: pid_t = 0
                guard canAccessAccessibility(for: request),
                      AXUIElementGetPid(element, &actualPID) == .success else {
                    return nil
                }
                return actualPID
            }
        )
    }

    private func children(
        of element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return [] }
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }

    private func directSelectedText(
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> String? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        if let text = value as? String {
            return text
        }
        return (value as? NSAttributedString)?.string
    }

    private func selectedTextRange(
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> NSRange? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0,
              range.location <= Int.max - range.length else {
            return nil
        }
        return NSRange(
            location: range.location,
            length: range.length
        )
    }

    private func string(
        for range: NSRange,
        in element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> String? {
        var cfRange = CFRange(
            location: range.location,
            length: range.length
        )
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        if let text = value as? String {
            return text
        }
        return (value as? NSAttributedString)?.string
    }

    private func selectedTextMarkerRange(
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        return value
    }

    private func length(
        forTextMarkerRange markerRange: CFTypeRef,
        in element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> SelectionHelperMarkerLength {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return .invalid }
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLengthForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &value
        )
        return SelectionHelperMarkerLength.decode(status: status, value: value)
    }

    private func string(
        forTextMarkerRange markerRange: CFTypeRef,
        in element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> String? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &value
        ) == .success else {
            return nil
        }
        if let text = value as? String {
            return text
        }
        return (value as? NSAttributedString)?.string
    }

    private func bounds(
        for range: NSRange,
        in element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> CGRect? {
        var cfRange = CFRange(
            location: range.location,
            length: range.length
        )
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        return cgRect(from: value)
    }

    private func bounds(
        forTextMarkerRange markerRange: CFTypeRef,
        in element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> CGRect? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &value
        ) == .success else {
            return nil
        }
        return cgRect(from: value)
    }

    private func cgRect(from value: CFTypeRef?) -> CGRect? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }
        return validScreenRect(rect) ? rect : nil
    }

    private func elementBounds(
        _ element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> CGRect? {
        guard let positionValue = axValueAttribute(
            kAXPositionAttribute as CFString,
            from: element,
            request: request
        ),
        AXValueGetType(positionValue) == .cgPoint,
        let sizeValue = axValueAttribute(
            kAXSizeAttribute as CFString,
            from: element,
            request: request
        ),
        AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        let rect = CGRect(origin: point, size: size)
        return validScreenRect(rect) ? rect : nil
    }

    private func axValueAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> AXValue? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> String? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func boundedMetadata(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        SelectionAgentPayloadValidator.truncatedMetadata(
            value,
            maximumBytes: maximumBytes
        )
    }

    private func validScreenRect(_ rect: CGRect) -> Bool {
        SelectionAgentPayloadValidator.isValid(
            SelectionAgentRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        )
    }

    private func axElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        request: SelectionAgentCaptureRequest
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard canAccessAccessibility(for: request) else { return nil }
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func isExpired(
        _ request: SelectionAgentCaptureRequest
    ) -> Bool {
        Date() >= request.deadline
    }

    private func interruptionFailure(
        for request: SelectionAgentCaptureRequest
    ) -> SelectionAgentCaptureResponse? {
        if cancellations.isCancelled(request.requestID) {
            return .failure(
                requestID: request.requestID,
                code: .cancelled
            )
        }
        if isExpired(request) {
            return .failure(
                requestID: request.requestID,
                code: .timedOut
            )
        }
        return nil
    }

    private func canAccessAccessibility(
        for request: SelectionAgentCaptureRequest
    ) -> Bool {
        interruptionFailure(for: request) == nil
    }

    private func messagingTimeout(
        for request: SelectionAgentCaptureRequest
    ) -> Float {
        SelectionHelperAXMessagingTimeoutPolicy.timeout(deadline: request.deadline)
    }
}

protocol SelectionHelperKeyStoring: AnyObject {
    func load() -> Data?
    func save(_ data: Data) -> Bool
    func delete() -> Bool
    func replaceActiveKeyWithDisconnectTombstone(
        expiresAt: Date
    ) -> Bool
    func loadDisconnectTombstone(
        now: Date
    ) -> Data?
    @discardableResult
    func clearDisconnectTombstone() -> Bool
    func permitsLocalAssociation() -> Bool
    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool
    func persistAutomaticAssociationDisabled() -> Bool
    func permitsExplicitAssociationIntent() -> Bool
    func prepareExplicitLocalAssociation() -> Bool
    func permitsAuthenticatedUse() -> Bool
}

protocol SelectionHelperBootstrapKeyLoading: AnyObject {
    func load() -> Data?
}

extension SelectionHelperKeyStoring {
    func permitsLocalAssociation() -> Bool { false }
    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool { false }
    func persistAutomaticAssociationDisabled() -> Bool { false }
    func permitsExplicitAssociationIntent() -> Bool { false }
    func prepareExplicitLocalAssociation() -> Bool { false }
    func permitsAuthenticatedUse() -> Bool { false }
}

/// The Helper deliberately has no creation API for this secret. A missing
/// bootstrap key is a fail-closed pairing error, not an opportunity to create
/// a one-sided identity.
final class SelectionHelperBootstrapKeyStore:
    SelectionHelperBootstrapKeyLoading
{
    func load() -> Data? {
        guard var query = keychainQuery() else { return nil }
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        guard BlocksKeychainAccess.helperCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            return nil
        }
        return data
    }

    private func keychainQuery() -> [String: Any]? {
        BlocksKeychainNamespace.helperQuery(
            service: BlocksSelectionHelperProtocol.bootstrapKeychainService,
            account: BlocksSelectionHelperProtocol.bootstrapKeychainAccount,
            accessGroup: SelectionHelperSharedKeychainAccessGroup.current()
        )
    }
}

struct SelectionHelperDisconnectTombstone: Codable {
    let key: Data
    let expiresAt: Date
}

final class SelectionHelperKeyStore: SelectionHelperKeyStoring {
    private static let localAssociationLogger = Logger(subsystem: "app.blocks.selection-helper", category: "LocalAssociation")
    private let accessGroupProvider: () -> String?
    private let copyMatching: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    private let updateItem: (CFDictionary, CFDictionary) -> OSStatus
    private let addItem: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    private let deleteItem: (CFDictionary) -> OSStatus
    private static let disconnectTombstoneService =
        "\(BlocksSelectionHelperProtocol.keychainService).disconnect-tombstone"
    private static let disconnectTombstoneAccount = "v1"

    init(
        accessGroupProvider: @escaping () -> String? = {
            SelectionHelperSharedKeychainAccessGroup.current()
        },
        copyMatching: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = BlocksKeychainAccess.helperCopyMatching,
        updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus =
            BlocksKeychainAccess.helperUpdate,
        addItem: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = BlocksKeychainAccess.helperAdd,
        deleteItem: @escaping (CFDictionary) -> OSStatus = BlocksKeychainAccess.helperDelete
    ) {
        self.accessGroupProvider = accessGroupProvider
        self.copyMatching = copyMatching
        self.updateItem = updateItem
        self.addItem = addItem
        self.deleteItem = deleteItem
    }

    func load() -> Data? {
        var result: CFTypeRef?
        guard var query = keychainQuery(
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        ) else {
            return nil
        }
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        guard copyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            return nil
        }
        return data
    }

    func save(_ data: Data) -> Bool {
        guard data.count == 32 else { return false }
        guard let query = keychainQuery(
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        ) else {
            return false
        }
        let status = updateItem(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let didSave = addItem(
                item as CFDictionary,
                nil
            ) == errSecSuccess
            if didSave {
                deleteLegacyActiveKey()
            }
            return didSave
        }
        guard status == errSecSuccess else { return false }
        deleteLegacyActiveKey()
        return true
    }

    func permitsLocalAssociation() -> Bool {
        var identities = [(BlocksSelectionHelperProtocol.keychainService, BlocksSelectionHelperProtocol.keychainAccount),
                          (BlocksSelectionHelperProtocol.legacyKeychainService, BlocksSelectionHelperProtocol.legacyKeychainAccount)]
        #if BLOCKS_LOCAL_DEVELOPMENT
        identities.append((Self.disconnectTombstoneService, Self.disconnectTombstoneAccount))
        #else
        identities.append((SelectionHelperLocalAssociation.disabledKeychainService, SelectionHelperLocalAssociation.disabledKeychainAccount))
        #endif
        return identities.enumerated().allSatisfy { index, identity in
            let (service, account) = identity
            guard var query = keychainQuery(service: service, account: account) else { return false }
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = copyMatching(query as CFDictionary, nil)
            if status != errSecItemNotFound {
                Self.localAssociationLogger.notice("stage=helper-keychain-absence slot=\(index, privacy: .public) status=\(status, privacy: .public)")
            }
            return status == errSecItemNotFound
        }
    }

    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool {
        guard data.count == 32,
              var query = keychainQuery(service: BlocksSelectionHelperProtocol.keychainService,
                                        account: BlocksSelectionHelperProtocol.keychainAccount) else { return false }
        query[kSecValueData as String] = data
        return addItem(query as CFDictionary, nil) == errSecSuccess
    }

    func persistAutomaticAssociationDisabled() -> Bool {
        guard let query = keychainQuery(service: SelectionHelperLocalAssociation.disabledKeychainService,
                                        account: SelectionHelperLocalAssociation.disabledKeychainAccount) else { return false }
        return SelectionHelperLocalAssociation.persistDisabledMarker(query: query, copy: copyMatching, add: addItem)
    }

    func permitsExplicitAssociationIntent() -> Bool {
        for (service, account) in [(BlocksSelectionHelperProtocol.keychainService, BlocksSelectionHelperProtocol.keychainAccount),
                                   (BlocksSelectionHelperProtocol.legacyKeychainService, BlocksSelectionHelperProtocol.legacyKeychainAccount)] {
            guard let query = keychainQuery(service: service, account: account),
                  copyMatching(query as CFDictionary, nil) == errSecItemNotFound else { return false }
        }
        guard let query = keychainQuery(service: SelectionHelperLocalAssociation.disabledKeychainService,
                                        account: SelectionHelperLocalAssociation.disabledKeychainAccount) else { return false }
        return SelectionHelperLocalAssociation.disabledMarkerPresence(query: query, copy: copyMatching) != nil
    }

    func prepareExplicitLocalAssociation() -> Bool {
        guard permitsExplicitAssociationIntent(),
              let query = keychainQuery(service: SelectionHelperLocalAssociation.disabledKeychainService,
                                        account: SelectionHelperLocalAssociation.disabledKeychainAccount) else { return false }
        return SelectionHelperLocalAssociation.clearDisabledMarkerForExplicitOptIn(query: query, copy: copyMatching, delete: deleteItem)
    }

    func permitsAuthenticatedUse() -> Bool {
        guard let query = keychainQuery(service: SelectionHelperLocalAssociation.disabledKeychainService,
                                        account: SelectionHelperLocalAssociation.disabledKeychainAccount) else { return false }
        return SelectionHelperLocalAssociation.disabledMarkerPresence(query: query, copy: copyMatching) == false
    }

    func delete() -> Bool {
        guard let activeKeyQuery else { return false }
        let status = deleteItem(activeKeyQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func replaceActiveKeyWithDisconnectTombstone(
        expiresAt: Date
    ) -> Bool {
        guard let key = load(),
              let encoded = try? JSONEncoder().encode(
                SelectionHelperDisconnectTombstone(
                    key: key,
                    expiresAt: expiresAt
                )
              ),
              saveDisconnectTombstone(encoded) else {
            return false
        }
        // Persist the acknowledgement before deleting the active key. If the
        // active deletion fails, keep it authoritative and remove the new
        // tombstone best-effort; a stale tombstone cannot authenticate while
        // an active key exists.
        guard delete() else {
            clearDisconnectTombstone()
            return false
        }
        return true
    }

    func loadDisconnectTombstone(now: Date) -> Data? {
        guard let data = loadData(
            service: Self.disconnectTombstoneService,
            account: Self.disconnectTombstoneAccount
        ), let tombstone = try? JSONDecoder().decode(
            SelectionHelperDisconnectTombstone.self,
            from: data
        ), tombstone.key.count == 32 else {
            return nil
        }
        guard tombstone.expiresAt > now else {
            clearDisconnectTombstone()
            return nil
        }
        return tombstone.key
    }

    @discardableResult
    func clearDisconnectTombstone() -> Bool {
        guard let query = keychainQuery(
            service: Self.disconnectTombstoneService,
            account: Self.disconnectTombstoneAccount
        ) else {
            return false
        }
        let status = deleteItem(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private var activeKeyQuery: [String: Any]? {
        keychainQuery(
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
    }

    private func loadData(service: String, account: String) -> Data? {
        var result: CFTypeRef?
        guard var query = keychainQuery(
            service: service,
            account: account
        ) else {
            return nil
        }
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        guard copyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    private func saveDisconnectTombstone(_ data: Data) -> Bool {
        guard let query = keychainQuery(
            service: Self.disconnectTombstoneService,
            account: Self.disconnectTombstoneAccount
        ) else {
            return false
        }
        let status = updateItem(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            return addItem(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private func keychainQuery(
        service: String,
        account: String
    ) -> [String: Any]? {
        BlocksKeychainNamespace.helperQuery(
            service: service, account: account, accessGroup: accessGroupProvider()
        )
    }

    private func deleteLegacyActiveKey() {
        guard let query = keychainQuery(
            service: BlocksSelectionHelperProtocol.legacyKeychainService,
            account: BlocksSelectionHelperProtocol.legacyKeychainAccount
        ) else {
            return
        }
        _ = deleteItem(query as CFDictionary)
    }
}

enum SelectionHelperPairingResetFailure: Error, Equatable {
    case keyDeletionFailed
}

enum SelectionHelperPairingCommitResult: Equatable {
    case rejected
    case keyStorageFailed
    case committed(generation: UInt64)
}

private struct SelectionHelperPairReplyReplayEntry {
    let request: SelectionHelperPairRequest
    let response: Data
    let expiresAt: Date
}

final class SelectionHelperServer:
    @unchecked Sendable
{
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    enum ListenerHost {
        case ipv4Loopback
        case ipv6Loopback
    }

    enum ListenerResult: Equatable {
        case ready
        case failed(String)
    }

    protocol Listener: AnyObject {
        func start(queue: DispatchQueue)
        func cancel()
    }

    typealias ListenerFactory = (
        _ host: NWEndpoint.Host,
        _ listenerHost: ListenerHost,
        _ stateHandler: @escaping (ListenerResult) -> Void,
        _ connectionHandler: @escaping (NWConnection) -> Void
    ) throws -> any Listener

    struct ListenerReadiness {
        private var ipv4Result: ListenerResult?
        private var ipv6Result: ListenerResult?

        mutating func record(
            _ newResult: ListenerResult,
            for host: ListenerHost
        ) -> State? {
            switch (host, result(for: host), newResult) {
            case (.ipv4Loopback, nil, .ready):
                set(.ready, for: host)
                return .ready
            case let (.ipv4Loopback, nil, .failed(description)),
                 let (.ipv4Loopback, .ready, .failed(description)):
                // NWListener can report a terminal failure after it was ready.
                // Preserve that first failure so the model can offer retry.
                set(.failed(description), for: host)
                return .failed(
                    "IPv4 loopback listener failed: \(description)"
                )
            case (.ipv6Loopback, nil, let result):
                set(result, for: host)
                return nil
            default:
                // IPv6 is optional, and each generation publishes only one
                // IPv4 ready result plus a possible first terminal failure.
                return nil
            }
        }

        private func result(for host: ListenerHost) -> ListenerResult? {
            switch host {
            case .ipv4Loopback:
                ipv4Result
            case .ipv6Loopback:
                ipv6Result
            }
        }

        private mutating func set(
            _ result: ListenerResult,
            for host: ListenerHost
        ) {
            switch host {
            case .ipv4Loopback:
                ipv4Result = result
            case .ipv6Loopback:
                ipv6Result = result
            }
        }
    }

    private struct ResponseSenderAdmission {
        private var activeResponseSenderIDs: Set<UUID> = []

        mutating func admit(
            maximumActiveResponseSenders: Int
        ) -> UUID? {
            guard activeResponseSenderIDs.count <
                maximumActiveResponseSenders else {
                return nil
            }
            let responseID = UUID()
            activeResponseSenderIDs.insert(responseID)
            return responseID
        }

        mutating func release(_ responseID: UUID) {
            activeResponseSenderIDs.remove(responseID)
        }

        var count: Int {
            activeResponseSenderIDs.count
        }
    }

    /// Local resource admission only; this is not a wire or version contract.
    private static let defaultMaximumActiveResponseSenders = 64
    private static let logger = Logger(
        subsystem: "app.blocks.selection-helper",
        category: "Loopback"
    )
    private let keyStore: any SelectionHelperKeyStoring
    private let bootstrapKeyStore: any SelectionHelperBootstrapKeyLoading
    private let replayGate = SelectionHelperAuthenticatedReplayGate()
    private let captureService = SelectionHelperCaptureService()
    private let pasteTargetInspectionService =
        SelectionHelperPasteTargetInspectionService()
    private let now: () -> Date
    private let queue = DispatchQueue(
        label: "app.blocks.selection-helper.server",
        qos: .userInitiated
    )
    private let stateHandler: @MainActor (State) -> Void
    private let pairingHandler: @MainActor (Bool, UInt64) -> Void
    private let listenerFactory: ListenerFactory
    private let maximumActiveResponseSenders: Int
    private var listeners: [any Listener] = []
    private var listenerReadiness = ListenerReadiness()
    private var listenerGeneration: UInt64 = 0
    private var currentServerState: State = .starting
    private var failedPairAttempts: [Date] = []
    private var pairingCode: String
    private var pairingGeneration: UInt64 = 0
    private let localAssociationServer = SelectionHelperLocalAssociationTransport.Server()
    private var localAssociationAuthority = SelectionHelperLocalAssociation.Authority()
    // One entry is intentional: this is acknowledgement recovery, not a
    // general request cache. It is process-local and expires quickly.
    private var recentSuccessfulPairReply:
        SelectionHelperPairReplyReplayEntry?
    private let pairReplyReplayLifetime: TimeInterval
    private var activeResponseSenders:
        [UUID: SelectionHelperResponseFrameSender] = [:]
    private var responseSenderAdmission: ResponseSenderAdmission
    private let applicationUpdateGate = ApplicationOperationAdmissionGate(name: "Selection Helper requests")
    // These flags are confined to `queue`, just like authenticated commands.
    private var preparedForApplicationUpdate = false
    private var terminationRequestGeneration: UInt64 = 0

    func beginUserOperation() -> ApplicationOperationAdmissionGate.Lease? { applicationUpdateGate.begin() }

    func prepareForNormalTermination() -> Bool {
        queue.sync {
            guard responseSenderAdmission.count == 0 else { return false }
            do {
                try applicationUpdateGate.pauseIfIdle()
                preparedForApplicationUpdate = true
                return true
            } catch { return false }
        }
    }

    private func requestTerminationAfterResponsesFinish(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.preparedForApplicationUpdate,
                  self.terminationRequestGeneration == generation else { return }
            guard self.responseSenderAdmission.count == 0,
                  self.applicationUpdateGate.activeOperationCount == 0 else {
                self.requestTerminationAfterResponsesFinish(generation: generation)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let authorized = self.queue.sync {
                    self.preparedForApplicationUpdate && self.terminationRequestGeneration == generation
                }
                if authorized { NSApp.terminate(nil) }
            }
        }
    }

    init(
        pairingCode: String,
        stateHandler: @escaping @MainActor (State) -> Void,
        pairingHandler: @escaping @MainActor (Bool, UInt64) -> Void,
        keyStore: any SelectionHelperKeyStoring = SelectionHelperKeyStore(),
        bootstrapKeyStore: any SelectionHelperBootstrapKeyLoading =
            SelectionHelperBootstrapKeyStore(),
        now: @escaping () -> Date = Date.init,
        pairReplyReplayLifetime: TimeInterval = 5,
        listenerFactory: @escaping ListenerFactory =
            SelectionHelperServer.makeNetworkListener,
        maximumActiveResponseSenders: Int =
            defaultMaximumActiveResponseSenders
    ) {
        precondition(maximumActiveResponseSenders > 0)
        self.pairingCode = pairingCode
        self.stateHandler = stateHandler
        self.pairingHandler = pairingHandler
        self.keyStore = keyStore
        self.bootstrapKeyStore = bootstrapKeyStore
        self.now = now
        self.pairReplyReplayLifetime = pairReplyReplayLifetime
        self.listenerFactory = listenerFactory
        self.maximumActiveResponseSenders = maximumActiveResponseSenders
        responseSenderAdmission = ResponseSenderAdmission()
    }

    @discardableResult
    func updatePairingCode(_ code: String) -> UInt64 {
        queue.sync {
            guard applicationUpdateGate.isAcceptingOperations else { return pairingGeneration }
            pairingGeneration &+= 1
            pairingCode = code
            return pairingGeneration
        }
    }

    @discardableResult
    func resetPairing(
        _ code: String
    ) -> Result<UInt64, SelectionHelperPairingResetFailure> {
        guard let lease = applicationUpdateGate.begin() else { return .failure(.keyDeletionFailed) }
        defer { lease.release() }
        return queue.sync {
            // This runs on the same serial queue as pairing and authenticated
            // commands, so an in-flight pairing cannot restore the old key.
            #if !BLOCKS_LOCAL_DEVELOPMENT
            localAssociationAuthority.invalidate()
            pairingGeneration &+= 1
            guard keyStore.persistAutomaticAssociationDisabled() else { return .failure(.keyDeletionFailed) }
            #endif
            guard keyStore.delete() else {
                return .failure(.keyDeletionFailed)
            }
            keyStore.clearDisconnectTombstone()
            recentSuccessfulPairReply = nil
            #if BLOCKS_LOCAL_DEVELOPMENT
            pairingGeneration &+= 1
            #endif
            pairingCode = code
            failedPairAttempts.removeAll()
            return .success(pairingGeneration)
        }
    }

    func disconnectPairedClient() -> Bool {
        queue.sync { disconnectPairedClientOnQueue() }
    }

    private func disconnectPairedClientOnQueue() -> Bool {
        guard let operationLease = applicationUpdateGate.begin() else { return false }
        defer { operationLease.release() }
        #if !BLOCKS_LOCAL_DEVELOPMENT
        localAssociationAuthority.invalidate()
        pairingGeneration &+= 1
        guard keyStore.persistAutomaticAssociationDisabled() else { return false }
        #endif
        guard keyStore.replaceActiveKeyWithDisconnectTombstone(
            expiresAt: Date().addingTimeInterval(
                BlocksSelectionHelperProtocol
                    .disconnectAcknowledgementLifetime
            )
        ) else {
            return false
        }
        recentSuccessfulPairReply = nil
        let pairingGeneration = self.pairingGeneration
        let notificationLease = applicationUpdateGate.begin()
        Task { @MainActor in
            defer { notificationLease?.release() }
            pairingHandler(false, pairingGeneration)
        }
        return true
    }

    #if DEBUG
    // This is deliberately limited to pairing packets. Tests exercise the
    // production proof, ECDH, rate-limit, and persistence path without a
    // listener or a bypass for authenticated commands.
    func submitRawPairRequestForTesting(
        _ request: SelectionHelperPairRequest
    ) -> Data? {
        guard let payload = try? JSONEncoder().encode(request) else {
            return nil
        }
        return queue.sync {
            handlePair(
                SelectionHelperWirePacket(kind: .pair, payload: payload)
            )
        }
    }

    func submitRawAuthenticatedPacketForTesting(
        _ packet: SelectionHelperWirePacket,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        queue.async { [self] in handleAuthenticated(packet, completion: completion) }
    }
    #endif

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startListeners()
            self.localAssociationServer.start { [weak self] data, peer in
                guard let self else { return nil }
                return self.queue.sync { self.handleLocalAssociation(data, peer: peer) }
            }
        }
    }

    private func handleLocalAssociation(_ data: Data, peer: SelectionHelperLocalAssociationTransport.Peer) -> Data? {
        guard let lease = applicationUpdateGate.begin() else { return nil }
        defer { lease.release() }
        guard SelectionHelperLocalAssociationTransport.isCurrent(peer, role: "app"),
              let request = try? JSONDecoder().decode(SelectionHelperLocalAssociation.Request.self, from: data),
              request.version == SelectionHelperLocalAssociation.version,
              UUID(uuidString: request.requestID) != nil else { return nil }
        let paired = keyStore.load() != nil
        let response: SelectionHelperLocalAssociation.Response
        switch request.kind {
        case .status:
            #if !BLOCKS_LOCAL_DEVELOPMENT
            let intent: SelectionHelperLocalAssociation.Intent?
            if !paired, keyStore.permitsExplicitAssociationIntent(), let publicKey = request.clientPublicKey {
                intent = localAssociationAuthority.issueIntent(requestID: request.requestID, clientPublicKey: publicKey,
                    generation: pairingGeneration, isPaired: paired, now: now(), peerToken: peer.auditToken)
            } else { intent = nil }
            response = .init(isPaired: paired, intent: intent)
            #else
            response = .init(isPaired: paired)
            #endif
        case .authorize:
            guard !paired, let publicKey = request.clientPublicKey else { return nil }
            #if !BLOCKS_LOCAL_DEVELOPMENT
            guard let intent = request.intent,
                  localAssociationAuthority.consumeIntent(intent, requestID: request.requestID, clientPublicKey: publicKey,
                    generation: pairingGeneration, isPaired: paired, now: now(), peerToken: peer.auditToken),
                  keyStore.prepareExplicitLocalAssociation() else { return nil }
            #endif
            guard keyStore.permitsLocalAssociation(),
                  let authorization = localAssociationAuthority.issue(
                    requestID: request.requestID, clientPublicKey: publicKey,
                    generation: pairingGeneration, isPaired: paired, now: now(), peerToken: peer.auditToken
                  ) else { return nil }
            response = .init(isPaired: false, authorization: authorization)
        case .pair:
            guard let pairRequest = request.pairRequest,
                  pairRequest.requestID == request.requestID,
                  let authorization = localAssociationAuthority.consume(
                    request: pairRequest, generation: pairingGeneration,
                    isPaired: paired, now: now(), peerToken: peer.auditToken
                  ),
                  let payload = try? JSONEncoder().encode(pairRequest),
                  let reply = handlePair(.init(kind: .pair, payload: payload), localAuthorization: authorization, localPeer: peer) else { return nil }
            response = .init(isPaired: keyStore.load() != nil, pairPacket: reply)
        case .disable:
            #if !BLOCKS_LOCAL_DEVELOPMENT
            // Association policy only: strong peer authentication already ran
            // above. Never remove an active key without its authenticated command.
            localAssociationAuthority.invalidate()
            pairingGeneration &+= 1
            let disabled = keyStore.persistAutomaticAssociationDisabled()
            response = .init(isPaired: !keyStore.permitsExplicitAssociationIntent(), automaticAssociationDisabled: disabled)
            #else
            return nil
            #endif
        }
        return try? JSONEncoder().encode(response)
    }

    func retryIfFailed() {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .failed = self.currentServerState else { return }
            self.listeners.forEach { $0.cancel() }
            self.listeners.removeAll()
            self.startListeners()
        }
    }

    private func startListeners() {
        listenerGeneration &+= 1
        let generation = listenerGeneration
        listenerReadiness = ListenerReadiness()
        publishState(.starting)
        let listeners: [(NWEndpoint.Host, ListenerHost)] = [
            ("127.0.0.1", .ipv4Loopback),
            ("::1", .ipv6Loopback),
        ]
        for (host, listenerHost) in listeners {
            startListener(
                host: host,
                listenerHost: listenerHost,
                generation: generation
            )
        }
    }

    private func startListener(
        host: NWEndpoint.Host,
        listenerHost: ListenerHost,
        generation: UInt64
    ) {
        do {
            let listener = try listenerFactory(
                host,
                listenerHost,
                { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self,
                              self.listenerGeneration == generation else {
                            return
                        }
                        self.recordListener(result, for: listenerHost)
                    }
                },
                { [weak self] connection in
                    self?.accept(connection)
                }
            )
            listeners.append(listener)
            listener.start(queue: queue)
        } catch {
            recordListener(
                .failed(error.localizedDescription),
                for: listenerHost
            )
        }
    }

    private func recordListener(
        _ result: ListenerResult,
        for host: ListenerHost
    ) {
        guard let state = listenerReadiness.record(result, for: host) else {
            return
        }
        publishState(state)
    }

    private func publishState(_ state: State) {
        currentServerState = state
        Task { @MainActor in
            stateHandler(state)
        }
    }

    private static func makeNetworkListener(
        host: NWEndpoint.Host,
        listenerHost: ListenerHost,
        stateHandler: @escaping (ListenerResult) -> Void,
        connectionHandler: @escaping (NWConnection) -> Void
    ) throws -> any Listener {
        try NetworkListener(
            host: host,
            listenerHost: listenerHost,
            stateHandler: stateHandler,
            connectionHandler: connectionHandler
        )
    }

    private final class NetworkListener: Listener {
        private let listener: NWListener

        init(
            host: NWEndpoint.Host,
            listenerHost: ListenerHost,
            stateHandler: @escaping (ListenerResult) -> Void,
            connectionHandler: @escaping (NWConnection) -> Void
        ) throws {
            let parameters = NWParameters.tcp
            let port = NWEndpoint.Port(
                rawValue: BlocksSelectionHelperProtocol.loopbackPort
            )!
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: host,
                port: port
            )
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    stateHandler(.ready)
                case let .failed(error):
                    stateHandler(.failed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = connectionHandler
            _ = listenerHost
        }

        func start(queue: DispatchQueue) {
            listener.start(queue: queue)
        }

        func cancel() {
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        SelectionHelperRequestFrameReceiver(
            connection: connection,
            queue: queue
        ) { [weak self] requestPayload in
            self?.handle(requestPayload) { response in
                self?.send(response, on: connection)
            }
        }.start()
    }

    private func handle(
        _ data: Data,
        completion: @escaping (Data?) -> Void
    ) {
        guard let packet = try? JSONDecoder().decode(
            SelectionHelperWirePacket.self,
            from: data
        ) else {
            completion(nil)
            return
        }
        switch packet.kind {
        case .pair:
            completion(handlePair(packet))
        case .authenticated:
            handleAuthenticated(
                packet,
                completion: completion
            )
        }
    }

    private func handlePair(
        _ packet: SelectionHelperWirePacket,
        localAuthorization: SelectionHelperLocalAssociation.Authorization? = nil,
        localPeer: SelectionHelperLocalAssociationTransport.Peer? = nil
    ) -> Data? {
        guard let lease = applicationUpdateGate.begin() else { return nil }
        defer { lease.release() }
        guard let request = try? JSONDecoder().decode(
            SelectionHelperPairRequest.self,
            from: packet.payload
        ) else {
            return nil
        }
        guard !request.requestID.isEmpty,
              request.requestID.utf8.count <=
                BlocksSelectionCaptureProtocol.maximumRequestIdentifierBytes else {
            return nil
        }
        if localAuthorization == nil, let response = cachedSuccessfulPairReply(for: request) {
            return response
        }
        guard request.protocolVersion ==
                BlocksSelectionHelperProtocol.version else {
            return pairResponse(
                SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: nil,
                    helperProof: nil,
                    failureCode: "incompatible_version"
                )
            )
        }
        guard let bootstrapKey = localAuthorization?.bootstrapKey ?? bootstrapKeyStore.load() else {
            return pairResponse(
                SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: nil,
                    helperProof: nil,
                    failureCode: "bootstrap_unavailable"
                )
            )
        }
        guard SelectionHelperPairingAuthentication.verifiesClientProof(
            request.clientProof,
            bootstrapKey: bootstrapKey,
            request: request
        ) else {
            return pairResponse(
                SelectionHelperPairResponse(
                    requestID: request.requestID,
                    helperPublicKey: nil,
                    helperProof: nil,
                    failureCode: "invalid_pairing_proof"
                )
            )
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        guard let key = try?
                SelectionHelperAuthenticatedCodec
                    .deriveSharedKey(
                        privateKey: privateKey,
                        peerPublicKeyData:
                            request.clientPublicKey,
                        requestID: request.requestID
                    )
        else {
            return nil
        }
        let helperPublicKey = privateKey.publicKey.rawRepresentation
        guard let helperProof =
                SelectionHelperPairingAuthentication.helperProof(
                    bootstrapKey: bootstrapKey,
                    request: request,
                    helperPublicKey: helperPublicKey
                ) else {
            return nil
        }
        let response = SelectionHelperPairResponse(
            requestID: request.requestID,
            helperPublicKey: helperPublicKey,
            helperProof: helperProof,
            failureCode: nil
        )
        guard let responseData = pairResponse(response) else {
            return nil
        }
        let pairingResult: SelectionHelperPairingCommitResult
        if let localAuthorization {
            guard let localPeer, SelectionHelperLocalAssociationTransport.isCurrent(localPeer, role: "app"),
                  keyStore.permitsLocalAssociation(), pairingGeneration == localAuthorization.generation,
                  now() < localAuthorization.expiresAt else { return nil }
            if keyStore.saveLocalAssociationIfAbsent(key) {
                pairingGeneration &+= 1
                pairingCode = ""
                pairingResult = .committed(generation: pairingGeneration)
            } else { pairingResult = .keyStorageFailed }
        } else {
            pairingResult = commitPairing(code: request.pairingCode, key: key)
        }
        guard case let .committed(pairingGeneration) = pairingResult else {
            if case .rejected = pairingResult {
                return pairResponse(
                    SelectionHelperPairResponse(
                        requestID: request.requestID,
                        helperPublicKey: nil,
                        helperProof: nil,
                        failureCode: "invalid_pairing_code"
                    )
                )
            }
            return nil
        }
        // The cache is installed on the server's serial queue immediately
        // after the key/code commit and before the first reply can be sent.
        recentSuccessfulPairReply = SelectionHelperPairReplyReplayEntry(
            request: request,
            response: responseData,
            expiresAt: now().addingTimeInterval(pairReplyReplayLifetime)
        )
        let notificationLease = applicationUpdateGate.begin()
        Task { @MainActor in
            defer { notificationLease?.release() }
            pairingHandler(true, pairingGeneration)
        }
        return responseData
    }

    private func handleAuthenticated(
        _ packet: SelectionHelperWirePacket,
        completion: @escaping (Data?) -> Void
    ) {
        guard let envelope = try? JSONDecoder().decode(
                SelectionHelperSealedMessage.self,
                from: packet.payload
              )
        else {
            completion(nil)
            return
        }
        if let key = keyStore.load(),
           let command = try? replayGate.authenticate(
            SelectionHelperCommand.self,
            from: envelope,
            keyData: key
           ) {
            #if !BLOCKS_LOCAL_DEVELOPMENT
            // A durable opt-out is authoritative even when deletion failed.
            // Only the authenticated deletion retry remains usable.
            guard command.kind == .disconnect || keyStore.permitsAuthenticatedUse() else {
                completion(nil)
                return
            }
            #endif
            handle(command) { [weak self] response in
                self?.respond(
                    response,
                    to: envelope,
                    key: key,
                    completion: completion
                )
            }
            return
        }
        // A tombstone is deliberately narrower than an active pairing: it
        // proves only that this old key may repeat disconnect after a lost
        // acknowledgement. Health, capture, and every other command remain
        // unauthenticated once the active key is gone.
        guard let key = keyStore.loadDisconnectTombstone(now: Date()),
              (try? replayGate.authenticate(
                SelectionHelperCommand.self,
                from: envelope,
                keyData: key,
                accepting: { $0.kind == .disconnect }
              )) != nil else {
            completion(nil)
            return
        }
        respond(
            SelectionHelperCommandResponse(booleanValue: true),
            to: envelope,
            key: key,
            completion: completion
        )
    }

    private func respond(
        _ response: SelectionHelperCommandResponse,
        to envelope: SelectionHelperSealedMessage,
        key: Data,
        completion: @escaping (Data?) -> Void
    ) {
        do {
            let sealed = try SelectionHelperAuthenticatedCodec.seal(
                response,
                requestID: envelope.requestID,
                expiresAt: Date().addingTimeInterval(5),
                keyData: key
            )
            let sealedData = try JSONEncoder().encode(sealed)
            let responsePacket = SelectionHelperWirePacket(
                kind: .authenticated,
                payload: sealedData
            )
            completion(try JSONEncoder().encode(responsePacket))
        } catch {
            Self.logger.error(
                "response seal failed error=\(String(describing: error), privacy: .public)"
            )
            completion(nil)
        }
    }

    private func handle(
        _ command: SelectionHelperCommand,
        completion:
            @escaping (SelectionHelperCommandResponse) -> Void
    ) {
        // Only authenticated active-key messages can reach these controls.
        // They never delete the active key, bootstrap key, or pairing state.
        switch command.kind {
        case .prepareForApplicationUpdate:
            do {
                try applicationUpdateGate.pauseIfIdle()
                preparedForApplicationUpdate = true
                completion(.init(booleanValue: true))
            } catch { completion(.init(booleanValue: false, failureCode: "helper_busy")) }
            return
        case .resumeAfterCancelledApplicationUpdate:
            terminationRequestGeneration &+= 1
            preparedForApplicationUpdate = false
            applicationUpdateGate.resume()
            completion(.init(booleanValue: true))
            return
        case .terminateForApplicationUpdate:
            guard preparedForApplicationUpdate,
                  applicationUpdateGate.activeOperationCount == 0 else {
                completion(.init(booleanValue: false, failureCode: "helper_not_prepared"))
                return
            }
            terminationRequestGeneration &+= 1
            completion(.init(booleanValue: true))
            requestTerminationAfterResponsesFinish(generation: terminationRequestGeneration)
            return
        default: break
        }
        guard let lease = applicationUpdateGate.begin() else {
            completion(.init(failureCode: "application_update_preparing"))
            return
        }
        let originalCompletion = completion
        let completion: (SelectionHelperCommandResponse) -> Void = { response in
            defer { lease.release() }
            originalCompletion(response)
        }
        switch command.kind {
        case .health:
            completion(
                SelectionHelperCommandResponse(
                    health: SelectionHelperHealth(
                        helperVersion:
                            Bundle.main.object(
                                forInfoDictionaryKey:
                                    "CFBundleShortVersionString"
                            ) as? String ?? "0",
                        accessibilityTrusted:
                            captureService.permissionStatus(),
                        capabilities: [
                            BlocksSelectionHelperProtocol
                                .pasteTargetInspectionCapability,
                            BlocksSelectionHelperProtocol.updateLifecycleCapability,
                        ]
                    )
                )
            )
        case .capture:
            guard let request = command.captureRequest else {
                completion(
                    SelectionHelperCommandResponse(
                        failureCode: "invalid_request"
                    )
                )
                return
            }
            captureService.capture(request) { response in
                completion(
                    SelectionHelperCommandResponse(
                        captureResponse: response
                    )
                )
            }
        case .inspectPasteTarget:
            guard let request = command.pasteTargetRequest,
                  request.isValid else {
                completion(
                    SelectionHelperCommandResponse(
                        failureCode: "invalid_request"
                    )
                )
                return
            }
            pasteTargetInspectionService.inspect(request) { inspection in
                completion(
                    SelectionHelperCommandResponse(
                        pasteTargetInspection: inspection
                    )
                )
            }
        case .permissionStatus:
            completion(
                SelectionHelperCommandResponse(
                    booleanValue:
                        captureService.permissionStatus()
                )
            )
        case .requestPermission:
            DispatchQueue.main.async {
                completion(
                    SelectionHelperCommandResponse(
                        booleanValue:
                            self.captureService
                                .requestPermission()
                    )
                )
            }
        case .cancel:
            completion(
                SelectionHelperCommandResponse(
                    booleanValue:
                        command.cancellationRequestID.map {
                            captureService.cancel($0)
                        } ?? false
                )
            )
        case .disconnect:
            completion(
                SelectionHelperCommandResponse(
                    booleanValue: disconnectPairedClientOnQueue()
                )
            )
        case .prepareForApplicationUpdate, .resumeAfterCancelledApplicationUpdate, .terminateForApplicationUpdate:
            completion(.init(failureCode: "invalid_lifecycle_command"))
        }
    }

    private func send(
        _ data: Data?,
        on connection: NWConnection
    ) {
        queue.async { [weak self] in
            self?.beginSending(data, on: connection)
        }
    }

    private func beginSending(
        _ data: Data?,
        on connection: NWConnection
    ) {
        guard let data else {
            connection.cancel()
            return
        }
        guard let responseID = responseSenderAdmission.admit(
            maximumActiveResponseSenders: maximumActiveResponseSenders
        ) else {
            connection.cancel()
            return
        }
        let sender = SelectionHelperResponseFrameSender(
            connection: connection,
            queue: queue
        ) { [weak self] in
            guard let self else { return }
            self.activeResponseSenders.removeValue(forKey: responseID)
            self.responseSenderAdmission.release(responseID)
        }
        activeResponseSenders[responseID] = sender
        sender.send(data)
    }

    #if DEBUG
    func admitResponseSenderForTesting() -> UUID? {
        queue.sync {
            responseSenderAdmission.admit(
                maximumActiveResponseSenders:
                    maximumActiveResponseSenders
            )
        }
    }

    func releaseResponseSenderForTesting(_ responseID: UUID) {
        queue.sync {
            responseSenderAdmission.release(responseID)
        }
    }

    func activeResponseSenderCountForTesting() -> Int {
        queue.sync {
            responseSenderAdmission.count
        }
    }
    #endif

    private func pairResponse(
        _ response: SelectionHelperPairResponse
    ) -> Data? {
        guard let payload = try? JSONEncoder().encode(response) else {
            return nil
        }
        return try? JSONEncoder().encode(
            SelectionHelperWirePacket(
                kind: .pair,
                payload: payload
            )
        )
    }

    private func commitPairing(
        code: String,
        key: Data
    ) -> SelectionHelperPairingCommitResult {
        guard let pairingGeneration = beginPairAttempt(code: code) else {
            return .rejected
        }
        guard let committedGeneration = persistPairing(
            key,
            expectedGeneration: pairingGeneration
        ) else {
            return .keyStorageFailed
        }
        return .committed(generation: committedGeneration)
    }

    private func beginPairAttempt(code: String) -> UInt64? {
        let now = now()
        failedPairAttempts.removeAll {
            now.timeIntervalSince($0) > 60
        }
        guard failedPairAttempts.count < 5,
              code == pairingCode else {
            failedPairAttempts.append(now)
            return nil
        }
        failedPairAttempts.removeAll()
        return pairingGeneration
    }

    private func cachedSuccessfulPairReply(
        for request: SelectionHelperPairRequest
    ) -> Data? {
        guard let entry = recentSuccessfulPairReply else {
            return nil
        }
        guard now() < entry.expiresAt else {
            recentSuccessfulPairReply = nil
            return nil
        }
        guard entry.request == request else {
            return nil
        }
        return entry.response
    }

    private func persistPairing(
        _ key: Data,
        expectedGeneration: UInt64
    ) -> UInt64? {
        guard pairingGeneration == expectedGeneration else {
            return nil
        }
        // A new pairing must not inherit an acknowledgement for an older
        // key. Clear it before installing the replacement active key.
        guard keyStore.clearDisconnectTombstone(),
              keyStore.save(key) else {
            return nil
        }
        // Consume the code as part of the successful key write. The AppModel
        // will install the next displayed code in its later MainActor callback,
        // but no second request can reuse this code in that interval.
        pairingGeneration &+= 1
        pairingCode = ""
        return pairingGeneration
    }
}

@MainActor
private final class SelectionHelperAppModel:
    ObservableObject
{
    static let shared = SelectionHelperAppModel()

    @Published private(set) var serverState:
        SelectionHelperServer.State = .starting
    @Published private(set) var isPaired = false
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairingResetError: String?
    @Published private(set) var accessibilityTrusted = false
    @Published var launchAtLogin = false

    private var server: SelectionHelperServer?
    func prepareForApplicationTermination() -> Bool { server?.prepareForNormalTermination() ?? true }
    private var pairingGeneration: UInt64 = 0

    private init() {
        pairingCode = Self.makePairingCode()
        isPaired = SelectionHelperKeyStore().load() != nil
        accessibilityTrusted = AXIsProcessTrusted()
        launchAtLogin =
            SMAppService.mainApp.status == .enabled
        let server = SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { [weak self] state in
                self?.serverState = state
            },
            pairingHandler: { [weak self] isPaired, generation in
                self?.applyPairingState(
                    isPaired,
                    generation: generation
                )
            }
        )
        self.server = server
        server.start()
    }

    func refreshPermission() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func retryServerIfFailed() {
        guard case .failed = serverState else { return }
        server?.retryIfFailed()
    }

    func requestPermission() {
        guard let lease = server?.beginUserOperation() else { return }
        defer { lease.release() }
        let options = [
            kAXTrustedCheckOptionPrompt
                .takeUnretainedValue() as String: true,
        ] as CFDictionary
        accessibilityTrusted =
            AXIsProcessTrustedWithOptions(options)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard let lease = server?.beginUserOperation() else { return }
        defer { lease.release() }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin =
                SMAppService.mainApp.status == .enabled
            return
        }
        launchAtLogin = enabled
    }

    func resetPairing() {
        let newPairingCode = Self.makePairingCode()
        guard let server else {
            pairingResetError = String(
                localized: "selectionHelper.pairing.reset.error"
            )
            return
        }
        switch server.resetPairing(newPairingCode) {
        case let .success(generation):
            pairingGeneration = generation
            pairingCode = newPairingCode
            isPaired = false
            pairingResetError = nil
        case .failure:
            // Keep the existing key, generation, code, and paired state so
            // the user can retry without creating a one-sided pairing.
            pairingResetError = String(
                localized: "selectionHelper.pairing.reset.error"
            )
        }
    }

    private func applyPairingState(
        _ isPaired: Bool,
        generation: UInt64
    ) {
        // Ignore a delayed pair callback after the user reset pairing.
        guard generation >= pairingGeneration else { return }
        pairingGeneration = generation
        self.isPaired = isPaired
        guard isPaired else { return }

        let newPairingCode = Self.makePairingCode()
        pairingCode = newPairingCode
        pairingGeneration = server?.updatePairingCode(newPairingCode)
            ?? pairingGeneration
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

private struct SelectionHelperContentView: View {
    @ObservedObject var model: SelectionHelperAppModel
    @State private var isResetPairingConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                String(localized: "selectionHelper.title"),
                systemImage: "text.cursor"
            )
            .font(.title2.weight(.semibold))

            Text(
                String(localized: "selectionHelper.detail")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox(String(localized: "selectionHelper.pairing")) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            model.isPaired
                                ? String(
                                    localized:
                                        "selectionHelper.pairing.paired"
                                )
                                : String(
                                    localized:
                                        "selectionHelper.pairing.code"
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !model.isPaired {
                            Text(model.pairingCode)
                                .font(
                                    .system(
                                        size: 28,
                                        weight: .semibold,
                                        design: .monospaced
                                    )
                                )
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Image(
                        systemName: model.isPaired
                            ? "checkmark.circle.fill"
                            : "link.badge.plus"
                    )
                    .foregroundStyle(
                        model.isPaired ? .green : .secondary
                    )
                }
                .padding(8)
            }

            Button(
                String(localized: "selectionHelper.pairing.reset"),
                role: .destructive
            ) {
                isResetPairingConfirmationPresented = true
            }
            .disabled(!model.isPaired)
            .accessibilityHint(
                String(
                    localized:
                        "selectionHelper.pairing.reset.accessibilityHint"
                )
            )

            Text(model.pairingResetError ?? " ")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2, reservesSpace: true)
                .accessibilityHidden(model.pairingResetError == nil)

            GroupBox(
                String(localized: "selectionHelper.accessibility")
            ) {
                HStack {
                    Text(
                        model.accessibilityTrusted
                            ? String(
                                localized:
                                    "selectionHelper.accessibility.ready"
                            )
                            : String(
                                localized:
                                    "selectionHelper.accessibility.permissionRequired"
                            )
                    )
                    Spacer()
                    if model.accessibilityTrusted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(
                            String(
                                localized:
                                    "selectionHelper.accessibility.request"
                            )
                        ) {
                            model.requestPermission()
                        }
                    }
                }
                .padding(8)
            }

            Toggle(
                String(localized: "selectionHelper.launchAtLogin"),
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )

            HStack {
                Text(serverStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "selectionHelper.recheck")) {
                    model.refreshPermission()
                    model.retryServerIfFailed()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            String(
                localized: "selectionHelper.pairing.reset.confirmation.title"
            ),
            isPresented: $isResetPairingConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    localized:
                        "selectionHelper.pairing.reset.confirmation.action"
                ),
                role: .destructive
            ) {
                model.resetPairing()
            }
            Button(
                String(
                    localized:
                        "selectionHelper.pairing.reset.confirmation.cancel"
                ),
                role: .cancel
            ) {}
        } message: {
            Text(
                String(
                    localized:
                        "selectionHelper.pairing.reset.confirmation.message"
                )
            )
        }
    }

    private var serverStatus: String {
        switch model.serverState {
        case .starting:
            String(localized: "selectionHelper.connection.starting")
        case .ready:
            model.isPaired
                ? String(localized: "selectionHelper.connection.paired")
                : String(localized: "selectionHelper.connection.waitingForPairing")
        case let .failed(message):
            String(
                format: String(
                    localized:
                        "selectionHelper.connection.failed"
                ),
                message
            )
        }
    }
}

@_spi(Testing) @MainActor
public final class SelectionHelperAppLifecycle {
    private let isRunningUnitTests: () -> Bool
    private let startServer: () -> Void
    private let presentWindow: () -> Void
    private var hasStartedServer = false

    @_spi(Testing) public init(
        isRunningUnitTests: @escaping () -> Bool,
        startServer: @escaping () -> Void,
        presentWindow: @escaping () -> Void
    ) {
        self.isRunningUnitTests = isRunningUnitTests
        self.startServer = startServer
        self.presentWindow = presentWindow
    }

    @_spi(Testing) public func applicationDidFinishLaunching() {
        guard !isRunningUnitTests(), !hasStartedServer else { return }
        hasStartedServer = true
        startServer()
    }

    @_spi(Testing) public func applicationDidBecomeActive() {
        guard !isRunningUnitTests() else { return }
        presentWindow()
    }

    @_spi(Testing) public func applicationShouldHandleReopen() -> Bool {
        guard !isRunningUnitTests() else { return false }
        presentWindow()
        return true
    }
}

@_spi(Testing) public enum SelectionHelperTestHost {
    private static let xctestEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto",
    ]

    @_spi(Testing) public static func isRunningUnitTests(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsXCTestMarkers: Bool = allowsDebugUnitTestOverride,
        allowsDebugOverride: Bool = allowsDebugUnitTestOverride
    ) -> Bool {
        // XCTest injects these into the application process when a test bundle
        // is hosted by this app. Check them before the scheme override, because
        // the override is not guaranteed to reach every hosted process.
        if allowsXCTestMarkers && xctestEnvironmentKeys.contains(
            where: { environment[$0]?.isEmpty == false }
        ) {
            return true
        }
        return allowsDebugOverride && environment["BLOCKS_UNIT_TESTING"] == "1"
    }

    @_spi(Testing) public static let allowsDebugUnitTestOverride: Bool = {
        #if DEBUG
        true
        #else
        // A production helper must not let an inherited environment variable
        // suppress its listener, accessibility checks, or login-item state.
        false
        #endif
    }()
}

@MainActor
private final class SelectionHelperAppDelegate: NSObject, NSApplicationDelegate {
    private lazy var model = SelectionHelperAppModel.shared
    private var windowController: NSWindowController?

    private var isRunningUnitTests: Bool {
        SelectionHelperTestHost.isRunningUnitTests()
    }

    private lazy var lifecycle = SelectionHelperAppLifecycle(
        isRunningUnitTests: { [weak self] in
            self?.isRunningUnitTests ?? true
        },
        startServer: { [weak self] in
            _ = self?.model
        },
        presentWindow: { [weak self] in
            self?.presentWindow()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycle.applicationDidFinishLaunching()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        lifecycle.applicationDidBecomeActive()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        lifecycle.applicationShouldHandleReopen()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningUnitTests else { return .terminateNow }
        return model.prepareForApplicationTermination() ? .terminateNow : .terminateCancel
    }

    private func presentWindow() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "selectionHelper.title")
        window.contentViewController = NSHostingController(
            rootView: SelectionHelperContentView(model: model)
        )
        window.center()

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        windowController.showWindow(nil)
    }
}

@main
private struct BlocksSelectionHelperApp: App {
    @NSApplicationDelegateAdaptor(SelectionHelperAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
