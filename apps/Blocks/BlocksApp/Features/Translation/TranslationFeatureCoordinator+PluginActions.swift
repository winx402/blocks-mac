import BlocksCore
import Foundation

extension TranslationFeatureCoordinator {
    func performPluginHostAction(
        _ actionID: String,
        context: BlocksPluginHostActionRegistry.Context,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        guard context.origin.userInitiated else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "translation.requires_user_initiated"
            )
        }
        guard let presenter = pluginTargetPresenter(
            input: input,
            expectedRevision: context.expectedRevision
        ), let snapshot = presenter.model.snapshot else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "translation_session_unavailable"
            )
        }
        let serviceID = input.string("service_id")
        if let serviceID,
           !snapshot.results.contains(where: { $0.service.id == serviceID }),
           actionID == "translation.cancel"
                || actionID == "translation.retry"
                || actionID == "translation.copy" {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "translation.service_unavailable"
            )
        }
        switch actionID {
        case "translation.cancel":
            if let serviceID {
                guard presenter.model.cancel(serviceID: serviceID) else {
                    throw BlocksPluginRuntimeError.invalidHostOperation(
                        "translation.service_state_changed"
                    )
                }
            } else {
                presenter.model.cancel()
            }
            return .bool(true)
        case "translation.retry":
            guard let serviceID else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "translation.retry:service_id"
                )
            }
            guard presenter.model.retry(serviceID: serviceID) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "translation.service_state_changed"
                )
            }
            return .bool(true)
        case "translation.favorite":
            return .bool(await presenter.model.favorite())
        case "translation.copy":
            let selectedResult: TranslationResultSnapshot?
            if let serviceID {
                selectedResult = snapshot.results.first {
                    $0.service.id == serviceID
                }
            } else {
                selectedResult = snapshot.results.first(where: \.isSuccessful)
            }
            guard let result = selectedResult else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "translation.copy:result_unavailable"
                )
            }
            let outcome = await commitTranslatedText(
                result.translatedText,
                model: presenter.model,
                expectedTranslationSessionID: snapshot.id,
                expectedRevision: context.expectedRevision
            )
            return .object([
                "copied": .bool(outcome != .failed),
                "history_recorded": .bool(outcome == .copiedAndRecorded),
            ])
        default:
            throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
        }
    }

    private func pluginTargetPresenter(
        input: [String: JSONValue],
        expectedRevision: Int64?
    ) -> TranslationPanelPresenter? {
        guard let rawPanelID = input.string("panel_id"),
              let panelID = UUID(uuidString: rawPanelID),
              let translationSessionID = input.string(
                  "translation_session_id"
              ),
              let presenter = presenters[panelID],
              presenter.id == panelID,
              presenter.model.acceptsPluginHostAction(
                  translationSessionID: translationSessionID,
                  expectedRevision: expectedRevision
              ) else {
            return nil
        }
        return presenter
    }
}
