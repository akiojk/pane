import Foundation

/// Forwards the stream ports over the tablet's USB cable using adb.
/// The tablet then connects to itself, and the cable carries the bytes.
final class AdbBridge {
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "app.pane.adb")
    private var timer: DispatchSourceTimer?
    private var ports: [UInt16] = []
    private var serial: String?
    private var adb: String?
    private var verifiedAt: Date?

    /// `adb devices` is answered by the adb server on the Mac. Anything with `-s` goes to the tablet's adbd,
    /// which also forwards the streams, and querying it every couple of seconds made audio stutter.
    private let reverifyInterval: TimeInterval = 30

    func start(ports: [UInt16]) {
        queue.async { [self] in
            self.ports = ports
            self.adb = Self.findAdb()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
            self.tick()
        }
    }

    /// Runs synchronously so the tunnels are gone before the app exits.
    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.removeTunnels()
        }
    }

    private func tick() {
        guard let adb else {
            onStatus?("USB needs adb. It was not found in Android platform-tools.")
            return
        }
        let ready = Self.readySerials(Self.run(adb, ["devices"]).output)
        if let current = serial, !ready.contains(current) {
            serial = nil
            verifiedAt = nil
        }
        if serial == nil {
            serial = ready.first
        }
        guard let serial else {
            onStatus?("Plug in the tablet and accept USB debugging.")
            return
        }
        if let verifiedAt, Date().timeIntervalSince(verifiedAt) < reverifyInterval {
            return
        }
        let listed = Self.run(adb, ["-s", serial, "reverse", "--list"])
        if listed.code != 0 {
            self.serial = nil
            verifiedAt = nil
            onStatus?("Plug in the tablet and accept USB debugging.")
            return
        }
        var failed = false
        for port in ports where !listed.output.contains("tcp:\(port) tcp:\(port)") {
            if Self.run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]).code != 0 {
                failed = true
            }
        }
        if failed {
            verifiedAt = nil
            onStatus?("The tablet is plugged in, but the USB tunnel did not open.")
        } else {
            verifiedAt = Date()
            onStatus?("USB cable ready. Open Pane on the tablet.")
        }
    }

    private func removeTunnels() {
        guard let adb, let serial else {
            self.serial = nil
            return
        }
        for port in ports {
            _ = Self.run(adb, ["-s", serial, "reverse", "--remove", "tcp:\(port)"])
        }
        self.serial = nil
    }

    private static func findAdb() -> String? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["ADB"] {
            candidates.append(override)
        }
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.append(home + "/platform-tools/adb")
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func readySerials(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            if fields.count == 1 {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                return parts[0]
            }
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return fields[0]
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
