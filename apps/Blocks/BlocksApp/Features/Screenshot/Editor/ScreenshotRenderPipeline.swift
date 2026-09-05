import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os

struct ScreenshotRenderPipelineResult: @unchecked Sendable {
    let revision: ScreenshotSceneRevision
    let image: CGImage
}

/// Serializes one logical preview stream and rejects every stale completion.
///
/// A store may own multiple pipelines for different cached products, but each
/// product has exactly one owner and one revision boundary.
@MainActor
final class ScreenshotRenderPipeline {
    typealias RenderOperation = @Sendable (
        ScreenshotSourceContext,
        ScreenshotSceneRenderRequest
    ) throws -> CGImage

    private let renderOperation: RenderOperation
    private let signposter: OSSignposter
    private var task: Task<Void, Never>?
    private var activeCancellation: ScreenshotRenderCancellation?
    private var generation: UInt64 = 0

    init(
        category: String = "screenshot-render",
        renderOperation: @escaping RenderOperation = { sourceContext, request in
            try ScreenshotRenderer().render(sourceContext: sourceContext, request: request)
        }
    ) {
        self.renderOperation = renderOperation
        signposter = OSSignposter(
            subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
            category: category
        )
    }

    func submit(
        sourceContext: ScreenshotSourceContext,
        request: ScreenshotSceneRenderRequest,
        completion: @escaping @MainActor @Sendable (ScreenshotRenderPipelineResult) -> Void,
        failure: @escaping @MainActor @Sendable (ScreenshotSceneRevision, String) -> Void = { _, _ in }
    ) {
        generation &+= 1
        let submittedGeneration = generation
        activeCancellation?.cancel()
        task?.cancel()
        activeCancellation = request.cancellation
        let renderOperation = renderOperation
        let signposter = signposter
        let signpostState = signposter.beginInterval("Render")

        let pipeline = self
        task = Task.detached(priority: .userInitiated) {
            defer { signposter.endInterval("Render", signpostState) }
            guard !Task.isCancelled else { return }
            let image: CGImage
            do {
                image = try renderOperation(sourceContext, request)
            } catch {
                guard !Task.isCancelled, !request.cancellation.isCancelled else { return }
                await MainActor.run {
                    guard pipeline.generation == submittedGeneration else { return }
                    failure(request.revision, error.localizedDescription)
                }
                return
            }
            guard !Task.isCancelled, !request.cancellation.isCancelled else { return }
            await MainActor.run {
                guard pipeline.generation == submittedGeneration,
                      !request.cancellation.isCancelled else { return }
                completion(.init(revision: request.revision, image: image))
            }
        }
    }

    func cancel() {
        generation &+= 1
        activeCancellation?.cancel()
        activeCancellation = nil
        task?.cancel()
        task = nil
    }
}
