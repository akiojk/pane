import Darwin
import Foundation

/// Per-second pipeline timings, written to /tmp/pane-stats.log.
/// Off unless `defaults write app.pane.mac pane.stats -bool YES`.
final class PaneStats: @unchecked Sendable {
    static let shared = PaneStats()

    let enabled = UserDefaults.standard.bool(forKey: "pane.stats")

    // Only touch these inside `record`.
    var captured = 0
    var replaced = 0
    var encoded = 0
    var repeats = 0
    var sent = 0
    var serverDrops = 0
    var bytes = 0
    var keyframes = 0
    var largestFrame = 0
    var captureDelay = Window()
    var encodeDelay = Window()
    var sendDelay = Window()
    var captureGap = Gap()
    var sendGap = Gap()
    var audioDelay = Window()
    var audioFrames = 0
    var audioBuffers = 0
    var audioCaptureGap = Gap()
    var audioSendGap = Gap()

    /// Longest time between two events, and how far intervals stray from an even 60 fps cadence.
    struct Gap {
        var last: UInt64 = 0
        var max = 0.0
        var deviation = 0.0
        var intervals = 0

        mutating func tick() {
            let now = PaneStats.now()
            if last != 0 {
                let interval = Double(now - last) * PaneStats.ticksToMs
                max = Swift.max(max, interval)
                if interval < 50 {
                    deviation += abs(interval - 1000.0 / 60)
                    intervals += 1
                }
            }
            last = now
        }

        var jitter: Double { intervals == 0 ? 0 : deviation / Double(intervals) }

        mutating func reset() {
            max = 0
            deviation = 0
            intervals = 0
        }
    }

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    fileprivate static let ticksToMs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    struct Window {
        var total = 0.0
        var count = 0
        var max = 0.0

        mutating func add(_ value: Double) {
            total += value
            count += 1
            max = Swift.max(max, value)
        }

        var text: String {
            count == 0 ? "-" : String(format: "%.1f/%.1f", total / Double(count), max)
        }
    }

    private init() {
        guard enabled else { return }
        try? "".write(toFile: "/tmp/pane-stats.log", atomically: true, encoding: .utf8)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.pane.stats"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    static func now() -> UInt64 { mach_absolute_time() }

    static func milliseconds(since start: UInt64) -> Double {
        let now = mach_absolute_time()
        return now > start ? Double(now - start) * ticksToMs : 0
    }

    func record(_ update: (PaneStats) -> Void) {
        guard enabled else { return }
        lock.lock()
        update(self)
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let line = String(
            format: "%@ captured %d replaced %d encoded %d repeats %d sent %d drops %d %.1fMb key %d largest %dKB | capture %@ encode %@ send %@ ms | gapMax capture %.1f send %.1f | jitter capture %.1f send %.1f | audio %d buffers %d frames delay %@ ms gapMax capture %.1f send %.1f\n",
            Self.clock(), captured, replaced, encoded, repeats, sent, serverDrops, Double(bytes) * 8 / 1_000_000,
            keyframes, largestFrame / 1024,
            captureDelay.text, encodeDelay.text, sendDelay.text, captureGap.max, sendGap.max,
            captureGap.jitter, sendGap.jitter, audioBuffers, audioFrames, audioDelay.text,
            audioCaptureGap.max, audioSendGap.max
        )
        audioDelay = Window(); audioFrames = 0; audioBuffers = 0
        audioCaptureGap.reset(); audioSendGap.reset()
        captured = 0; replaced = 0; encoded = 0; repeats = 0; sent = 0; serverDrops = 0; bytes = 0
        keyframes = 0; largestFrame = 0
        captureDelay = Window(); encodeDelay = Window(); sendDelay = Window()
        captureGap.reset(); sendGap.reset()
        lock.unlock()
        if let handle = FileHandle(forWritingAtPath: "/tmp/pane-stats.log"), let data = line.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
