import ApplicationServices
import CoreGraphics
import Foundation

/// Turns tablet touch into pointer and scroll events on the virtual display.
final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var displayID: CGDirectDisplayID = 0
    private var naturalScroll = true
    private var downIDs = Set<UInt16>()
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 1

    /// Scroll state lives on one queue: gesture deltas, sub-point remainders, and momentum after a fling.
    private let scrollQueue = DispatchQueue(label: "app.pane.scroll")
    private var remainder = CGPoint.zero
    private var momentumTimer: DispatchSourceTimer?
    private var momentumVelocity = CGPoint.zero
    private var momentumLast: TimeInterval = 0
    private var momentumStarted = false

    /// A finger lands less precisely than a mouse, so taps this close count as a double click.
    private let doubleClickDistance: CGFloat = 12
    private let doubleClickInterval: TimeInterval = 0.35

    func setDisplay(_ id: CGDirectDisplayID) {
        lock.lock()
        displayID = id
        downIDs.removeAll()
        lock.unlock()
    }

    func setNaturalScroll(_ enabled: Bool) {
        lock.lock()
        naturalScroll = enabled
        lock.unlock()
    }

    func pointer(_ message: PointerMessage) {
        lock.lock()
        let displayID = self.displayID
        lock.unlock()
        guard displayID != 0, let point = Self.point(x: message.x, y: message.y, displayID: displayID) else {
            return
        }
        if message.phase == 1 || message.phase == 4 {
            scrollQueue.async { self.stopMomentum() }
        }
        if message.phase == 4 {
            post(.mouseMoved, at: point, button: .left, clicks: 0, pressure: 1)
            post(.rightMouseDown, at: point, button: .right, clicks: 1, pressure: 1)
            post(.rightMouseUp, at: point, button: .right, clicks: 1, pressure: 0)
            return
        }

        let type: CGEventType
        var clicks = 1
        lock.lock()
        switch message.phase {
        case 1:
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < doubleClickDistance
            clickCount = now - lastClickTime < doubleClickInterval && near ? min(3, clickCount + 1) : 1
            clicks = clickCount
            lastClickTime = now
            lastClickPoint = point
            downIDs.insert(message.pointerID)
            type = .leftMouseDown
        case 2, 3:
            downIDs.remove(message.pointerID)
            clicks = clickCount
            type = .leftMouseUp
        default:
            type = downIDs.contains(message.pointerID) ? .leftMouseDragged : .mouseMoved
        }
        lock.unlock()

        if type == .leftMouseDown {
            post(.mouseMoved, at: point, button: .left, clicks: 0, pressure: message.pressure)
        }
        post(type, at: point, button: .left, clicks: clicks, pressure: message.pressure)
    }

    func scroll(dx: Float, dy: Float, phase: ScrollPhase) {
        lock.lock()
        let displayID = self.displayID
        let direction: CGFloat = naturalScroll ? 1 : -1
        lock.unlock()
        guard displayID != 0 else { return }
        let bounds = CGDisplayBounds(displayID)
        // Points on the virtual display. Positive follows the finger, so content moves with it.
        let delta = CGPoint(x: CGFloat(dx) * bounds.width * direction, y: CGFloat(dy) * bounds.height * direction)
        scrollQueue.async {
            switch phase {
            case .began:
                self.stopMomentum()
                self.remainder = .zero
                self.postScroll(delta, phase: 1, momentum: 0)
            case .changed, .none:
                self.postScroll(delta, phase: phase == .none ? 0 : 2, momentum: 0)
            case .ended:
                self.postScroll(.zero, phase: 4, momentum: 0)
                self.startMomentum(velocity: delta)
            case .cancelled:
                self.postScroll(.zero, phase: 8, momentum: 0)
            }
        }
    }

    func pinch(_ message: PinchMessage) {
        lock.lock()
        let displayID = self.displayID
        lock.unlock()
        guard displayID != 0, let point = Self.point(x: message.x, y: message.y, displayID: displayID) else { return }
        scrollQueue.async {
            switch message.phase {
            case .began:
                self.stopMomentum()
                // The pinch goes to the window under the pointer, so put it between the fingers first.
                self.post(.mouseMoved, at: point, button: .left, clicks: 0, pressure: 0)
                PanePostMagnify(point, .began, Double(message.magnification))
            case .changed, .none:
                PanePostMagnify(point, .changed, Double(message.magnification))
            case .ended:
                PanePostMagnify(point, .ended, 0)
            case .cancelled:
                PanePostMagnify(point, .cancelled, 0)
            }
        }
    }

    // MARK: - Scroll events

    /// `phase` uses the trackpad values: 1 began, 2 changed, 4 ended, 8 cancelled.
    /// `momentum` is 1 begin, 2 continue, 3 end. Apps treat these like a real trackpad,
    /// with smooth scrolling and rubber banding at the edges.
    private func postScroll(_ delta: CGPoint, phase: Int64, momentum: Int64) {
        let x = delta.x + remainder.x
        let y = delta.y + remainder.y
        let wholeX = Int32(x.rounded(.towardZero))
        let wholeY = Int32(y.rounded(.towardZero))
        remainder = CGPoint(x: x - CGFloat(wholeX), y: y - CGFloat(wholeY))
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: wholeY,
            wheel2: wholeX,
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.post(tap: .cghidEventTap)
    }

    /// Velocity in points per second. Decays like a flick on iOS.
    private func startMomentum(velocity: CGPoint) {
        stopMomentum()
        let limit: CGFloat = 8000
        let clamped = CGPoint(x: max(-limit, min(limit, velocity.x)), y: max(-limit, min(limit, velocity.y)))
        guard hypot(clamped.x, clamped.y) > 150 else { return }
        momentumVelocity = clamped
        momentumLast = ProcessInfo.processInfo.systemUptime
        momentumStarted = false
        let timer = DispatchSource.makeTimerSource(queue: scrollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.momentumTick() }
        timer.resume()
        momentumTimer = timer
    }

    private func momentumTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - momentumLast
        momentumLast = now
        let decay = CGFloat(pow(0.998, elapsed * 1000))
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        if hypot(momentumVelocity.x, momentumVelocity.y) < 20 {
            stopMomentum()
            return
        }
        let step = CGPoint(x: momentumVelocity.x * CGFloat(elapsed), y: momentumVelocity.y * CGFloat(elapsed))
        postScroll(step, phase: 0, momentum: momentumStarted ? 2 : 1)
        momentumStarted = true
    }

    private func stopMomentum() {
        guard let timer = momentumTimer else { return }
        timer.cancel()
        momentumTimer = nil
        if momentumStarted {
            postScroll(.zero, phase: 0, momentum: 3)
        }
        momentumStarted = false
    }

    // MARK: - Pointer events

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int, pressure: Float) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if clicks > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        }
        let clamped = min(1, max(0, pressure))
        event.setDoubleValueField(.mouseEventPressure, value: Double(clamped == 0 ? 1 : clamped))
        event.post(tap: .cghidEventTap)
    }

    private static func point(x: Float, y: Float, displayID: CGDirectDisplayID) -> CGPoint? {
        guard x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        return CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
    }
}
