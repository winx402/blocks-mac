import AppKit
import BlocksCore

@MainActor
final class ScreenshotColorSampleCoordinator {
    typealias SamplerStarter = (
        @escaping @Sendable (NSColor?) -> Void
    ) -> AnyObject

    @MainActor
    private final class Session {
        var sampler: AnyObject?
        var continuation: CheckedContinuation<JSONValue, Error>?
        private var isFinished = false

        func finish(_ result: Result<JSONValue, Error>) {
            guard !isFinished else { return }
            isFinished = true
            sampler = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }

    private let startSampler: SamplerStarter
    private var activeSession: Session?

    init(startSampler: @escaping SamplerStarter = { completion in
        let sampler = NSColorSampler()
        sampler.show(selectionHandler: completion)
        return sampler
    }) {
        self.startSampler = startSampler
    }

    func sample() async throws -> JSONValue {
        guard activeSession == nil else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "screenshot_color_sample_in_progress"
            )
        }
        let session = Session()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                session.continuation = continuation
                activeSession = session
                session.sampler = startSampler { [weak self, session] color in
                    Task { @MainActor [weak self, session] in
                        guard let self else {
                            session.finish(.failure(CancellationError()))
                            return
                        }
                        self.complete(session, with: color)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, session] in
                guard let self else {
                    session.finish(.failure(CancellationError()))
                    return
                }
                self.cancel(session)
            }
        }
    }

    private func cancel(_ session: Session) {
        guard activeSession === session else { return }
        activeSession = nil
        // NSColorSampler has no public API to dismiss its system picker.
        // Releasing the retained sampler nevertheless makes the host action
        // terminal, so the runtime can release its admission lease.
        session.finish(.failure(CancellationError()))
    }

    private func complete(_ session: Session, with color: NSColor?) {
        guard activeSession === session else { return }
        activeSession = nil
        guard let color,
              let resolved = color.usingColorSpace(.sRGB) else {
            session.finish(.failure(
                BlocksPluginRuntimeError.invalidHostOperation(
                    "screenshot_color_sample_cancelled"
                )
            ))
            return
        }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            NSMouseInRect(location, screen.frame, false)
        } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let normalizedX = frame.width > 0
            ? (location.x - frame.minX) / frame.width : 0
        let normalizedY = frame.height > 0
            ? (location.y - frame.minY) / frame.height : 0
        let red = resolved.redComponent
        let green = resolved.greenComponent
        let blue = resolved.blueComponent
        let alpha = resolved.alphaComponent
        let hex = String(
            format: "#%02X%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
        session.finish(.success(.object([
            "color_space": .string("sRGB"),
            "red": .double(red),
            "green": .double(green),
            "blue": .double(blue),
            "alpha": .double(alpha),
            "hex": .string(hex),
            "normalized_x": .double(normalizedX),
            "normalized_y": .double(normalizedY),
        ])))
    }
}
