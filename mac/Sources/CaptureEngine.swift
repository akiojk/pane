import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Buffer, whether it is a real change, and the host time the frame was composited.
    var onPixelBuffer: ((CVPixelBuffer, Bool, UInt64) -> Void)?
    /// System audio, everything apps play. Pane only forwards it while the tablet is the output device.
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStopped: ((String) -> Void)?

    static let audioSampleRate = 48_000
    static let audioChannels = 2

    private let queue = DispatchQueue(label: "app.pane.capture")
    private let audioQueue = DispatchQueue(label: "app.pane.capture.audio", qos: .userInteractive)
    private var stream: SCStream?
    private let lock = NSLock()
    private var running = false
    private var wantsKeyframe = true

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.capturesAudio = true
        configuration.sampleRate = Self.audioSampleRate
        configuration.channelCount = Self.audioChannels
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        retain(stream)
    }

    private func retain(_ stream: SCStream) {
        lock.lock()
        self.stream = stream
        running = true
        wantsKeyframe = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { onAudio?(sampleBuffer) }
            return
        }
        guard type == .screen else { return }
        lock.lock()
        let isRunning = running
        lock.unlock()
        guard isRunning, sampleBuffer.isValid else { return }

        let status = frameStatus(sampleBuffer)
        switch status {
        case .complete, .started:
            break
        case .idle:
            lock.lock()
            let need = wantsKeyframe
            lock.unlock()
            guard need else { return }
        default:
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let composited = displayTime(sampleBuffer) ?? PaneStats.now()
        if status != .idle {
            PaneStats.shared.record { stats in
                stats.captured += 1
                stats.captureDelay.add(PaneStats.milliseconds(since: composited))
                stats.captureGap.tick()
            }
        }
        onPixelBuffer?(pixelBuffer, status != .idle, composited)
    }

    private func displayTime(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let value = attachments.first?[.displayTime] as? UInt64 else {
            return nil
        }
        return value
    }

    /// Called once an encoded frame has actually been produced. Until then, unchanged
    /// frames keep being offered so a static display still gets a first picture out.
    func noteFrameDelivered() {
        lock.lock()
        wantsKeyframe = false
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        running = false
        lock.unlock()
        onStopped?(error.localizedDescription)
    }

    private func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return .complete
        }
        return status
    }

    enum CaptureError: LocalizedError {
        case displayNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound:
                return "ScreenCaptureKit cannot see the virtual display yet."
            }
        }
    }
}
