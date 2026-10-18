import CoreAudio
import Foundation

/// Captures everything apps play through a Core Audio process tap (macOS 14.2+).
/// Taps hand over audio in a few milliseconds. ScreenCaptureKit's audio arrives about 50 ms late,
/// which leaves the sound visibly behind the picture.
final class AudioTap {
    /// Buffer list, frame count, its format, and the host time of the first frame.
    typealias Handler = (UnsafePointer<AudioBufferList>, Int, AudioStreamBasicDescription, UInt64) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.pane.audio.tap", qos: .userInteractive)

    var isRunning: Bool { procID != nil }

    enum TapError: Error {
        case failed(String, OSStatus)
    }

    /// `clockDeviceUID` is the output the apps are playing to, so the tap runs on its clock.
    func start(clockDeviceUID: String, handler: @escaping Handler) throws {
        stop()
        guard #available(macOS 14.2, *) else { throw TapError.failed("needs macOS 14.2", -1) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("create tap", status) }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format)
        guard status == noErr else { stop(); throw TapError.failed("read tap format", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pane audio tap",
            kAudioAggregateDeviceUIDKey: "app.pane.audio.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockDeviceUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); throw TapError.failed("create aggregate device", status) }
        aggregateID = device

        // 5 ms buffers. Smaller buffers are what make the tap low latency.
        var frames: UInt32 = 240
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        // For non-interleaved audio mBytesPerFrame is per channel, matching each buffer, so this works either way.
        let bytesPerFrame = Int(max(1, format.mBytesPerFrame))
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, first.mDataByteSize > 0 else { return }
            handler(input, Int(first.mDataByteSize) / bytesPerFrame, format, inputTime.pointee.mHostTime)
        }
        guard status == noErr, let proc else { stop(); throw TapError.failed("create IO proc", status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw TapError.failed("start", status) }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
