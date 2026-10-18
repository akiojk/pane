import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for interactive display streaming.
final class H264Encoder {
    var onAccessUnit: ((Data, Bool, UInt64) -> Void)?

    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int
    private let queue = DispatchQueue(label: "app.pane.encoder")
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var forceNext = true
    private var busy = false
    private var latest: CVPixelBuffer?
    private var latestFresh = false
    private var latestComposited: UInt64 = 0
    private var lastPTS: CMTime?
    private var lastInput: CVPixelBuffer?
    private var settleRepeats = 0
    private let stateLock = NSLock()
    private var stopped = false

    /// The tablet's decoder shows a frame only once the next one arrives. After the screen
    /// stops changing, the last picture is encoded again so it actually reaches the panel.
    private let settleDelay: DispatchTimeInterval = .milliseconds(30)
    private let settleCount = 2

    init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.bitrate = bitrate
    }

    func start() throws {
        var session: VTCompressionSession?
        let spec: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if status != noErr || session == nil {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            throw EncoderError.setupFailed(status)
        }

        setNumber(session, kVTCompressionPropertyKey_RealTime, 1)
        setBoolean(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
        // TCP never loses a frame and the tablet asks for a keyframe when it needs one, so periodic
        // keyframes only cost bandwidth. Each one is several times a normal frame and stalls the frames behind it.
        setNumber(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 30)
        setNumber(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30)
        setNumber(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        setNumber(session, kVTCompressionPropertyKey_AverageBitRate, bitrate)
        setNumber(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        setBoolean(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        // Level 5.1 tops out near 60 fps at 2560×1600. Above that the stream has to declare 5.2
        // or the tablet decoder may refuse it or fall back to a slower path.
        let fast = fps > 60
        let levels = fast
            ? [kVTProfileLevel_H264_Baseline_5_2, kVTProfileLevel_H264_High_5_2, kVTProfileLevel_H264_Baseline_AutoLevel]
            : [kVTProfileLevel_H264_Baseline_5_1, kVTProfileLevel_H264_High_5_1]
        for level in levels where VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: level) == noErr {
            break
        }

        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else {
            VTCompressionSessionInvalidate(session)
            throw EncoderError.setupFailed(prepare)
        }
        stateLock.lock()
        self.session = session
        stopped = false
        forceNext = true
        stateLock.unlock()
    }

    /// `fresh` is a real content change. A still-screen refresh must not replace one.
    /// Holding the capture buffer is fine: ScreenCaptureKit only reuses buffers that have been released.
    func encode(_ pixelBuffer: CVPixelBuffer, fresh: Bool, composited: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stopped = self.stopped
            if !stopped, fresh || self.latest == nil {
                if self.latest != nil, self.latestFresh {
                    PaneStats.shared.record { $0.replaced += 1 }
                }
                self.latest = pixelBuffer
                self.latestFresh = fresh
                self.latestComposited = composited
            }
            self.stateLock.unlock()
            if !stopped {
                self.drain()
            }
        }
    }

    private func scheduleSettle(after index: Int64) {
        queue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let idle = !self.stopped && !self.busy && self.latest == nil && self.frameIndex == index + 1
            if idle, self.settleRepeats > 0, let last = self.lastInput {
                self.settleRepeats -= 1
                self.latest = last
                self.latestFresh = false
                self.latestComposited = PaneStats.now()
                PaneStats.shared.record { $0.repeats += 1 }
            }
            self.stateLock.unlock()
            self.drain()
        }
    }

    private func drain() {
        stateLock.lock()
        if stopped || busy || session == nil || latest == nil {
            stateLock.unlock()
            return
        }
        busy = true
        let buffer = latest
        let composited = latestComposited
        latest = nil
        lastInput = buffer
        if latestFresh {
            settleRepeats = settleCount
        }
        let shouldForce = forceNext
        forceNext = false
        let index = frameIndex
        frameIndex += 1
        let session = self.session
        stateLock.unlock()
        guard let session, let buffer else { return }

        // Real composite time, so rate control sees the true frame rate even when macOS
        // delivers fewer frames than the display mode promises.
        var pts = CMClockMakeHostTimeFromSystemUnits(composited)
        if let lastPTS, CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts
        let properties: CFDictionary? = shouldForce
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            if status == noErr, let sampleBuffer, let unit = AnnexB.accessUnit(from: sampleBuffer) {
                PaneStats.shared.record { stats in
                    stats.encoded += 1
                    stats.encodeDelay.add(PaneStats.milliseconds(since: composited))
                    if unit.keyframe { stats.keyframes += 1 }
                    stats.largestFrame = max(stats.largestFrame, unit.data.count)
                }
                let micros = UInt64(index) * 1_000_000 / UInt64(self.fps)
                self.onAccessUnit?(unit.data, unit.keyframe, micros)
            }
            self.queue.async {
                self.stateLock.lock()
                self.busy = false
                let idle = self.latest == nil
                self.stateLock.unlock()
                if idle {
                    self.scheduleSettle(after: index)
                } else {
                    self.drain()
                }
            }
        }
        if status != noErr {
            queue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.busy = false
                self.stateLock.unlock()
                self.drain()
            }
        }
    }

    func requestKeyframe() {
        stateLock.lock()
        forceNext = true
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        let session = self.session
        self.session = nil
        latest = nil
        lastInput = nil
        stateLock.unlock()
        guard let session else { return }
        queue.sync {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    private func setNumber(_ session: VTCompressionSession, _ key: CFString, _ value: Int) {
        VTSessionSetProperty(session, key: key, value: NSNumber(value: value))
    }

    private func setBoolean(_ session: VTCompressionSession, _ key: CFString, _ value: Bool) {
        VTSessionSetProperty(session, key: key, value: value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    enum EncoderError: Error {
        case setupFailed(OSStatus)
    }
}

enum AnnexB {
    static func accessUnit(from sampleBuffer: CMSampleBuffer) -> (data: Data, keyframe: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &total,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer, total > 0 else { return nil }
        let avcc = Data(bytes: pointer, count: total)
        let keyframe = isSync(sampleBuffer)
        var lengthSize = 4
        var parameterSets = Data()
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = parameterSetAnnexB(format, lengthSize: &lengthSize)
        }
        var unit = Data()
        if keyframe {
            unit.append(parameterSets)
        }
        unit.append(avccToAnnexB(avcc, lengthSize: lengthSize))
        return unit.isEmpty ? nil : (unit, keyframe)
    }

    static func avccToAnnexB(_ data: Data, lengthSize: Int) -> Data {
        guard lengthSize == 1 || lengthSize == 2 || lengthSize == 4 else { return Data() }
        var output = Data()
        var offset = 0
        let startCode: [UInt8] = [0, 0, 0, 1]
        while offset + lengthSize <= data.count {
            var length = 0
            for byte in data[offset..<(offset + lengthSize)] {
                length = (length << 8) | Int(byte)
            }
            offset += lengthSize
            guard length > 0, offset + length <= data.count else { break }
            output.append(contentsOf: startCode)
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        return output
    }

    private static func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private static func parameterSetAnnexB(_ format: CMFormatDescription, lengthSize: inout Int) -> Data {
        var count = 0
        var nalLength: Int32 = 4
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLength
        )
        if probe == noErr, nalLength > 0 {
            lengthSize = Int(nalLength)
        }
        guard count > 0 else { return Data() }
        var output = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            output.append(contentsOf: startCode)
            output.append(pointer, count: size)
        }
        return output
    }
}
