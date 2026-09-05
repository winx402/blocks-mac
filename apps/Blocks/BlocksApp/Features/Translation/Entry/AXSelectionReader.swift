import AppKit
import ApplicationServices
import BlocksCore
import Foundation
import OSLog

struct AXSelectionTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    /// Quartz/Accessibility global coordinates, whose origin is the
    /// upper-left of the main display. This is captured before Blocks
    /// presents any window so static web/document selections can be hit-tested.
    let accessibilityMouseLocation: CGPoint?
    let capturedAt: Date

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        accessibilityMouseLocation: CGPoint? = nil,
        capturedAt: Date
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.accessibilityMouseLocation = accessibilityMouseLocation
        self.capturedAt = capturedAt
    }
}

struct AXSelectionFocusedElementIdentity:
    Equatable,
    Sendable
{
    let role: String?
    let subrole: String?
    let identifier: String?
    let domIdentifier: String?
    let chromeNodeIdentifier: String?
}

struct AXSelectionElementSnapshot:
    Equatable,
    Sendable
{
    let focusedElement: AXSelectionFocusedElementIdentity
    let selectedText: String?
    let selectedRange: NSRange?
    let captureStrategy: SelectionAgentCaptureStrategy
    let candidateDepth: Int
    /// Accessibility uses a top-left global coordinate space. The reader
    /// converts this rect before exposing a successful selection.
    let accessibilityScreenBounds: CGRect?

    init(
        role: String?,
        subrole: String?,
        identifier: String? = nil,
        domIdentifier: String? = nil,
        chromeNodeIdentifier: String? = nil,
        selectedText: String?,
        selectedRange: NSRange?,
        captureStrategy: SelectionAgentCaptureStrategy = .focusedElement,
        candidateDepth: Int = 0,
        accessibilityScreenBounds: CGRect?
    ) {
        focusedElement = AXSelectionFocusedElementIdentity(
            role: role,
            subrole: subrole,
            identifier: identifier,
            domIdentifier: domIdentifier,
            chromeNodeIdentifier: chromeNodeIdentifier
        )
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.captureStrategy = captureStrategy
        self.candidateDepth = candidateDepth
        self.accessibilityScreenBounds =
            accessibilityScreenBounds
    }

    var role: String? { focusedElement.role }
    var subrole: String? { focusedElement.subrole }
}

struct AXSelectionSnapshot: Equatable, Sendable {
    let target: AXSelectionTarget
    let focusedElement: AXSelectionFocusedElementIdentity
    let selectedText: String
    let selectedRange: NSRange?
    let captureStrategy: SelectionAgentCaptureStrategy
    let candidateDepth: Int
    let screenBounds: CGRect?
    let capturedAt: Date

    var focusedRole: String? { focusedElement.role }
    var focusedSubrole: String? { focusedElement.subrole }
}

enum AXSelectionReadFailureReason:
    String,
    Equatable,
    Sendable
{
    case noFrontmostApplication
    case blocksIsFrontmost
    case accessibilityPermissionDenied
    case agentUnavailable
    case agentInstallationConflict
    case agentRequiresApproval
    case agentVersionOutdated
    case agentConnectionFailed
    case targetExited
    case timedOut
    case cancelled
    case selectionTooLarge
    case focusedElementUnavailable
    case passwordField
    case selectionUnavailable
    case emptySelection
}

struct AXSelectionReadFailure: Equatable, Sendable {
    let reason: AXSelectionReadFailureReason
    let target: AXSelectionTarget?
}

enum AXSelectionReadResult: Equatable, Sendable {
    case selected(AXSelectionSnapshot)
    case unavailable(AXSelectionReadFailure)
}

enum AXSelectionElementReadResult: Equatable, Sendable {
    case element(AXSelectionElementSnapshot)
    case unavailable
    case failure(AXSelectionReadFailureReason)
}

/// Represents one frozen selection request. In Direct builds the token owns
/// an Agent request ID rather than an AXUIElement, so cancellation can cross
/// the process boundary without exposing Accessibility to the main App.
final class AXSelectionElementReadToken:
    @unchecked Sendable
{
    private let reader: () -> AXSelectionElementReadResult
    private let canceller: () -> Void

    init(
        reader: @escaping () -> AXSelectionElementReadResult,
        canceller: @escaping () -> Void = {}
    ) {
        self.reader = reader
        self.canceller = canceller
    }

    func read() -> AXSelectionElementReadResult {
        reader()
    }

    func cancel() {
        canceller()
    }
}

protocol AXSelectionSystemClient {
    var accessibilityTrusted: Bool { get }
    var defersAccessibilityTrustEvaluation: Bool { get }
    func requestAccessibilityPermission()
    func readSelection(
        from target: AXSelectionTarget
    ) -> AXSelectionElementReadResult
    func freezeSelection(
        from target: AXSelectionTarget,
        requestID: String
    ) -> AXSelectionElementReadToken?
}

extension AXSelectionSystemClient {
    var defersAccessibilityTrustEvaluation: Bool {
        false
    }

    func requestAccessibilityPermission() {}
}

struct AXSelectionReadRequest: @unchecked Sendable {
    let id: String
    let target: AXSelectionTarget
    fileprivate let token: AXSelectionElementReadToken

    func cancel() {
        token.cancel()
    }
}

enum AXSelectionReadRequestResult: Sendable {
    case ready(AXSelectionReadRequest)
    case unavailable(AXSelectionReadFailure)
}

/// The main App only resolves the foreground process and consumes the
/// Selection Helper response. Any explicitly authorized compatibility-copy
/// fallback is coordinated by the translation feature, outside this reader.
final class AXSelectionReader: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationSelectionEntry"
    )
    private let systemClient: any AXSelectionSystemClient
    private let ownBundleIdentifier: String?
    private let frontmostTargetProvider:
        @MainActor () -> AXSelectionTarget?
    private let screenBoundsConverter: (CGRect) -> CGRect
    private let now: () -> Date

    init(
        systemClient: any AXSelectionSystemClient =
            SelectionHelperAXSelectionSystemClient(),
        ownBundleIdentifier: String? =
            Bundle.main.bundleIdentifier,
        frontmostTargetProvider:
            @escaping @MainActor () -> AXSelectionTarget? = {
                guard let application =
                    NSWorkspace.shared.frontmostApplication,
                      !application.isTerminated else {
                    return nil
                }
                return AXSelectionTarget(
                    processIdentifier:
                        application.processIdentifier,
                    bundleIdentifier:
                        application.bundleIdentifier,
                    applicationName:
                        application.localizedName
                        ?? application.bundleIdentifier
                        ?? "Unknown",
                    accessibilityMouseLocation:
                        CGEvent(source: nil)?.location,
                    capturedAt: Date()
                )
            },
        screenBoundsConverter:
            @escaping (CGRect) -> CGRect =
                AXSelectionReader.appKitScreenRect,
        now: @escaping () -> Date = Date.init
    ) {
        self.systemClient = systemClient
        self.ownBundleIdentifier = ownBundleIdentifier
        self.frontmostTargetProvider =
            frontmostTargetProvider
        self.screenBoundsConverter =
            screenBoundsConverter
        self.now = now
    }

    @MainActor
    func captureFrontmostTarget() -> AXSelectionTarget? {
        frontmostTargetProvider()
    }

    @MainActor
    func readFrontmostSelection()
        -> AXSelectionReadResult {
        guard let target = captureFrontmostTarget() else {
            return .unavailable(AXSelectionReadFailure(
                reason: .noFrontmostApplication,
                target: nil
            ))
        }
        return readSelection(from: target)
    }

    func readSelection(
        from target: AXSelectionTarget
    ) -> AXSelectionReadResult {
        switch freezeSelectionRequest(
            from: target,
            requestID: UUID().uuidString
        ) {
        case let .ready(request):
            return readSelection(from: request)
        case let .unavailable(failure):
            return .unavailable(failure)
        }
    }

    func freezeSelectionRequest(
        from target: AXSelectionTarget,
        requestID: String = UUID().uuidString
    ) -> AXSelectionReadRequestResult {
        Self.logger.info(
            "request=\(requestID, privacy: .public) stage=freeze pid=\(target.processIdentifier, privacy: .public) bundle=\(target.bundleIdentifier ?? "unknown", privacy: .public) hasMouse=\(target.accessibilityMouseLocation != nil, privacy: .public)"
        )
        if let ownBundleIdentifier,
           target.bundleIdentifier == ownBundleIdentifier {
            return .unavailable(AXSelectionReadFailure(
                reason: .blocksIsFrontmost,
                target: target
            ))
        }
        guard systemClient
            .defersAccessibilityTrustEvaluation
            || systemClient.accessibilityTrusted else {
            return .unavailable(AXSelectionReadFailure(
                reason: .accessibilityPermissionDenied,
                target: target
            ))
        }
        guard let token =
            systemClient.freezeSelection(
                from: target,
                requestID: requestID
            ) else {
            return .unavailable(AXSelectionReadFailure(
                reason: .focusedElementUnavailable,
                target: target
            ))
        }
        return .ready(AXSelectionReadRequest(
            id: requestID,
            target: target,
            token: token
        ))
    }

    func readSelection(
        from request: AXSelectionReadRequest
    ) -> AXSelectionReadResult {
        let target = request.target
        let element: AXSelectionElementSnapshot
        switch request.token.read() {
        case let .element(snapshot):
            element = snapshot
        case let .failure(reason):
            Self.logger.info(
                "request=\(request.id, privacy: .public) stage=result outcome=\(reason.rawValue, privacy: .public)"
            )
            return .unavailable(AXSelectionReadFailure(
                reason: reason,
                target: target
            ))
        case .unavailable:
            return .unavailable(AXSelectionReadFailure(
                reason: .focusedElementUnavailable,
                target: target
            ))
        }
        if element.subrole
            == kAXSecureTextFieldSubrole as String {
            return .unavailable(AXSelectionReadFailure(
                reason: .passwordField,
                target: target
            ))
        }
        guard let selectedText = element.selectedText else {
            return .unavailable(AXSelectionReadFailure(
                reason: .selectionUnavailable,
                target: target
            ))
        }
        guard !selectedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return .unavailable(AXSelectionReadFailure(
                reason: .emptySelection,
                target: target
            ))
        }

        return .selected(AXSelectionSnapshot(
            target: target,
            focusedElement: element.focusedElement,
            selectedText: selectedText,
            selectedRange: element.selectedRange,
            captureStrategy: element.captureStrategy,
            candidateDepth: element.candidateDepth,
            screenBounds:
                element.accessibilityScreenBounds.map(
                    screenBoundsConverter
                ),
            capturedAt: now()
        ))
    }

    func requestAccessibilityPermission() {
        systemClient.requestAccessibilityPermission()
    }

    static func appKitScreenRect(
        _ accessibilityRect: CGRect
    ) -> CGRect {
        guard !accessibilityRect.isNull,
              !accessibilityRect.isInfinite else {
            return accessibilityRect
        }
        let primaryDisplayBounds = CGDisplayBounds(
            CGMainDisplayID()
        )
        guard !primaryDisplayBounds.isNull,
              !primaryDisplayBounds.isInfinite else {
            return accessibilityRect
        }
        return CGRect(
            x: accessibilityRect.minX,
            y: primaryDisplayBounds.maxY
                - accessibilityRect.maxY,
            width: accessibilityRect.width,
            height: accessibilityRect.height
        )
    }

    static func appKitMouseAnchor(
        _ accessibilityLocation: CGPoint?
    ) -> TranslationInputAnchor? {
        guard let accessibilityLocation,
              accessibilityLocation.x.isFinite,
              accessibilityLocation.y.isFinite else {
            return nil
        }
        let screenRect = appKitScreenRect(
            CGRect(
                x: accessibilityLocation.x,
                y: accessibilityLocation.y,
                width: 1,
                height: 1
            )
        )
        return TranslationInputAnchor(screenRect: screenRect)
    }
}
