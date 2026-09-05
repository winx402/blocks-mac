import Foundation

enum AICapabilityDomain: String, Codable {
    case llm
    case translation
    case ocr
}

enum AICapabilityExecutionMode: String, Codable {
    case localMock = "local_mock"
    case openAICompatible = "openai_compatible"
    case liteLLMGateway = "litellm_gateway"
    case localCLI = "local_cli"
    case llmBacked = "llm_backed"
    case dedicatedAPI = "dedicated_api"
    case appleVision = "apple_vision"
    case multimodalLLM = "multimodal_llm"
    case cloudOCR = "cloud_ocr"
}

struct AICapabilityProfile: Identifiable, Equatable {
    let id: String
    let domain: AICapabilityDomain
    let executionMode: AICapabilityExecutionMode
    let nameKey: String
    let summaryKey: String
    let capabilityTags: [String]
    let configured: Bool
    let implemented: Bool
    let localOnly: Bool
    let requiresKeychainSecret: Bool
    let requiresExternalTransfer: Bool

    var localizedName: String {
        L10n.string(nameKey)
    }

    var localizedSummary: String {
        L10n.string(summaryKey)
    }

    var boundaryTags: [String] {
        var tags = [localOnly ? L10n.string("settings.aiCapabilityLocalOnly") : L10n.string("settings.aiCapabilityExternalTransfer")]
        if !implemented {
            tags.append(L10n.string("settings.aiCapabilityNotImplemented"))
        }
        return tags
    }
}

struct LLMProviderProfile: Identifiable, Equatable {
    let base: AICapabilityProfile

    var id: String { base.id }
    var localizedName: String { base.localizedName }
    var localizedSummary: String { base.localizedSummary }
    var boundaryTags: [String] { base.boundaryTags }

    static func defaults() -> [LLMProviderProfile] {
        [
            LLMProviderProfile(
                base: AICapabilityProfile(
                    id: "llm-mock-local",
                    domain: .llm,
                    executionMode: .localMock,
                    nameKey: "aiCapability.llm.mock.name",
                    summaryKey: "aiCapability.llm.mock.summary",
                    capabilityTags: ["text", "structured-preview"],
                    configured: true,
                    implemented: true,
                    localOnly: true,
                    requiresKeychainSecret: false,
                    requiresExternalTransfer: false
                )
            ),
            LLMProviderProfile(
                base: AICapabilityProfile(
                    id: "llm-openai-compatible-placeholder",
                    domain: .llm,
                    executionMode: .openAICompatible,
                    nameKey: "aiCapability.llm.openAICompatible.name",
                    summaryKey: "aiCapability.llm.openAICompatible.summary",
                    capabilityTags: ["OpenAI-compatible", "text", "vision", "structured-output"],
                    configured: false,
                    implemented: false,
                    localOnly: false,
                    requiresKeychainSecret: true,
                    requiresExternalTransfer: true
                )
            ),
            LLMProviderProfile(
                base: AICapabilityProfile(
                    id: "llm-litellm-gateway-placeholder",
                    domain: .llm,
                    executionMode: .liteLLMGateway,
                    nameKey: "aiCapability.llm.liteLLMGateway.name",
                    summaryKey: "aiCapability.llm.liteLLMGateway.summary",
                    capabilityTags: ["LiteLLM", "gateway", "OpenAI-compatible"],
                    configured: false,
                    implemented: false,
                    localOnly: false,
                    requiresKeychainSecret: true,
                    requiresExternalTransfer: true
                )
            ),
            LLMProviderProfile(
                base: AICapabilityProfile(
                    id: "llm-local-cli-placeholder",
                    domain: .llm,
                    executionMode: .localCLI,
                    nameKey: "aiCapability.llm.localCLI.name",
                    summaryKey: "aiCapability.llm.localCLI.summary",
                    capabilityTags: ["CLI", "agent", "json-output"],
                    configured: false,
                    implemented: false,
                    localOnly: false,
                    requiresKeychainSecret: false,
                    requiresExternalTransfer: true
                )
            )
        ]
    }
}

struct OCREngineProfile: Identifiable, Equatable {
    let base: AICapabilityProfile
    let backedByLLMProviderID: String?

    var id: String { base.id }
    var localizedName: String { base.localizedName }
    var localizedSummary: String { base.localizedSummary }
    var boundaryTags: [String] { base.boundaryTags }

    static func defaults(defaultLLMProviderID: String) -> [OCREngineProfile] {
        [
            OCREngineProfile(
                base: AICapabilityProfile(
                    id: "ocr-mock-local",
                    domain: .ocr,
                    executionMode: .localMock,
                    nameKey: "aiCapability.ocr.mock.name",
                    summaryKey: "aiCapability.ocr.mock.summary",
                    capabilityTags: ["ocr", "local-preview"],
                    configured: true,
                    implemented: true,
                    localOnly: true,
                    requiresKeychainSecret: false,
                    requiresExternalTransfer: false
                ),
                backedByLLMProviderID: nil
            ),
            OCREngineProfile(
                base: AICapabilityProfile(
                    id: "ocr-apple-vision-placeholder",
                    domain: .ocr,
                    executionMode: .appleVision,
                    nameKey: "aiCapability.ocr.appleVision.name",
                    summaryKey: "aiCapability.ocr.appleVision.summary",
                    capabilityTags: ["Apple Vision", "local-ocr"],
                    configured: false,
                    implemented: false,
                    localOnly: true,
                    requiresKeychainSecret: false,
                    requiresExternalTransfer: false
                ),
                backedByLLMProviderID: nil
            ),
            OCREngineProfile(
                base: AICapabilityProfile(
                    id: "ocr-multimodal-llm-placeholder",
                    domain: .ocr,
                    executionMode: .multimodalLLM,
                    nameKey: "aiCapability.ocr.multimodalLLM.name",
                    summaryKey: "aiCapability.ocr.multimodalLLM.summary",
                    capabilityTags: ["vision", "LLM-backed"],
                    configured: false,
                    implemented: false,
                    localOnly: false,
                    requiresKeychainSecret: true,
                    requiresExternalTransfer: true
                ),
                backedByLLMProviderID: defaultLLMProviderID
            ),
            OCREngineProfile(
                base: AICapabilityProfile(
                    id: "ocr-cloud-placeholder",
                    domain: .ocr,
                    executionMode: .cloudOCR,
                    nameKey: "aiCapability.ocr.cloud.name",
                    summaryKey: "aiCapability.ocr.cloud.summary",
                    capabilityTags: ["cloud-ocr", "dedicated-api"],
                    configured: false,
                    implemented: false,
                    localOnly: false,
                    requiresKeychainSecret: true,
                    requiresExternalTransfer: true
                ),
                backedByLLMProviderID: nil
            )
        ]
    }
}

struct AICapabilityCatalog {
    let llmProviders: [LLMProviderProfile]
    let ocrEngines: [OCREngineProfile]

    static func defaults() -> AICapabilityCatalog {
        let llmProviders = LLMProviderProfile.defaults()
        let defaultLLMProviderID = llmProviders[0].id
        return AICapabilityCatalog(
            llmProviders: llmProviders,
            ocrEngines: OCREngineProfile.defaults(defaultLLMProviderID: defaultLLMProviderID)
        )
    }
}
