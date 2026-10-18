import CoreGraphics
import Foundation
import Network

/// Carries the pointer both ways on its own TCP connection so it is not stuck behind a video frame.
/// The Mac sends position and shape. The tablet sends touch and scroll.
final class CursorRelay {
    var onPointer: ((PointerMessage) -> Void)?
    var onScroll: ((Float, Float, ScrollPhase) -> Void)?
    var onPinch: ((PinchMessage) -> Void)?

    private let queue = DispatchQueue(label: "app.pane.cursor")
    private var parser = FrameParser()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var displayID: CGDirectDisplayID = 0
    private var lastX: Float = -1
    private var lastY: Float = -1
    private var lastVisible = false
    private var sendBusy = false
    private var pendingPosition: Data?
    private var pendingShape: Data?
    private var currentShape: CursorShape?

    struct CursorShape {
        var png: Data
        var hotspot: CGPoint
        var size: CGSize
    }

    func start(port: UInt16) {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = PaneListener.tcpParameters(port: port, keepalive: false)
            guard let listener = try? NWListener(using: parameters) else { return }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func setDisplay(_ id: CGDirectDisplayID) {
        queue.async {
            self.displayID = id
            self.lastX = -1
            self.queueShape()
        }
    }

    /// Hotspot and size are in points, the same units as the display bounds.
    func setShape(_ shape: CursorShape) {
        queue.async {
            self.currentShape = shape
            self.queueShape()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.displayID = 0
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        parser = FrameParser()
        sendBusy = false
        pendingPosition = nil
        lastX = -1
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            self?.queue.async {
                guard let self, self.connection === connection else { return }
                self.queueShape()
                self.flush()
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func queueShape() {
        guard let shape = currentShape, displayID != 0 else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 1, bounds.height > 1 else { return }
        pendingShape = PaneCodec.cursorShape(
            hotX: Float(shape.hotspot.x / bounds.width),
            hotY: Float(shape.hotspot.y / bounds.height),
            width: Float(shape.size.width / bounds.width),
            height: Float(shape.size.height / bounds.height),
            png: shape.png
        )
        flush()
    }

    private func tick() {
        guard let connection, connection.state == .ready, displayID != 0 else { return }
        guard let event = CGEvent(source: nil) else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 1, bounds.height > 1 else { return }
        let point = event.location
        let x = Float((point.x - bounds.origin.x) / bounds.width)
        let y = Float((point.y - bounds.origin.y) / bounds.height)
        let visible = x >= 0 && y >= 0 && x <= 1 && y <= 1
        if visible == lastVisible && abs(x - lastX) < 0.0004 && abs(y - lastY) < 0.0004 { return }
        lastX = x
        lastY = y
        lastVisible = visible
        pendingPosition = PaneCodec.cursorPosition(visible: visible, x: min(1, max(0, x)), y: min(1, max(0, y)))
        flush()
    }

    /// One write at a time, newest data only. A shape goes before the position that uses it.
    private func flush() {
        guard !sendBusy, let connection, connection.state == .ready else { return }
        let packet: Data
        if let shape = pendingShape {
            packet = shape
            pendingShape = nil
        } else if let position = pendingPosition {
            packet = position
            pendingPosition = nil
        } else {
            return
        }
        sendBusy = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.queue.async {
                guard let self, self.connection === connection else { return }
                self.sendBusy = false
                self.flush()
            }
        })
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, self.connection === connection, error == nil else { return }
                if let data, !data.isEmpty {
                    for message in self.parser.append(data) {
                        switch message {
                        case .pointer(let pointer):
                            self.onPointer?(pointer)
                        case .scroll(let dx, let dy, let phase):
                            self.onScroll?(dx, dy, phase)
                        case .pinch(let pinch):
                            self.onPinch?(pinch)
                        default:
                            break
                        }
                    }
                }
                if isComplete { return }
                self.receiveLoop(connection)
            }
        }
    }
}
