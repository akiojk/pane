import AppKit
import CoreGraphics
import Foundation
import os

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case starting
        case waiting
        case streaming
        case stopped
        case failed
    }

    @Published var phase: Phase = .starting
    @Published var detail = "Starting"
    @Published var clientName: String?
    @Published var clientDetail = ""
    @Published var fps: Double = 0
    @Published var megabits: Double = 0
    @Published var geometryLabel = ""
    @Published var preset: DisplayPreset = .match
    @Published var refresh = 120
    @Published var naturalScroll = true
    @Published var screenRecordingGranted = false
    @Published var accessibilityGranted = false
    @Published var lastError: String?
    @Published var listenerDetail = ""
    @Published var usbDetail = "Checking the USB cable…"
    @Published var audioInstalled = false
    @Published var audioRouted = false

    let port: UInt16 = 47777

    private var display: PaneVirtualDisplay?
    private var geometry: DisplayArrangement.Geometry?
    private var activeSpec: DisplaySpec?
    private var pendingHello: HelloMessage?
    private let server = StreamServer()
    private let cursor = CursorRelay()
    private let cursorShape = CursorShapeWatcher()
    private let adb = AdbBridge()
    private let audio = AudioRelay()
    private var pipelineGeneration = 0
    private let input = InputInjector()
    private var capture: CaptureEngine?
    private var encoder: H264Encoder?
    private let meter = RateMeter()
    private var statsTimer: Timer?
    private var started = false
    private var applying = false
    private let log = Logger(subsystem: "app.pane", category: "app")

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "pane.preset"), let saved = DisplayPreset(rawValue: raw) {
            preset = saved
        }
        let savedRefresh = defaults.integer(forKey: "pane.refresh")
        if [30, 60, 120].contains(savedRefresh) {
            refresh = savedRefresh
        }
        if defaults.object(forKey: "pane.naturalScroll") != nil {
            naturalScroll = defaults.bool(forKey: "pane.naturalScroll")
        }
        input.setNaturalScroll(naturalScroll)
    }

    func bootstrap() {
        guard !started else { return }
        started = true
        wireServer()
        do {
            try server.start(port: port)
            cursor.start(port: port + 1)
            cursorShape.onChange = { [cursor] shape in
                cursor.setShape(shape)
            }
            cursorShape.start()
            adb.onStatus = { text in
                Task { @MainActor in
                    AppModel.shared.usbDetail = text
                }
            }
            audio.onRouteChange = { routed in
                Task { @MainActor in
                    AppModel.shared.audioRouted = routed
                    AppModel.shared.audioInstalled = AudioRelay.isInstalled
                }
            }
            audio.start(port: port + 2)
            audioInstalled = AudioRelay.isInstalled
            adb.start(ports: [port, port + 1, port + 2])
        } catch {
            phase = .failed
            lastError = "Could not listen on port \(port). \(error.localizedDescription)"
            return
        }
        refreshPermissions()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleStats()
            }
        }
        Task { await self.recreateDisplay() }
    }

    func shutdown() {
        statsTimer?.invalidate()
        stopPipeline()
        cursorShape.stop()
        cursor.stop()
        audio.stop()
        adb.stop()
        display = nil
        server.stop()
        phase = .stopped
    }

    func applyDisplaySettings() {
        UserDefaults.standard.set(preset.rawValue, forKey: "pane.preset")
        UserDefaults.standard.set(refresh, forKey: "pane.refresh")
        guard started else { return }
        Task { await self.recreateDisplay() }
    }

    func setNaturalScroll(_ enabled: Bool) {
        naturalScroll = enabled
        input.setNaturalScroll(enabled)
        UserDefaults.standard.set(enabled, forKey: "pane.naturalScroll")
    }

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !screenRecordingGranted {
            lastError = "Turn on Screen Recording for Pane in System Settings. macOS usually wants the app reopened after that."
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func wireServer() {
        server.onListenerState = { state in
            Task { @MainActor in
                AppModel.shared.listenerDetail = state
                if state.hasPrefix("failed") {
                    AppModel.shared.lastError = "The network listener failed. \(state)"
                }
            }
        }
        server.onHello = { hello in
            Task { @MainActor in
                await AppModel.shared.handleHello(hello)
            }
        }
        server.onPointer = { [input] message in
            input.pointer(message)
        }
        server.onScroll = { [input] dx, dy, phase in
            input.scroll(dx: dx, dy: dy, phase: phase)
        }
        server.onPinch = { [input] pinch in
            input.pinch(pinch)
        }
        // Clicks travel on the pointer connection so a video frame cannot sit in front of them.
        cursor.onPointer = { [input] message in
            input.pointer(message)
        }
        cursor.onScroll = { [input] dx, dy, phase in
            input.scroll(dx: dx, dy: dy, phase: phase)
        }
        cursor.onPinch = { [input] pinch in
            input.pinch(pinch)
        }
        server.onKeyframeRequest = { [weak self] in
            Task { @MainActor in
                self?.encoder?.requestKeyframe()
            }
        }
        server.onDisconnect = {
            Task { @MainActor in
                AppModel.shared.handleDisconnect()
            }
        }
    }

    private func handleHello(_ hello: HelloMessage) async {
        pendingHello = hello
        let trimmed = hello.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        clientName = trimmed.isEmpty ? "Android tablet" : trimmed
        var bits: [String] = []
        if hello.hasTouch { bits.append("touch") }
        if hello.hasStylus { bits.append("stylus") }
        if hello.hasHover { bits.append("hover") }
        clientDetail = bits.joined(separator: " · ")
        refreshPermissions()
        guard screenRecordingGranted else {
            lastError = "Allow Screen Recording for Pane, then reconnect the tablet. If you just turned it on, quit Pane and open it again."
            requestScreenRecording()
            return
        }
        if !accessibilityGranted {
            lastError = "Allow Accessibility for Pane so taps on the tablet can move the Mac pointer."
            requestAccessibility()
        }
        if preset == .match || display == nil {
            await recreateDisplay()
        } else {
            await startPipeline()
        }
    }

    private func handleDisconnect() {
        stopPipeline()
        clientName = nil
        clientDetail = ""
        fps = 0
        megabits = 0
        if display != nil {
            phase = .waiting
            detail = "Tablet disconnected. The display is still there, so your windows stay put."
        }
    }

    private func recreateDisplay() async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        stopPipeline()
        guard let spec = preset.spec(hello: pendingHello, refreshCap: refresh) else {
            display = nil
            geometry = nil
            activeSpec = nil
            geometryLabel = ""
            if preset == .match, let hello = pendingHello {
                phase = .failed
                lastError = "The tablet reported \(hello.screenWidth)×\(hello.screenHeight), which Pane cannot use as a display."
            } else {
                phase = .waiting
                detail = "Plug in the tablet and open Pane. The display will match the tablet's screen."
                lastError = nil
            }
            return
        }
        if activeSpec == spec, display != nil, geometry != nil {
            phase = .waiting
            detail = "Plug in the tablet and open Pane. The cable is the only connection."
            if clientName != nil {
                await startPipeline()
            }
            return
        }
        display = nil
        geometry = nil
        activeSpec = nil
        phase = .starting
        detail = "Creating the \(spec.name) display"
        lastError = nil

        let created = DisplayArrangement.create(spec)
        guard let created, created.displayID != 0 else {
            phase = .failed
            lastError = "macOS did not create a virtual display. Pane uses the private CGVirtualDisplay API, which has to run inside this app."
            return
        }
        display = created
        input.setDisplay(created.displayID)
        cursor.setDisplay(created.displayID)

        var settled: DisplayArrangement.Geometry?
        for attempt in 0..<25 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let geometry = DisplayArrangement.arrange(displayID: created.displayID, spec: spec) {
                settled = geometry
                break
            }
        }
        guard let settled else {
            phase = .failed
            lastError = "The virtual display never published a video mode."
            log.error("\(self.lastError ?? "", privacy: .public)")
            return
        }
        activeSpec = spec
        geometry = settled
        let scale = settled.pixelWidth >= settled.pointWidth * 2 ? "Retina" : "1×"
        geometryLabel = "\(settled.pixelWidth)×\(settled.pixelHeight) \(scale) · \(settled.pointWidth)×\(settled.pointHeight) pt · \(streamRate(settled)) Hz"
        phase = .waiting
        detail = "Plug in the tablet and open Pane. The cable is the only connection."
        log.info("display \(created.displayID) \(self.geometryLabel, privacy: .public)")
        if clientName != nil {
            await startPipeline()
        }
    }

    private func startPipeline() async {
        guard let geometry, let display else { return }
        stopPipeline()
        let generation = pipelineGeneration
        let fps = streamRate(geometry)
        let encoder = H264Encoder(
            width: geometry.pixelWidth,
            height: geometry.pixelHeight,
            fps: fps,
            bitrate: Self.bitrate(pixels: geometry.pixelWidth * geometry.pixelHeight, fps: fps)
        )
        let capture = CaptureEngine()
        encoder.onAccessUnit = { [server, meter, capture] data, keyframe, pts in
            server.sendVideo(annexB: data, keyframe: keyframe, ptsMicros: pts)
            meter.add(frames: 1, bytes: data.count)
            capture.noteFrameDelivered()
        }
        capture.onPixelBuffer = { [encoder] buffer, fresh, composited in
            encoder.encode(buffer, fresh: fresh, composited: composited)
        }
        capture.onAudio = { [audio] sampleBuffer in
            audio.send(sampleBuffer)
        }
        capture.onStopped = { message in
            Task { @MainActor in
                AppModel.shared.lastError = "Capture stopped. \(message)"
            }
        }
        do {
            try encoder.start()
            encoder.requestKeyframe()
            try await capture.start(
                displayID: display.displayID,
                width: geometry.pixelWidth,
                height: geometry.pixelHeight,
                fps: fps
            )
        } catch {
            encoder.stop()
            capture.stop()
            guard generation == pipelineGeneration else { return }
            phase = .waiting
            lastError = error.localizedDescription
            log.error("pipeline \(error.localizedDescription, privacy: .public)")
            return
        }
        // Another start or a disconnect happened while capture was starting. Only the newest pipeline may run.
        guard generation == pipelineGeneration else {
            encoder.stop()
            capture.stop()
            return
        }
        self.encoder = encoder
        self.capture = capture
        server.sendHelloAck(width: geometry.pixelWidth, height: geometry.pixelHeight, fps: fps)
        phase = .streaming
        detail = "Streaming to \(clientName ?? "the tablet")"
        lastError = nil
    }

    private func stopPipeline() {
        pipelineGeneration += 1
        capture?.stop()
        encoder?.stop()
        capture = nil
        encoder = nil
    }

    private func sampleStats() {
        refreshPermissions()
        let sample = meter.take()
        let interval = sample.interval
        guard interval > 0 else { return }
        if phase == .streaming {
            fps = Double(sample.frames) / interval
            megabits = Double(sample.bytes) * 8 / interval / 1_000_000
        }
    }

    /// The rate WindowServer actually gave the display, so capture never asks for frames that will not come.
    private func streamRate(_ geometry: DisplayArrangement.Geometry) -> Int {
        let actual = geometry.refreshRate
        return (24...240).contains(actual) ? min(actual, refresh) : refresh
    }

    /// At 120 Hz each frame carries half the change of a 60 Hz frame, so the rate grows slower than the frame count.
    private static func bitrate(pixels: Int, fps: Int) -> Int {
        let estimate = Int(Double(pixels) * 0.20 * 60 * (Double(fps) / 60).squareRoot())
        return min(80_000_000, max(12_000_000, estimate))
    }
}

final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0
    private var last = Date()

    func add(frames: Int, bytes: Int) {
        lock.lock()
        self.frames += frames
        self.bytes += bytes
        lock.unlock()
    }

    func take() -> (frames: Int, bytes: Int, interval: TimeInterval) {
        lock.lock()
        let now = Date()
        let interval = now.timeIntervalSince(last)
        let snapshot = (frames, bytes, interval)
        frames = 0
        bytes = 0
        last = now
        lock.unlock()
        return snapshot
    }
}
