import AppKit
import CoreImage
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

struct ScrollingCapturedFrame: @unchecked Sendable {
    let image: CGImage
    let timestamp: CMTime
    let contentRect: CGRect
}

enum ScreenCaptureKitScrollingFrameSourceError: Error {
    case displayNotFound
    case invalidRegion
    case missingFrameSurface
}

final class ScrollingFrameBridgeBuffer<Value>: @unchecked Sendable {
    struct Delivery: @unchecked Sendable {
        let generation: UInt64
        let requestID: UInt64
        let sequence: UInt64
        let value: Value
    }

    private let lock = NSLock()
    private let frameCapacity: Int
    private var activeGeneration: UInt64?
    private var nextSequence: UInt64 = 0
    private var lastDeliveredSequence: UInt64 = 0
    private var pendingFrames: [(sequence: UInt64, value: Value)] = []
    private var pendingRequests: [(requestID: UInt64, minimumSequence: UInt64)] = []
    private var isDelivering = false
    private var needsSeed = true

    init(frameCapacity: Int = 4) {
        self.frameCapacity = max(2, frameCapacity)
    }

    func begin(generation: UInt64) {
        lock.lock()
        activeGeneration = generation
        nextSequence = 0
        lastDeliveredSequence = 0
        pendingFrames.removeAll(keepingCapacity: true)
        pendingRequests.removeAll(keepingCapacity: true)
        isDelivering = false
        needsSeed = true
        lock.unlock()
    }

    func offer(_ value: Value, generation: UInt64) -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return nil }
        nextSequence &+= 1
        pendingFrames.append((nextSequence, value))
        if pendingFrames.count > frameCapacity {
            pendingFrames.removeFirst(pendingFrames.count - frameCapacity)
        }
        if needsSeed {
            needsSeed = false
            pendingRequests.append((requestID: 0, minimumSequence: 0))
        }
        return takeNextForDelivery(generation: generation)
    }

    func request(generation: UInt64, requestID: UInt64) -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return nil }
        pendingRequests.append((requestID: requestID, minimumSequence: nextSequence))
        return takeNextForDelivery(generation: generation)
    }

    func complete(_ delivery: Delivery) -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == delivery.generation, isDelivering else { return nil }
        lastDeliveredSequence = max(lastDeliveredSequence, delivery.sequence)
        pendingFrames.removeAll { $0.sequence <= lastDeliveredSequence }
        isDelivering = false
        return takeNextForDelivery(generation: delivery.generation)
    }

    func cancelRequests(generation: UInt64, requestIDs: Set<UInt64>) {
        guard !requestIDs.isEmpty else { return }
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        pendingRequests.removeAll { requestIDs.contains($0.requestID) }
        lock.unlock()
    }

    func invalidate(generation: UInt64) {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        activeGeneration = nil
        pendingFrames.removeAll(keepingCapacity: false)
        pendingRequests.removeAll(keepingCapacity: false)
        isDelivering = false
        needsSeed = false
        lock.unlock()
    }

    func isActive(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    private func takeNextForDelivery(generation: UInt64) -> Delivery? {
        guard !isDelivering,
              let request = pendingRequests.first,
              let next = pendingFrames.first(where: {
                  $0.sequence > request.minimumSequence && $0.sequence > lastDeliveredSequence
              }) else { return nil }
        pendingRequests.removeFirst()
        isDelivering = true
        return Delivery(
            generation: generation,
            requestID: request.requestID,
            sequence: next.sequence,
            value: next.value
        )
    }
}

@MainActor
protocol ScrollingScreenshotFrameSourcing: AnyObject {
    func start(
        generation: UInt64,
        displayID: UInt32,
        displayFrame: CGRect,
        selectionRect: CGRect,
        scale: CGFloat,
        onFrame: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
        onFailure: @escaping @Sendable (UInt64, Error) async -> Void
    ) async throws
    func requestFrame(generation: UInt64, requestID: UInt64)
    func cancelFrameRequests(generation: UInt64, requestIDs: Set<UInt64>)
    func stop(generation: UInt64) async
}

@MainActor
final class ScreenCaptureKitScrollingFrameSource: NSObject, ScrollingScreenshotFrameSourcing {
    private let logger = Logger(subsystem: "app.blocks.app", category: "ScrollingFrameSource")
    private let outputQueue = DispatchQueue(label: "app.blocks.screenshot.scrolling.frames", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var output: Output?
    private var activeGeneration: UInt64?

    func start(
        generation: UInt64,
        displayID: UInt32,
        displayFrame: CGRect,
        selectionRect: CGRect,
        scale: CGFloat,
        onFrame: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
        onFailure: @escaping @Sendable (UInt64, Error) async -> Void
    ) async throws {
        guard stream == nil else { return }
        let region = selectionRect.intersection(displayFrame)
        guard !region.isNull, region.width >= 8, region.height >= 8, displayFrame.contains(region) else {
            throw ScreenCaptureKitScrollingFrameSourceError.invalidRegion
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureKitScrollingFrameSourceError.displayNotFound
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.minX - displayFrame.minX,
            y: displayFrame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
        configuration.width = max(1, Int((region.width * scale).rounded()))
        configuration.height = max(1, Int((region.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = Output(
            generation: generation,
            ciContext: ciContext,
            onFrame: onFrame,
            onFailure: onFailure
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
        self.output = output
        self.stream = stream
        activeGeneration = generation
        logger.info(
            "stage=scrolling-stream-start displayID=\(displayID, privacy: .public) width=\(configuration.width, privacy: .public) height=\(configuration.height, privacy: .public)"
        )
        do {
            try await stream.startCapture()
            guard ownsActiveState(generation: generation, stream: stream, output: output) else {
                await stopOwnedStream(stream, output: output)
                return
            }
        } catch {
            if ownsActiveState(generation: generation, stream: stream, output: output) {
                output.invalidate()
                self.output = nil
                self.stream = nil
                activeGeneration = nil
            } else {
                await stopOwnedStream(stream, output: output)
            }
            throw error
        }
    }

    func requestFrame(generation: UInt64, requestID: UInt64) {
        guard activeGeneration == generation else { return }
        output?.requestFrame(requestID: requestID)
    }

    func cancelFrameRequests(generation: UInt64, requestIDs: Set<UInt64>) {
        guard activeGeneration == generation else { return }
        output?.cancelRequests(requestIDs)
    }

    func stop(generation: UInt64) async {
        guard activeGeneration == generation, let stream else { return }
        let output = output
        self.stream = nil
        self.output = nil
        activeGeneration = nil
        output?.invalidate()
        do {
            try await stream.stopCapture()
        } catch {
            logger.warning("stage=scrolling-stream-stop-failed code=\((error as NSError).code, privacy: .public)")
        }
    }

    private func ownsActiveState(
        generation: UInt64,
        stream: SCStream,
        output: Output
    ) -> Bool {
        activeGeneration == generation
            && self.stream === stream
            && self.output === output
    }

    private func stopOwnedStream(_ stream: SCStream, output: Output) async {
        output.invalidate()
        do {
            try await stream.stopCapture()
        } catch {
            logger.warning("stage=scrolling-stream-stop-failed code=\((error as NSError).code, privacy: .public)")
        }
    }
}

private extension ScreenCaptureKitScrollingFrameSource {
    struct Surface: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let timestamp: CMTime
        let contentRect: CGRect
    }

    final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let generation: UInt64
        private let ciContext: CIContext
        private let onFrame: @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void
        private let onFailure: @Sendable (UInt64, Error) async -> Void
        private let demandBuffer = ScrollingFrameBridgeBuffer<Surface>()

        init(
            generation: UInt64,
            ciContext: CIContext,
            onFrame: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
            onFailure: @escaping @Sendable (UInt64, Error) async -> Void
        ) {
            self.generation = generation
            self.ciContext = ciContext
            self.onFrame = onFrame
            self.onFailure = onFailure
            demandBuffer.begin(generation: generation)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  Self.isComplete(sampleBuffer),
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let surface = Surface(
                pixelBuffer: pixelBuffer,
                timestamp: sampleBuffer.presentationTimeStamp,
                contentRect: CGRect(
                    x: 0,
                    y: 0,
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
            )
            if let delivery = demandBuffer.offer(surface, generation: generation) {
                deliver(delivery)
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            guard demandBuffer.isActive(generation: generation) else { return }
            Task { await onFailure(generation, error) }
        }

        func requestFrame(requestID: UInt64) {
            if let delivery = demandBuffer.request(generation: generation, requestID: requestID) {
                deliver(delivery)
            }
        }

        func cancelRequests(_ requestIDs: Set<UInt64>) {
            demandBuffer.cancelRequests(generation: generation, requestIDs: requestIDs)
        }

        func invalidate() {
            demandBuffer.invalidate(generation: generation)
        }

        private func deliver(_ delivery: ScrollingFrameBridgeBuffer<Surface>.Delivery) {
            Task { [weak self] in
                guard let self else { return }
                let surface = delivery.value
                let ciImage = CIImage(cvPixelBuffer: surface.pixelBuffer)
                var retriesRequest = false
                if self.demandBuffer.isActive(generation: delivery.generation),
                   let image = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    await self.onFrame(delivery.generation, delivery.requestID, ScrollingCapturedFrame(
                        image: image,
                        timestamp: surface.timestamp,
                        contentRect: surface.contentRect
                    ))
                } else if self.demandBuffer.isActive(generation: delivery.generation) {
                    // A transient IOSurface conversion miss must not terminate a long
                    // capture. Keep the same semantic demand and satisfy it from the
                    // next complete stream frame.
                    retriesRequest = true
                }
                if let next = self.demandBuffer.complete(delivery) {
                    self.deliver(next)
                }
                if retriesRequest,
                   let retry = self.demandBuffer.request(
                       generation: delivery.generation,
                       requestID: delivery.requestID
                   ) {
                    self.deliver(retry)
                }
            }
        }

        private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int else {
                return false
            }
            return rawStatus == SCFrameStatus.complete.rawValue
        }
    }
}
