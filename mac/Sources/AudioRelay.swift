import CoreAudio
import CoreMedia
import Foundation
import Network

/// Streams system audio to the tablet while "Pane" (the PaneAudio driver) is the selected output.
/// The driver itself is silent, so the tablet becomes the Mac's speaker. Its volume control scales what is sent.
///
/// Audio comes from a Core Audio tap while the tablet is listening. If the tap cannot start, for example
/// because audio capture permission was denied, ScreenCaptureKit's audio is used instead. It works but runs later.
final class AudioRelay: @unchecked Sendable {
    static let deviceUID = "app.pane.audio.device"

    var onRouteChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "app.pane.audio", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var inflightBytes = 0
    private let lock = NSLock()
    private var routed = false
    private var connected = false
    private var tapRunning = false
    private var gain: Float = 1
    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private let tap = AudioTap()
    private var tapFailed = false

    /// More than this much unsent audio means the link stalled. Dropping keeps the sound in sync with the picture.
    private let maxInflightBytes = CaptureEngine.audioSampleRate * CaptureEngine.audioChannels * 2 / 5

    func start(port: UInt16) {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = PaneListener.tcpParameters(port: port, keepalive: false)
            guard let listener = try? NWListener(using: parameters) else { return }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
        DispatchQueue.main.async { self.watchRoute() }
    }

    func stop() {
        tap.stop()
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Whether the PaneAudio driver is installed and its device exists.
    static var isInstalled: Bool { findDevice() != kAudioObjectUnknown }

    var isRouted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return routed
    }

    /// Fallback path: called on the capture's audio queue with float PCM from ScreenCaptureKit.
    func send(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let wanted = routed && !tapRunning
        let gain = self.gain
        lock.unlock()
        guard wanted, let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        var pcm: Data?
        try? sampleBuffer.withAudioBufferList { list, _ in
            pcm = Self.int16PCM(list, frames: sampleBuffer.numSamples, format: format, gain: gain)
        }
        guard let pcm else { return }
        let age = CMClockGetTime(CMClockGetHostTimeClock()) - sampleBuffer.presentationTimeStamp
        enqueue(pcm, frames: sampleBuffer.numSamples, ageMs: age.isValid ? age.seconds * 1000 : nil)
    }

    /// Tap path: called on the tap's IO queue.
    private func sendTapped(_ input: UnsafePointer<AudioBufferList>, frames: Int, format: AudioStreamBasicDescription, hostTime: UInt64) {
        lock.lock()
        let wanted = routed
        let gain = self.gain
        lock.unlock()
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard wanted, let pcm = Self.int16PCM(list, frames: frames, format: format, gain: gain) else { return }
        let age = hostTime == 0 ? nil : PaneStats.milliseconds(since: hostTime)
        enqueue(pcm, frames: frames, ageMs: age)
    }

    private func enqueue(_ pcm: Data, frames: Int, ageMs: Double?) {
        PaneStats.shared.record { stats in
            stats.audioBuffers += 1
            stats.audioFrames += frames
            if let ageMs { stats.audioDelay.add(ageMs) }
            stats.audioCaptureGap.tick()
        }
        let packet = PaneCodec.audio(pcm: pcm)
        queue.async { [self] in
            guard let connection, connection.state == .ready else { return }
            if inflightBytes + packet.count > maxInflightBytes { return }
            inflightBytes += packet.count
            connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                PaneStats.shared.record { $0.audioSendGap.tick() }
                self?.queue.async {
                    guard let self, self.connection === connection else { return }
                    self.inflightBytes = max(0, self.inflightBytes - packet.count)
                }
            })
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        inflightBytes = 0
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    connection.send(
                        content: PaneCodec.audioFormat(sampleRate: CaptureEngine.audioSampleRate, channels: CaptureEngine.audioChannels),
                        completion: .contentProcessed { _ in }
                    )
                    self.setConnected(true)
                case .failed, .cancelled:
                    self.connection = nil
                    self.setConnected(false)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            self?.queue.async {
                guard let self, self.connection === connection else { return }
                if isComplete || error != nil {
                    connection.cancel()
                    self.connection = nil
                    self.setConnected(false)
                    return
                }
                self.receiveLoop(connection)
            }
        }
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        connected = value
        lock.unlock()
        DispatchQueue.main.async { self.updateTap() }
    }

    /// Runs the tap only while the tablet is listening and is the selected output,
    /// so macOS's recording indicator is not on for nothing.
    private func updateTap() {
        lock.lock()
        let wanted = routed && connected && !tapFailed
        lock.unlock()
        if wanted && !tap.isRunning {
            do {
                try tap.start(clockDeviceUID: Self.deviceUID) { [weak self] input, frames, format, hostTime in
                    self?.sendTapped(input, frames: frames, format: format, hostTime: hostTime)
                }
            } catch {
                tapFailed = true
                NSLog("Pane: audio tap unavailable, using ScreenCaptureKit audio. \(error)")
            }
        } else if !wanted && tap.isRunning {
            tap.stop()
        }
        lock.lock()
        tapRunning = tap.isRunning
        lock.unlock()
    }

    // MARK: - Output device and volume

    private func watchRoute() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshRoute()
        }
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshRoute()
        }
        refreshRoute()
    }

    private func refreshRoute() {
        let ours = Self.findDevice()
        if ours != deviceID {
            deviceID = ours
            watchVolume(ours)
        }
        let routed = ours != kAudioObjectUnknown && Self.defaultOutputDevice() == ours
        lock.lock()
        let changed = self.routed != routed
        self.routed = routed
        lock.unlock()
        refreshVolume()
        updateTap()
        if changed { onRouteChange?(routed) }
    }

    private func watchVolume(_ device: AudioObjectID) {
        guard device != kAudioObjectUnknown else { return }
        var address = Self.volumeAddress
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshVolume()
        }
    }

    private func refreshVolume() {
        guard deviceID != kAudioObjectUnknown else { return }
        var address = Self.volumeAddress
        var scalar: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr else { return }
        // The driver's scalar runs linearly over -64…0 dB, so convert back to amplitude.
        let decibels = -64 * (1 - scalar)
        lock.lock()
        gain = scalar <= 0 ? 0 : powf(10, decibels / 20)
        lock.unlock()
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static func findDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid = deviceUID as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device
            )
        }
        return status == noErr ? device : kAudioObjectUnknown
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    // MARK: - Conversion

    /// Both sources deliver 32-bit float, interleaved or one buffer per channel. The tablet wants interleaved 16-bit
    /// at the rate announced when it connected, so anything else is skipped rather than played at the wrong speed.
    private static func int16PCM(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, format: AudioStreamBasicDescription, gain: Float) -> Data? {
        guard frames > 0,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              Int(format.mSampleRate) == CaptureEngine.audioSampleRate,
              list.count > 0 else { return nil }
        let channels = CaptureEngine.audioChannels
        let interleavedSource = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let sourceChannels = Int(max(1, format.mChannelsPerFrame))
        var output = Data(count: frames * channels * 2)
        output.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: Int16.self)
            for channel in 0..<channels {
                let bufferIndex = interleavedSource ? 0 : min(channel, list.count - 1)
                guard let data = list[bufferIndex].mData else { continue }
                let source = data.assumingMemoryBound(to: Float32.self)
                let stride = interleavedSource ? sourceChannels : 1
                let offset = interleavedSource ? min(channel, sourceChannels - 1) : 0
                for frame in 0..<frames {
                    let sample = max(-1, min(1, source[frame * stride + offset] * gain))
                    destination[frame * channels + channel] = Int16(sample * 32767).littleEndian
                }
            }
        }
        return output
    }
}
