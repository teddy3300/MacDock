import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Manages real-time window streaming via ScreenCaptureKit SCStream.
/// Streams frames directly to an AVSampleBufferDisplayLayer for GPU hardware-accelerated rendering.
final class LiveStreamManager: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = LiveStreamManager()

    private(set) var currentWindowID: CGWindowID?
    private var activeStream: SCStream?
    private weak var activeDisplayLayer: AVSampleBufferDisplayLayer?
    private var onFirstFrameCallback: (() -> Void)?
    private var hasDeliveredFirstFrame = false
    private let queue = DispatchQueue(label: "com.macdock.livestream", qos: .userInteractive)
    private var sessionGeneration: UInt64 = 0

    override private init() {
        super.init()
    }

    /// Starts streaming the specified window to the provided display layer.
    func startStream(
        for windowID: CGWindowID,
        frameRate: Int = 30,
        displayLayer: AVSampleBufferDisplayLayer,
        onFirstFrame: (() -> Void)? = nil
    ) {
        stopCurrentStream()

        guard ScreenCapture.isAuthorized else {
            Logger.log("LiveStream: screen recording not authorized")
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration

        currentWindowID = windowID
        activeDisplayLayer = displayLayer
        onFirstFrameCallback = onFirstFrame
        hasDeliveredFirstFrame = false

        ScreenCapture.shareableWindow(for: windowID) { [weak self] scWindow in
            guard let self, self.sessionGeneration == generation else { return }
            guard let scWindow else {
                Logger.log("LiveStream: window \(windowID) not found in shareable content")
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let configuration = SCStreamConfiguration()
            let frame = scWindow.frame
            let nativeScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let boundedScale = min(nativeScale, 2560.0 / max(max(frame.width, frame.height), 1.0))
            let scale = max(0.5, boundedScale)

            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
            configuration.sourceRect = .zero
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.scalesToFit = true
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                Logger.log("LiveStream: failed to add stream output: \(error)")
                return
            }

            stream.startCapture { error in
                if let error {
                    Logger.log("LiveStream startCapture failed: \(error)")
                } else {
                    Logger.log("LiveStream started for window \(windowID) at \(frameRate) fps")
                }
            }
            self.activeStream = stream
        }
    }

    /// Stops any active stream and releases capture resources.
    func stopCurrentStream() {
        sessionGeneration &+= 1
        if let stream = activeStream {
            activeStream = nil
            stream.stopCapture { error in
                if let error {
                    Logger.log("LiveStream stopCapture error: \(error)")
                }
            }
            Logger.log("LiveStream stopped")
        }
        currentWindowID = nil
        let layer = activeDisplayLayer
        activeDisplayLayer = nil
        onFirstFrameCallback = nil
        hasDeliveredFirstFrame = false

        DispatchQueue.main.async {
            layer?.flushAndRemoveImage()
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard stream === activeStream else { return }

        if !hasDeliveredFirstFrame {
            hasDeliveredFirstFrame = true
            let callback = onFirstFrameCallback
            DispatchQueue.main.async {
                callback?()
            }
        }

        if let displayLayer = activeDisplayLayer {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.log("LiveStream delegate didStopWithError: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeStream === stream else { return }
            self.stopCurrentStream()
        }
    }
}
