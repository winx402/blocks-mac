import AppKit
import Combine
import SwiftUI

@MainActor
final class PermissionAssistPanelSessionModel: ObservableObject {
    @Published private(set) var session: PermissionAssistSession?
    @Published private(set) var appURL: URL

    init(session: PermissionAssistSession?, appURL: URL) {
        self.session = session
        self.appURL = appURL
    }

    func update(session: PermissionAssistSession?, appURL: URL) {
        guard self.session != session || self.appURL != appURL else {
            return
        }
        self.session = session
        self.appURL = appURL
    }
}

struct PermissionAssistPanelView: View {
    @ObservedObject var sessionModel: PermissionAssistPanelSessionModel
    let onCompleted: () -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            if let session = sessionModel.session {
                panelContent(session)
            }
        }
    }

    private func panelContent(_ session: PermissionAssistSession) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Label(session.kind.title, systemImage: permissionIcon(for: session.kind))
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("common.close"))
                .accessibilityIdentifier("permissionAssist.closeButton")
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 15) {
                    Label(sessionStateText(for: session), systemImage: sessionStateIcon(for: session.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(session.state == .failed ? .red : .secondary)

                    HStack(alignment: .center, spacing: 16) {
                        if session.arrowDirection == .right {
                            draggableAppIcon
                            animatedArrow(direction: session.arrowDirection)
                            instructionText(for: session)
                        } else {
                            instructionText(for: session)
                            animatedArrow(direction: session.arrowDirection)
                            draggableAppIcon
                        }
                    }
                    .padding(14)
                    .blocksSurface(
                        .section,
                        cornerRadius: BlocksVisualTokens.CornerRadius.section
                    )

                    Label(L10n.string("permission.assist.openedSettings"), systemImage: "gearshape.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("permissionAssist.scrollableContent")

            HStack {
                Spacer()
                Button {
                    onCompleted()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                        Text(L10n.string("permission.assist.completed"))
                    }
                    .frame(minWidth: 112, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("permissionAssist.completedButton")
            }
        }
        .blocksSurface(
            .panel,
            cornerRadius: BlocksVisualTokens.CornerRadius.large,
            padding: BlocksVisualTokens.Spacing.lg
        )
    }

    private var draggableAppIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: sessionModel.appURL.path))
            .resizable()
            .frame(width: 64, height: 64)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.section,
                    style: .continuous
                )
            )
            .onDrag {
                NSItemProvider(object: sessionModel.appURL as NSURL)
            }
    }

    private func animatedArrow(direction: PermissionAssistArrowDirection) -> some View {
        AnimatedPermissionArrow(direction: direction)
            .frame(width: 98, height: 34)
            .foregroundStyle(Color.accentColor)
    }

    private func instructionText(for session: PermissionAssistSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("permission.assist.dragTitle"))
                .font(.subheadline.weight(.semibold))
            Text(session.kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionStateText(for session: PermissionAssistSession) -> String {
        if let reason = session.lastFailureReason, session.state == .failed {
            return reason
        }
        switch session.state {
        case .idle:
            return L10n.string("permission.assist.state.idle")
        case .openingSystemSettings:
            return L10n.string("permission.assist.state.opening")
        case .waitingForSettingsWindow:
            return L10n.string("permission.assist.state.waiting")
        case .guiding:
            return L10n.string("permission.assist.state.guiding")
        case .checkingPermission:
            return L10n.string("permission.assist.state.checking")
        case .granted:
            return L10n.string("permission.assist.state.granted")
        case .failed:
            return L10n.string("permission.assist.state.failed")
        case .cancelled:
            return L10n.string("permission.assist.state.cancelled")
        case .timedOut:
            return L10n.string("permission.assist.state.timedOut")
        }
    }

    private func permissionIcon(for kind: PermissionAssistKind) -> String {
        switch kind {
        case .screenRecording:
            "record.circle"
        case .accessibility:
            "figure.wave"
        case .inputMonitoring:
            "keyboard"
        }
    }

    private func sessionStateIcon(for state: PermissionAssistSessionState) -> String {
        switch state {
        case .granted:
            "checkmark.circle"
        case .failed, .timedOut, .cancelled:
            "exclamationmark.triangle"
        case .waitingForSettingsWindow, .openingSystemSettings:
            "hourglass"
        default:
            "arrow.right.circle"
        }
    }
}

struct PermissionAssistArrowAnimationIdentity: Hashable {
    let direction: String
    let reduceMotion: Bool

    init(direction: PermissionAssistArrowDirection, reduceMotion: Bool) {
        self.direction = direction == .right ? "right" : "left"
        self.reduceMotion = reduceMotion
    }
}

enum PermissionAssistArrowAnimationProgress {
    static func initialValue(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : 0
    }
}

private struct AnimatedPermissionArrow: View {
    let direction: PermissionAssistArrowDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let midY = proxy.size.height / 2
                switch direction {
                case .right:
                    path.move(to: CGPoint(x: 4, y: midY))
                    path.addLine(to: CGPoint(x: proxy.size.width - 12, y: midY))
                    path.move(to: CGPoint(x: proxy.size.width - 24, y: midY - 10))
                    path.addLine(to: CGPoint(x: proxy.size.width - 10, y: midY))
                    path.addLine(to: CGPoint(x: proxy.size.width - 24, y: midY + 10))
                case .left:
                    path.move(to: CGPoint(x: proxy.size.width - 4, y: midY))
                    path.addLine(to: CGPoint(x: 12, y: midY))
                    path.move(to: CGPoint(x: 24, y: midY - 10))
                    path.addLine(to: CGPoint(x: 10, y: midY))
                    path.addLine(to: CGPoint(x: 24, y: midY + 10))
                }
            }
            .trim(from: 0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .task(id: PermissionAssistArrowAnimationIdentity(
                direction: direction,
                reduceMotion: reduceMotion
            )) {
                progress = PermissionAssistArrowAnimationProgress.initialValue(
                    reduceMotion: reduceMotion
                )
                guard !reduceMotion else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(BlocksMotionRole.reveal.animation(reduceMotion: reduceMotion)) {
                    progress = 1
                }
            }
            .onChange(of: reduceMotion) { _, isReduced in
                guard isReduced else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    progress = PermissionAssistArrowAnimationProgress.initialValue(
                        reduceMotion: true
                    )
                }
            }
        }
    }
}
