import Foundation
import Network

enum PaneListener {
    /// The tablet reaches this through adb reverse, which lands on localhost.
    /// Listening only here means a Wi-Fi address cannot connect.
    static func tcpParameters(port: UInt16, keepalive: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let localPort = NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: localPort)
        return parameters
    }
}

final class StreamServer {
    var onHello: ((HelloMessage) -> Void)?
    var onPointer: ((PointerMessage) -> Void)?
    var onScroll: ((Float, Float, ScrollPhase) -> Void)?
    var onPinch: ((PinchMessage) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onListenerState: ((String) -> Void)?

    private let queue = DispatchQueue(label: "app.pane.socket")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = FrameParser()
    private var inflight = false
    private var videoQueue: [QueuedFrame] = []

    private struct QueuedFrame {
        var packet: Data
        var queued: UInt64
    }
    private var dropUntilKeyframe = false
    private var hasClient = false

    /// Frames after a keyframe only describe changes, so none can be skipped.
    /// If the cable falls this far behind, start over from a fresh keyframe instead.
    private let maxQueuedFrames = 3

    func start(port: UInt16) throws {
        let listener = try NWListener(using: PaneListener.tcpParameters(port: port, keepalive: true))
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onListenerState?("ready")
            case .waiting(let error):
                self?.onListenerState?("waiting: \(error.localizedDescription)")
            case .failed(let error):
                self?.onListenerState?("failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.hasClient = false
            self.videoQueue.removeAll()
        }
    }

    func sendHelloAck(width: Int, height: Int, fps: Int) {
        send(PaneCodec.helloAck(width: width, height: height, fps: fps), critical: true)
    }

    func sendVideo(annexB: Data, keyframe: Bool, ptsMicros: UInt64) {
        queue.async { [weak self] in
            guard let self, self.hasClient else { return }
            if self.dropUntilKeyframe && !keyframe { return }
            if keyframe {
                self.dropUntilKeyframe = false
                self.videoQueue.removeAll()
            } else if self.videoQueue.count >= self.maxQueuedFrames {
                PaneStats.shared.record { $0.serverDrops += self.videoQueue.count + 1 }
                self.videoQueue.removeAll()
                self.dropUntilKeyframe = true
                self.onKeyframeRequest?()
                return
            }
            let packet = PaneCodec.video(annexB: annexB, keyframe: keyframe, ptsMicros: ptsMicros)
            self.videoQueue.append(QueuedFrame(packet: packet, queued: PaneStats.now()))
            self.pumpVideo()
        }
    }

    private func pumpVideo() {
        guard !inflight, hasClient, let connection, !videoQueue.isEmpty else { return }
        let frame = videoQueue.removeFirst()
        inflight = true
        sendSlice(of: frame, from: 0, on: connection)
    }

    /// All three connections share one USB pipe through adb, and adb forwards whatever is waiting in one go.
    /// A large frame sent at once (a scene cut can be 1–2 MB) holds the pipe for tens of milliseconds and
    /// audio stutters behind it. Slices about as fast as a USB 2 link let adb slip audio in between.
    /// Ordinary frames fit in one slice and go out immediately.
    private static let sliceBytes = 128 * 1024
    private static let slicePause: DispatchTimeInterval = .microseconds(2_000)

    private func sendSlice(of frame: QueuedFrame, from offset: Int, on connection: NWConnection) {
        let end = min(frame.packet.count, offset + Self.sliceBytes)
        let last = end == frame.packet.count
        let slice = frame.packet.subdata(in: frame.packet.startIndex + offset..<frame.packet.startIndex + end)
        connection.send(content: slice, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if !last {
                self.queue.asyncAfter(deadline: .now() + Self.slicePause) {
                    guard self.connection === connection else { return }
                    self.sendSlice(of: frame, from: end, on: connection)
                }
                return
            }
            PaneStats.shared.record { stats in
                stats.sent += 1
                stats.bytes += frame.packet.count
                stats.sendDelay.add(PaneStats.milliseconds(since: frame.queued))
                stats.sendGap.tick()
            }
            self.queue.async {
                guard self.connection === connection else { return }
                self.inflight = false
                self.pumpVideo()
            }
        })
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        parser = FrameParser()
        inflight = false
        videoQueue.removeAll()
        dropUntilKeyframe = false
        hasClient = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.receive(on: connection)
            case .failed, .cancelled:
                self.dropClient()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                for message in self.parser.append(data) {
                    self.dispatch(message)
                }
            }
            guard self.connection === connection else { return }
            if isComplete || error != nil {
                connection.cancel()
                self.dropClient()
                return
            }
            self.receive(on: connection)
        }
    }

    private func dropClient() {
        guard connection != nil else { return }
        hasClient = false
        connection = nil
        videoQueue.removeAll()
        inflight = false
        onDisconnect?()
    }

    private func dispatch(_ message: InboundMessage) {
        switch message {
        case .hello(let hello):
            hasClient = true
            onHello?(hello)
        case .pointer(let pointer):
            onPointer?(pointer)
        case .scroll(let dx, let dy, let phase):
            onScroll?(dx, dy, phase)
        case .pinch(let pinch):
            onPinch?(pinch)
        case .keyframeRequest:
            onKeyframeRequest?()
        case .goodbye:
            connection?.cancel()
            dropClient()
        }
    }

    private func send(_ packet: Data, critical: Bool) {
        queue.async {
            guard self.hasClient || critical else { return }
            self.connection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
}
