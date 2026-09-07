import AppKit
import BlocksCore
import Foundation
import OSLog

enum TranslationCompatibilitySelectionFailure: Error {
    case targetUnavailable
    case snapshotUnavailable
    case copyEventUnavailable
    case selectionUnavailable
    case pasteboardChanged
    case restorationFailed
}

struct TranslationCompatibilitySelectionAuthorizationStore {
    private static let defaultsKey =
        "translation.selection.compatibility.allowedBundleIDs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAuthorized(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return authorizedBundleIdentifiers.contains(bundleIdentifier)
    }

    func authorize(bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return
        }
        var identifiers = authorizedBundleIdentifiers
        identifiers.insert(bundleIdentifier)
        defaults.set(
            identifiers.sorted(),
            forKey: Self.defaultsKey
        )
    }

    func revoke(bundleIdentifier: String) {
        var identifiers = authorizedBundleIdentifiers
        identifiers.remove(bundleIdentifier)
        defaults.set(
            identifiers.sorted(),
            forKey: Self.defaultsKey
        )
    }

    var authorizedBundleIdentifiers: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }
}

/// Performs the explicit, per-application compatibility fallback outside the
/// main thread's pasteboard path. The original pasteboard is captured and
/// restored by the recoverable Broker; if it cannot be reproduced exactly the
/// fallback is refused.
final class TranslationCompatibilitySelectionService:
    @unchecked Sendable
{
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationCompatibilitySelection"
    )

    private let broker: any ClipboardBrokerServing
    private let frontmostProcessIdentifier:
        @MainActor () -> pid_t?
    private let postCopyShortcut: @MainActor () -> Bool

    init(
        broker: any ClipboardBrokerServing =
            ClipboardBrokerClient.shared,
        frontmostProcessIdentifier:
            @escaping @MainActor () -> pid_t? = {
                NSWorkspace.shared.frontmostApplication?
                    .processIdentifier
            },
        postCopyShortcut:
            @escaping @MainActor () -> Bool = {
                guard let source = CGEventSource(
                    stateID: .hidSystemState
                ),
                      let keyDown = CGEvent(
                        keyboardEventSource: source,
                        virtualKey: 0x08,
                        keyDown: true
                      ),
                      let keyUp = CGEvent(
                        keyboardEventSource: source,
                        virtualKey: 0x08,
                        keyDown: false
                      ) else {
                    return false
                }
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                return true
            }
    ) {
        self.broker = broker
        self.frontmostProcessIdentifier =
            frontmostProcessIdentifier
        self.postCopyShortcut = postCopyShortcut
    }

    func capture(
        target: AXSelectionTarget,
        requestID: UUID
    ) async -> Result<String, TranslationCompatibilitySelectionFailure> {
        let startedAt = ContinuousClock.now
        do {
            guard !Task.isCancelled else {
                return .failure(.targetUnavailable)
            }
            guard await frontmostProcessIdentifier()
                == target.processIdentifier else {
                return .failure(.targetUnavailable)
            }
            let snapshot = try await broker.snapshot()
            guard !Task.isCancelled else {
                return .failure(.targetUnavailable)
            }
            guard snapshot.status == .captured else {
                Self.log(
                    requestID: requestID,
                    stage: "snapshot",
                    outcome: snapshot.status.rawValue,
                    startedAt: startedAt
                )
                return .failure(.snapshotUnavailable)
            }
            guard await postCopyShortcutIfCurrentTask(
                targetProcessIdentifier: target.processIdentifier
            ) else {
                return .failure(.copyEventUnavailable)
            }

            // Cmd-C is now an irreversible side effect. The bounded polling,
            // selection read, and restoration must not inherit cancellation
            // from the entry task: a cancelled Task.sleep otherwise returns
            // immediately and can miss a late pasteboard change. Await this
            // detached owner before returning so its cleanup cannot be lost.
            let selectionResult = await captureAndRestoreAfterCopy(
                snapshot: snapshot
            )
            Self.log(
                requestID: requestID,
                stage: "completed",
                outcome: selectionResult.isSuccess
                    ? "success"
                    : "selection_unavailable",
                startedAt: startedAt
            )
            return selectionResult
        } catch {
            Self.log(
                requestID: requestID,
                stage: "failed",
                outcome: String(describing: error),
                startedAt: startedAt
            )
            return .failure(.restorationFailed)
        }
    }

    /// The coordinator owns compatibility capture tasks on the MainActor and
    /// cancels them there when a panel closes or a newer entry replaces them.
    /// Keep the final focus check, cancellation admission, and Cmd-C side
    /// effect in one non-suspending MainActor section so such a cancellation
    /// cannot be interleaved between admission and the synthetic key event.
    @MainActor
    private func postCopyShortcutIfCurrentTask(
        targetProcessIdentifier: pid_t
    ) -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard frontmostProcessIdentifier() == targetProcessIdentifier else {
            return false
        }
        // Cancellation may be published from another executor while the
        // synchronous workspace lookup above is in progress. Re-admit at the
        // final side-effect boundary before posting the irreversible Cmd-C.
        guard !Task.isCancelled else {
            return false
        }
        return postCopyShortcut()
    }

    private func captureAndRestoreAfterCopy(
        snapshot: ClipboardBrokerSnapshotResult
    ) async -> Result<String, TranslationCompatibilitySelectionFailure> {
        let broker = broker
        return await Task.detached(priority: .userInitiated) {
            var copiedChangeCount: Int?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(40))
                guard let current = try? await broker.baseline() else {
                    continue
                }
                if current != snapshot.changeCount {
                    copiedChangeCount = current
                    break
                }
            }
            guard let copiedChangeCount else {
                return .failure(.selectionUnavailable)
            }
            await broker.suppressExternalChangeCounts([copiedChangeCount])

            let selectionResult:
                Result<String, TranslationCompatibilitySelectionFailure>
            do {
                let selection = try await broker.currentPlainText(
                    limit:
                        BlocksSelectionCaptureProtocol
                            .maximumSelectionCharacters
                )
                if selection.changeCount == copiedChangeCount,
                   let text = selection.text?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty,
                   !selection.truncated {
                    selectionResult = .success(text)
                } else {
                    selectionResult = .failure(.selectionUnavailable)
                }
            } catch {
                selectionResult = .failure(.selectionUnavailable)
            }

            let restoration = await Self.restore(
                broker: broker,
                snapshot: snapshot,
                expectedChangeCount: copiedChangeCount
            )
            if case let .failure(failure) = restoration {
                return .failure(failure)
            }
            return selectionResult
        }.value
    }

    private static func restore(
        broker: any ClipboardBrokerServing,
        snapshot: ClipboardBrokerSnapshotResult,
        expectedChangeCount: Int
    ) async -> Result<Void, TranslationCompatibilitySelectionFailure> {
        do {
            let lease = try await broker.write(
                ClipboardBrokerWriteRequest(
                    items: snapshot.items,
                    expectedChangeCount: expectedChangeCount
                )
            )
            return await broker.validate(lease)
                ? .success(())
                : .failure(.restorationFailed)
        } catch ClipboardBrokerClientError.writeChanged {
            return .failure(.pasteboardChanged)
        } catch {
            return .failure(.restorationFailed)
        }
    }

    private static func log(
        requestID: UUID,
        stage: String,
        outcome: String,
        startedAt: ContinuousClock.Instant
    ) {
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        let elapsedMilliseconds = max(
            0,
            Int(
                Double(components.seconds) * 1_000
                    + Double(components.attoseconds)
                        / 1_000_000_000_000_000
            )
        )
        logger.info(
            "request=\(requestID.uuidString, privacy: .public) stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public)"
        )
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

struct TranslationSelectionCaptureExecution {
    let id: UUID
    let entryID: UUID
    let request: AXSelectionReadRequest
    let readTask: Task<AXSelectionReadResult, Never>
    var panelID: UUID?
    var readDeliveryTask: Task<Void, Never>?

    func cancel() {
        request.cancel()
        readTask.cancel()
        readDeliveryTask?.cancel()
    }
}

extension TranslationFeatureCoordinator {
    /// Smart shortcut entry: the foreground target is frozen before any Blocks
    /// window is ordered front. AX remains the primary path; the coordinator
    /// may offer the user an explicitly authorized, per-app compatibility-copy
    /// fallback after AX has failed.
    func showSmartSelectionPanel() {
        guard distributionChannel.supportsSelectionHelper else {
            showManualPanel()
            feedbackPresenter.presentSelectionHelperUnsupported()
            return
        }
        let invocationID = beginEntry(source: .selection)
        selectionInvocationID = invocationID
        let target = selectionReader.captureFrontmostTarget()
        guard let target else {
            present(
                input: TranslationInput(source: .selection, text: ""),
                entryID: invocationID,
                shouldPresent: { [weak self] in
                    self?.isCurrentEntry(invocationID) == true
                        && self?.selectionInvocationID == invocationID
                }
            ) { model in
                guard self.selectionInvocationID == invocationID else {
                    return
                }
                self.selectionInvocationID = nil
                model.updateSelection(
                    .unavailable(
                        AXSelectionReadFailure(
                            reason: .noFrontmostApplication,
                            target: nil
                        )
                    )
                )
                self.presenters[model.id]?.focus()
                model.requestSourceFocus()
            }
            return
        }

        let executionID = UUID()
        let reader = selectionReader
        switch reader.freezeSelectionRequest(
            from: target,
            requestID: invocationID.uuidString
        ) {
        case let .unavailable(failure):
            presentSelectionFailure(
                failure,
                target: target,
                invocationID: invocationID
            )
        case let .ready(request):
            // The frozen token starts the Agent request before any Blocks
            // window is ordered front. Reading it is asynchronous, so the
            // skeleton can appear immediately without disturbing the source
            // application's selection.
            guard let admissionLease =
                TranslationApplicationOperationAdmission.gate.begin() else {
                request.cancel()
                selectionInvocationID = nil
                finishEntryPresentation(invocationID, outcome: "update-paused")
                return
            }
            let readTask = Task.detached(
                priority: .userInitiated
            ) {
                defer { admissionLease.release() }
                return reader.readSelection(from: request)
            }
            selectionCaptureExecution =
                TranslationSelectionCaptureExecution(
                    id: executionID,
                    entryID: invocationID,
                    request: request,
                    readTask: readTask,
                    panelID: nil,
                    readDeliveryTask: nil
                )
            presentSelectionSkeleton(
                target: target,
                invocationID: invocationID,
                executionID: executionID,
                readTask: readTask
            )
        }
    }

    private func presentSelectionFailure(
        _ failure: AXSelectionReadFailure,
        target: AXSelectionTarget,
        invocationID: UUID
    ) {
        let provisionalAnchor = AXSelectionReader.appKitMouseAnchor(
            target.accessibilityMouseLocation
        )
        present(
            input: TranslationInput(
                source: .selection,
                text: "",
                context: TranslationInputContext(
                    sourceApplicationBundleID: target.bundleIdentifier,
                    sourceApplicationName: target.applicationName,
                    anchor: provisionalAnchor
                )
            ),
            entryID: invocationID,
            shouldPresent: { [weak self] in
                self?.isCurrentEntry(invocationID) == true
                    && self?.selectionInvocationID == invocationID
            }
        ) { [weak self] model in
            guard let self,
                  selectionInvocationID == invocationID else {
                return
            }
            selectionInvocationID = nil
            selectionTargets[model.id] = target
            model.updateSelection(.unavailable(failure))
            configureCompatibilitySelectionIfNeeded(
                for: model,
                failure: failure
            )
            presenters[model.id]?.focus()
            model.requestSourceFocus()
            feedbackPresenter.recordSelectionFailureIfNeeded(failure)
        }
    }

    private func presentSelectionSkeleton(
        target: AXSelectionTarget,
        invocationID: UUID,
        executionID: UUID,
        readTask: Task<AXSelectionReadResult, Never>
    ) {
        let provisionalAnchor = AXSelectionReader.appKitMouseAnchor(
            target.accessibilityMouseLocation
        )
        present(
            input: TranslationInput(
                source: .selection,
                text: "",
                context: TranslationInputContext(
                    sourceApplicationBundleID: target.bundleIdentifier,
                    sourceApplicationName: target.applicationName,
                    anchor: provisionalAnchor
                )
            ),
            entryID: invocationID,
            shouldPresent: { [weak self] in
                self?.isCurrentEntry(invocationID) == true
                    && self?.selectionInvocationID == invocationID
                    && self?.selectionCaptureExecution?.id
                        == executionID
            }
        ) { [weak self] model in
            guard let self,
                  selectionInvocationID == invocationID,
                  selectionCaptureExecution?.id == executionID,
                  selectionCaptureExecution?.entryID == invocationID else {
                return
            }
            selectionCaptureExecution?.panelID = model.id
            let readDeliveryTask = Task { [weak self, weak model] in
                let result = await readTask.value
                guard !Task.isCancelled,
                      let self,
                      let model,
                      isCurrentEntry(invocationID),
                      selectionInvocationID == invocationID,
                      selectionCaptureExecution?.id == executionID,
                      selectionCaptureExecution?.entryID == invocationID,
                      selectionCaptureExecution?.panelID == model.id,
                      presenters[model.id] != nil else {
                    return
                }
                selectionCaptureExecution = nil
                selectionInvocationID = nil
                selectionTargets[model.id] = target
                model.updateSelection(result)
                switch result {
                case .selected:
                    break
                case let .unavailable(failure):
                    configureCompatibilitySelectionIfNeeded(
                        for: model,
                        failure: failure
                    )
                    feedbackPresenter.recordSelectionFailureIfNeeded(
                        failure
                    )
                }
                presenters[model.id]?.focus()
                model.requestSourceFocus()
            }
            selectionCaptureExecution?.readDeliveryTask =
                readDeliveryTask
        }
    }

    func showManualPanel() {
        let entryID = beginEntry(source: .manual)
        present(
            input: TranslationInput(source: .manual, text: ""),
            entryID: entryID
        )
    }

    private func configureCompatibilitySelectionIfNeeded(
        for model: TranslationPanelSessionModel,
        failure: AXSelectionReadFailure
    ) {
        guard Self.compatibilitySelectionEligible(
            failure.reason
        ),
              let target = failure.target
                ?? selectionTargets[model.id] else {
            return
        }
        selectionTargets[model.id] = target

        // `NSPasteboard.changeCount` cannot prove which process produced a
        // change. An unrelated clipboard writer can race the synthetic Cmd-C,
        // so even a previously authorized application must stay on the
        // focused manual-input fallback instead of treating clipboard text as
        // the selected source and potentially sending it to a translation
        // service. Historical grants remain revocable in Settings, but they
        // no longer authorize an unverifiable automatic capture.
    }

    func startCompatibilitySelection(
        for model: TranslationPanelSessionModel,
        grantsAuthorization: Bool
    ) {
        guard let target = selectionTargets[model.id] else {
            model.updateSelection(
                .unavailable(
                    AXSelectionReadFailure(
                        reason: .targetExited,
                        target: nil
                    )
                )
            )
            return
        }
        if grantsAuthorization {
            compatibilitySelectionAuthorizationStore.authorize(
                bundleIdentifier: target.bundleIdentifier
            )
        } else {
            guard compatibilitySelectionAuthorizationStore
                .isAuthorized(
                    bundleIdentifier:
                        target.bundleIdentifier
                ) else {
                return
            }
        }

        compatibilitySelectionTasks[model.id]?.cancel()
        model.beginCompatibilitySelection()
        let requestID = UUID()
        let service = compatibilitySelectionService
        guard let task = TranslationApplicationOperationAdmission.gate.task({
            [weak self, weak model] in
            let result = await service.capture(
                target: target,
                requestID: requestID
            )
            guard !Task.isCancelled,
                  let self,
                  let model,
                  selectionTargets[model.id] == target else {
                return
            }
            compatibilitySelectionTasks[model.id] = nil
            switch result {
            case let .success(text):
                model.updateSelection(
                    .selected(
                        AXSelectionSnapshot(
                            target: target,
                            focusedElement:
                                AXSelectionFocusedElementIdentity(
                                    role: nil,
                                    subrole: nil,
                                    identifier: nil,
                                    domIdentifier: nil,
                                    chromeNodeIdentifier: nil
                                ),
                            selectedText: text,
                            selectedRange: nil,
                            captureStrategy:
                                .focusedWindowDocument,
                            candidateDepth: 0,
                            screenBounds: nil,
                            capturedAt: Date()
                        )
                    )
                )
                presenters[model.id]?.focus()
                model.requestSourceFocus()
            case .failure:
                model.updateSelection(
                    .unavailable(
                        AXSelectionReadFailure(
                            reason: .selectionUnavailable,
                            target: target
                        )
                    )
                )
                presenters[model.id]?.focus()
                model.requestSourceFocus()
            }
        }) else {
            return
        }
        compatibilitySelectionTasks[model.id] = task
    }

    private static func compatibilitySelectionEligible(
        _ reason: AXSelectionReadFailureReason
    ) -> Bool {
        switch reason {
        case .focusedElementUnavailable,
             .selectionUnavailable,
             .emptySelection,
             .timedOut:
            true
        case .noFrontmostApplication,
             .blocksIsFrontmost,
             .accessibilityPermissionDenied,
             .agentUnavailable,
             .agentInstallationConflict,
             .agentRequiresApproval,
             .agentVersionOutdated,
             .agentConnectionFailed,
             .targetExited,
             .cancelled,
             .selectionTooLarge,
             .passwordField:
            false
        }
    }
}
