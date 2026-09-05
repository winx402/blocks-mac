import BlocksCore
import SwiftUI

struct ClipboardRecordContextMenu: View {
    let record: ClipboardRecorderRecord
    let ocrState: ClipboardOCRState
    let tagStore: ClipboardTagStore
    let onPaste: () -> Void
    let onTranslate: () -> Void
    let onRetryOCR: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleTag: (String) -> Void
    let onCreateTag: (String) -> Void
    let onCopyPlainText: () -> Void
    let onRemove: () -> Void
    let pluginActions: AnyView?

    var body: some View {
        Button(action: onPaste) {
            Label(L10n.string("clipboard.context.paste"), systemImage: "cursorarrow.click.2")
        }
        .disabled(!record.restorable)

        Button(action: onTranslate) {
            Label(
                L10n.string("translation.clipboard.action"),
                systemImage: "character.book.closed"
            )
        }
        .disabled(record.excluded || record.kind == .image)

        Button(action: onCopyPlainText) {
            Label(L10n.string("clipboard.context.copyPlainText"), systemImage: "textformat")
        }
        .disabled(record.excluded)

        if record.kind == .image, ocrState == .failed {
            Button(action: onRetryOCR) {
                Label(L10n.string("clipboard.ocr.retry"), systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Button(action: onToggleFavorite) {
            Label(
                tagStore.isFavorite(recordID: record.id)
                    ? L10n.string("clipboard.tags.unfavorite")
                    : L10n.string("clipboard.tags.favorite"),
                systemImage: tagStore.isFavorite(recordID: record.id) ? "star.slash" : "star"
            )
        }

        ClipboardTagMenu(
            recordID: record.id,
            tagStore: tagStore,
            toggleTag: onToggleTag,
            createTag: onCreateTag
        )

        if let pluginActions {
            Divider()
            pluginActions
        }

        Divider()

        Button(role: .destructive, action: onRemove) {
            Label(L10n.string("clipboard.deleteHistoryItem"), systemImage: "trash")
        }
    }

}

private struct ClipboardTagMenu: View {
    private static var defaultQuickTagName: String {
        L10n.string("clipboard.tags.defaultName")
    }

    let recordID: String
    let tagStore: ClipboardTagStore
    let toggleTag: (String) -> Void
    let createTag: (String) -> Void

    var body: some View {
        Menu {
            ForEach(tagStore.tagsForFilter.filter { !$0.isBuiltIn }) { tag in
                Button {
                    toggleTag(tag.id)
                } label: {
                    Label(
                        tag.localizedDisplayName,
                        systemImage: tagStore.isTagged(recordID: recordID, tagID: tag.id) ? "checkmark.circle.fill" : "tag"
                    )
                }
            }

            Divider()

            Button {
                createTag(Self.defaultQuickTagName)
            } label: {
                Label(L10n.string("clipboard.tags.createDefault"), systemImage: "plus")
            }
        } label: {
            Label(L10n.string("clipboard.tags.menu"), systemImage: "tag")
        }
    }
}

private struct ClipboardTagChips: View {
    let tags: [ClipboardTag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    Label(
                        tag.localizedDisplayName,
                        systemImage: tag.builtInSystemImage ?? "tag.fill"
                    )
                        .blocksFont(size: 9, weight: .medium)
                        .lineLimit(1)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(tag.displayColor.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        }
                        .help(tag.localizedDisplayName)
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .blocksFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        }
                        .help(L10n.format("clipboard.tags.moreTags", overflowCount))
                }
            }
        }
    }

    private var overflowCount: Int {
        max(0, tags.count - 3)
    }
}

private struct ClipboardOCRStatusBadge: View {
    let record: ClipboardRecorderRecord
    let state: ClipboardOCRState
    let onRetryOCR: () -> Void

    var body: some View {
        if record.kind == .image, state != .notRequired {
            switch state {
            case .pending:
                Label(L10n.string("clipboard.ocr.pending"), systemImage: "clock")
            case .running:
                Label(L10n.string("clipboard.ocr.running"), systemImage: "text.viewfinder")
            case .succeeded:
                Label(L10n.string("clipboard.ocr.succeeded"), systemImage: "checkmark.circle")
            case .failed:
                Button(action: onRetryOCR) {
                    Label(L10n.string("clipboard.ocr.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            case .notRequired:
                EmptyView()
            }
        }
    }
}

struct ClipboardQuickPasteNumberBadge: View {
    let index: Int

    var body: some View {
        Text("\(index)")
            .blocksFont(size: 10, weight: .bold)
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.small,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.small,
                    style: .continuous
                )
                    .stroke(
                        Color.accentColor.opacity(0.65),
                        lineWidth: BlocksVisualTokens.Stroke.width
                    )
            }
            .accessibilityLabel(L10n.format("clipboard.quickPaste.numberHint", index))
    }
}
