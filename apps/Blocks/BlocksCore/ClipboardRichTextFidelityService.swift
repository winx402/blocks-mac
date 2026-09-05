import Foundation

public struct ClipboardRichTextFidelityEvidence: Equatable {
    public let linkPreserved: Bool
    public let paragraphsPreserved: Bool
    public let inlineStylePreserved: Bool
    public let listRepresentationPreserved: Bool
    public let kindRemainsRichText: Bool
    public let plainTextDerivationUpdated: Bool

    public var passed: Bool {
        linkPreserved
            && paragraphsPreserved
            && inlineStylePreserved
            && listRepresentationPreserved
            && kindRemainsRichText
            && plainTextDerivationUpdated
    }
}

public struct ClipboardRichTextFidelityResult {
    public let payload: ClipboardRecorderPayload?
    public let evidence: ClipboardRichTextFidelityEvidence

    public var passed: Bool {
        payload != nil && evidence.passed
    }
}

public struct ClipboardRichTextFidelityService {
    public init() {}

    public func updatedPayload(
        original payload: ClipboardRecorderPayload,
        draftText: String
    ) -> ClipboardRichTextFidelityResult {
        guard payload.kind == .richText,
              let data = payload.rtfData,
              let originalRTF = String(data: data, encoding: .utf8),
              originalRTF.localizedCaseInsensitiveContains("\\rtf"),
              isStructurallyValidRTF(originalRTF),
              let originalPlainText = payload.text else {
            return failureEvidence(payload: nil)
        }

        guard let updatedRTF = updatedRTF(
            originalRTF: originalRTF,
            originalPlainText: originalPlainText,
            draftText: draftText
        ) else {
            return failureEvidence(payload: nil)
        }
        let rtfData = Data(updatedRTF.utf8)

        let output = ClipboardRecorderPayload(
            recordID: payload.recordID,
            kind: .richText,
            text: draftText,
            rtfData: rtfData
        )
        let evidence = ClipboardRichTextFidelityEvidence(
            linkPreserved: linkPreserved(originalRTF: originalRTF, updatedRTF: updatedRTF),
            paragraphsPreserved: paragraphShapePreserved(original: originalPlainText, updatedRTF: updatedRTF),
            inlineStylePreserved: inlineAttributesPreserved(originalRTF: originalRTF, updatedRTF: updatedRTF),
            listRepresentationPreserved: listRepresentationPreserved(original: originalPlainText, originalRTF: originalRTF, updated: draftText, updatedRTF: updatedRTF),
            kindRemainsRichText: output.kind == .richText,
            plainTextDerivationUpdated: output.text == draftText
        )
        guard evidence.passed else {
            return ClipboardRichTextFidelityResult(payload: nil, evidence: evidence)
        }
        return ClipboardRichTextFidelityResult(payload: output, evidence: evidence)
    }

    private func updatedRTF(
        originalRTF: String,
        originalPlainText: String,
        draftText: String
    ) -> String? {
        let originalLines = originalPlainText.components(separatedBy: .newlines)
        let draftLines = draftText.components(separatedBy: .newlines)
        guard originalLines.count == draftLines.count else {
            return nil
        }
        var updated = originalRTF
        for index in originalLines.indices {
            let originalLine = originalLines[index]
            let replacementLine = rtfVisibleReplacement(draftLines[index], originalLine: originalLine)
            guard replaceRTFVisibleText(
                originalLine,
                with: replacementLine,
                in: &updated
            ) else {
                return nil
            }
        }
        return updated
    }

    private func isStructurallyValidRTF(_ value: String) -> Bool {
        var depth = 0
        var previousWasEscape = false
        var sawRTFControl = false
        for character in value {
            if previousWasEscape {
                if character == "r" {
                    sawRTFControl = value.localizedCaseInsensitiveContains("\\rtf")
                }
                previousWasEscape = false
                continue
            }
            if character == "\\" {
                previousWasEscape = true
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 {
                    return false
                }
            }
        }
        return depth == 0 && sawRTFControl
    }

    private func replaceRTFVisibleText(_ originalLine: String, with replacementLine: String, in rtf: inout String) -> Bool {
        let candidates = replacementCandidates(for: originalLine)
        for candidate in candidates where !candidate.isEmpty {
            let escapedCandidate = escapeRTF(candidate)
            guard rtf.contains(escapedCandidate) else {
                continue
            }
            rtf = rtf.replacingOccurrences(
                of: escapedCandidate,
                with: escapeRTF(replacementLine)
            )
            return true
        }
        return originalLine.isEmpty
    }

    private func replacementCandidates(for originalLine: String) -> [String] {
        var candidates = [originalLine]
        let trimmed = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("•") {
            candidates.append(
                trimmed
                    .dropFirst()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if trimmed.hasPrefix("-") {
            candidates.append(
                trimmed
                    .dropFirst()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Array(Set(candidates))
    }

    private func rtfVisibleReplacement(_ draftLine: String, originalLine: String) -> String {
        let originalTrimmed = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftTrimmed = draftLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if originalTrimmed.hasPrefix("•"), draftTrimmed.hasPrefix("•") {
            return String(draftTrimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if originalTrimmed.hasPrefix("-"), draftTrimmed.hasPrefix("-") {
            return String(draftTrimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draftLine
    }

    private func linkPreserved(originalRTF: String, updatedRTF: String) -> Bool {
        let originalHasLink = originalRTF.localizedCaseInsensitiveContains("HYPERLINK")
            || originalRTF.localizedCaseInsensitiveContains("\\field")
        return !originalHasLink || updatedRTF.localizedCaseInsensitiveContains("HYPERLINK")
            || updatedRTF.localizedCaseInsensitiveContains("\\field")
    }

    private func paragraphShapePreserved(original: String, updatedRTF: String) -> Bool {
        let originalParagraphCount = original.components(separatedBy: .newlines).count
        return originalParagraphCount <= 1 || updatedRTF.contains("\\par") || updatedRTF.contains("\\\n")
    }

    private func inlineAttributesPreserved(originalRTF: String, updatedRTF: String) -> Bool {
        let originalHasInlineAttributes = originalRTF.contains("\\b")
            || originalRTF.contains("\\i")
            || originalRTF.contains("\\ul")
            || originalRTF.contains("\\strike")
        return !originalHasInlineAttributes
            || updatedRTF.contains("\\b")
            || updatedRTF.contains("\\i")
            || updatedRTF.contains("\\ul")
            || updatedRTF.contains("\\strike")
    }

    private func listRepresentationPreserved(
        original: String,
        originalRTF: String,
        updated: String,
        updatedRTF: String
    ) -> Bool {
        let originalHasList = original.contains("•")
            || originalRTF.localizedCaseInsensitiveContains("list")
            || originalRTF.contains("\\bullet")
        return !originalHasList
            || updated.contains("•")
            || updatedRTF.contains("\\bullet")
            || updatedRTF.contains("\\'95")
    }

    private func escapeRTF(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    private func failureEvidence(payload: ClipboardRecorderPayload?) -> ClipboardRichTextFidelityResult {
        ClipboardRichTextFidelityResult(
            payload: payload,
            evidence: ClipboardRichTextFidelityEvidence(
                linkPreserved: false,
                paragraphsPreserved: false,
                inlineStylePreserved: false,
                listRepresentationPreserved: false,
                kindRemainsRichText: payload?.kind == .richText,
                plainTextDerivationUpdated: false
            )
        )
    }
}
