package app.pane.tablet

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.hypot

/**
 * Maps touches on the tablet into Mac input, the way a touchscreen would feel.
 *
 * Fingers: tap clicks, drag scrolls with momentum, press and hold then drag is a mouse drag
 * (move windows, select text), two-finger tap right-clicks, two-finger drag also scrolls,
 * and spreading or pinching two fingers zooms like a trackpad pinch.
 * S Pen: a precise pointer. Hover moves, touching clicks and drags, the side button right-clicks.
 */
internal class TouchRelay(
    private val view: View,
    private val sendPointer: (phase: Int, tool: Int, pointerId: Int, x: Float, y: Float, pressure: Float) -> Unit,
    private val sendScroll: (dx: Float, dy: Float, phase: Int) -> Unit,
    private val sendPinch: (phase: Int, magnification: Float, x: Float, y: Float) -> Unit
) {
    var videoWidth = 0
    var videoHeight = 0

    var onLocalCursor: ((Float, Float) -> Unit)? = null
    var drivingCursor: Boolean = false
        private set

    private enum class Mode { Idle, Pending, Scroll, Drag, TwoFinger, Pen, Done }

    /** What a two-finger touch turned into, decided by whichever moves first: the fingers apart, or both together. */
    private enum class TwoFingerKind { Undecided, Scroll, Pinch }

    private val handler = Handler(Looper.getMainLooper())
    private val slop = ViewConfiguration.get(view.context).scaledTouchSlop.toFloat()

    private var mode = Mode.Idle
    private var fingerId = -1
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var twoFingerStart = 0L
    private var twoFingerKind = TwoFingerKind.Undecided
    private var startSpan = 0f
    private var lastSpan = 0f
    private var velocity: VelocityTracker? = null
    private val hold = Runnable { beginDrag() }

    fun onTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> onFirstDown(event)
            MotionEvent.ACTION_POINTER_DOWN -> onExtraDown(event)
            MotionEvent.ACTION_MOVE -> onMove(event)
            MotionEvent.ACTION_POINTER_UP -> onExtraUp(event)
            MotionEvent.ACTION_UP -> onLastUp(event)
            MotionEvent.ACTION_CANCEL -> onCancel()
        }
        return true
    }

    fun onHover(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT) {
            drivingCursor = false
            return true
        }
        if (event.actionMasked != MotionEvent.ACTION_HOVER_MOVE) return false
        if (event.getToolType(0) != MotionEvent.TOOL_TYPE_STYLUS) return false
        if (mode != Mode.Idle) return false
        drivingCursor = true
        emitPointer(Protocol.PHASE_MOVE, Protocol.TOOL_PEN, event.getPointerId(0), event.getX(0), event.getY(0), event.getPressure(0))
        return true
    }

    private fun onFirstDown(event: MotionEvent) {
        reset()
        drivingCursor = true
        fingerId = event.getPointerId(0)
        downX = event.x
        downY = event.y
        lastX = downX
        lastY = downY
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
            if (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) {
                emitPointer(Protocol.PHASE_RIGHT_CLICK, Protocol.TOOL_PEN, fingerId, downX, downY, 1f)
                mode = Mode.Done
            } else {
                mode = Mode.Pen
                emitPointer(Protocol.PHASE_DOWN, Protocol.TOOL_PEN, fingerId, downX, downY, event.pressure)
            }
            return
        }
        // Put the Mac pointer under the finger without clicking, so a scroll lands on what was touched.
        mode = Mode.Pending
        emitPointer(Protocol.PHASE_MOVE, Protocol.TOOL_FINGER, fingerId, downX, downY, 0f)
        velocity = VelocityTracker.obtain().also { it.addMovement(event) }
        handler.postDelayed(hold, GestureRules.holdMillis)
    }

    private fun onExtraDown(event: MotionEvent) {
        if (mode != Mode.Pending && mode != Mode.Scroll) return
        if (fingers(event) != 2) return
        handler.removeCallbacks(hold)
        if (mode == Mode.Scroll) sendScroll(0f, 0f, Protocol.SCROLL_CANCELLED)
        mode = Mode.TwoFinger
        twoFingerStart = SystemClock.uptimeMillis()
        twoFingerKind = TwoFingerKind.Undecided
        val (cx, cy) = centroid(event)
        downX = cx
        downY = cy
        lastX = cx
        lastY = cy
        startSpan = span(event)
        lastSpan = startSpan
        velocity?.clear()
    }

    private fun onMove(event: MotionEvent) {
        velocity?.addMovement(event)
        when (mode) {
            Mode.Pending -> {
                val index = event.findPointerIndex(fingerId)
                if (index < 0) return
                val x = event.getX(index)
                val y = event.getY(index)
                if (!GestureRules.becameScroll(hypot(x - downX, y - downY), slop)) return
                handler.removeCallbacks(hold)
                mode = Mode.Scroll
                scrollBy(x - downX, y - downY, Protocol.SCROLL_BEGAN)
                lastX = x
                lastY = y
            }
            Mode.Scroll -> {
                val index = event.findPointerIndex(fingerId)
                if (index < 0) return
                val x = event.getX(index)
                val y = event.getY(index)
                scrollBy(x - lastX, y - lastY, Protocol.SCROLL_CHANGED)
                lastX = x
                lastY = y
            }
            Mode.TwoFinger -> {
                val (cx, cy) = centroid(event)
                val spread = span(event)
                when (twoFingerKind) {
                    TwoFingerKind.Undecided -> {
                        val spreadChange = kotlin.math.abs(spread - startSpan)
                        val travel = hypot(cx - downX, cy - downY)
                        when (GestureRules.twoFinger(spreadChange, travel, startSpan, slop)) {
                            GestureRules.TwoFinger.Undecided -> return
                            GestureRules.TwoFinger.Pinch -> {
                                twoFingerKind = TwoFingerKind.Pinch
                                pinch(Protocol.SCROLL_BEGAN, spread / startSpan - 1f, cx, cy)
                                lastSpan = spread
                            }
                            GestureRules.TwoFinger.Scroll -> {
                                twoFingerKind = TwoFingerKind.Scroll
                                scrollBy(cx - downX, cy - downY, Protocol.SCROLL_BEGAN)
                            }
                        }
                    }
                    TwoFingerKind.Scroll -> scrollBy(cx - lastX, cy - lastY, Protocol.SCROLL_CHANGED)
                    TwoFingerKind.Pinch -> {
                        if (lastSpan > 0f && spread != lastSpan) {
                            pinch(Protocol.SCROLL_CHANGED, spread / lastSpan - 1f, cx, cy)
                            lastSpan = spread
                        }
                    }
                }
                lastX = cx
                lastY = cy
            }
            Mode.Drag, Mode.Pen -> {
                val index = event.findPointerIndex(fingerId)
                if (index < 0) return
                val x = event.getX(index)
                val y = event.getY(index)
                if (x == lastX && y == lastY) return
                val tool = if (mode == Mode.Pen) Protocol.TOOL_PEN else Protocol.TOOL_FINGER
                emitPointer(Protocol.PHASE_MOVE, tool, fingerId, x, y, event.getPressure(index))
            }
            else -> Unit
        }
    }

    private fun onExtraUp(event: MotionEvent) {
        if (mode != Mode.TwoFinger || fingers(event) - 1 >= 2) return
        when (twoFingerKind) {
            TwoFingerKind.Scroll -> endScroll()
            TwoFingerKind.Pinch -> pinch(Protocol.SCROLL_ENDED, 0f, lastX, lastY)
            TwoFingerKind.Undecided -> if (GestureRules.twoFingerTap(SystemClock.uptimeMillis() - twoFingerStart)) {
                emitPointer(Protocol.PHASE_RIGHT_CLICK, Protocol.TOOL_FINGER, fingerId, downX, downY, 1f)
            }
        }
        mode = Mode.Done
    }

    private fun onLastUp(event: MotionEvent) {
        handler.removeCallbacks(hold)
        velocity?.addMovement(event)
        when (mode) {
            Mode.Pending -> {
                emitPointer(Protocol.PHASE_DOWN, Protocol.TOOL_FINGER, fingerId, downX, downY, 1f)
                emitPointer(Protocol.PHASE_UP, Protocol.TOOL_FINGER, fingerId, downX, downY, 0f)
            }
            Mode.Scroll -> endScroll()
            Mode.Drag -> emitPointer(Protocol.PHASE_UP, Protocol.TOOL_FINGER, fingerId, event.x, event.y, 0f)
            Mode.Pen -> emitPointer(Protocol.PHASE_UP, Protocol.TOOL_PEN, fingerId, event.x, event.y, 0f)
            else -> Unit
        }
        reset()
        drivingCursor = false
    }

    private fun onCancel() {
        handler.removeCallbacks(hold)
        when (mode) {
            Mode.Scroll -> sendScroll(0f, 0f, Protocol.SCROLL_CANCELLED)
            Mode.TwoFinger -> when (twoFingerKind) {
                TwoFingerKind.Scroll -> sendScroll(0f, 0f, Protocol.SCROLL_CANCELLED)
                TwoFingerKind.Pinch -> pinch(Protocol.SCROLL_CANCELLED, 0f, lastX, lastY)
                TwoFingerKind.Undecided -> Unit
            }
            Mode.Drag, Mode.Pen -> emitPointer(Protocol.PHASE_CANCEL, Protocol.TOOL_FINGER, fingerId, lastX, lastY, 0f)
            else -> Unit
        }
        reset()
        drivingCursor = false
    }

    /** Press and hold without moving: from here the finger drags like a held mouse button. */
    private fun beginDrag() {
        if (mode != Mode.Pending) return
        mode = Mode.Drag
        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        emitPointer(Protocol.PHASE_DOWN, Protocol.TOOL_FINGER, fingerId, downX, downY, 1f)
    }

    private fun endScroll() {
        val tracker = velocity
        val content = contentRect()
        if (tracker == null || content.width <= 1f || content.height <= 1f) {
            sendScroll(0f, 0f, Protocol.SCROLL_CANCELLED)
            return
        }
        tracker.computeCurrentVelocity(1000)
        // With two fingers, the first finger stands in for the pair.
        val vx = tracker.getXVelocity(fingerId)
        val vy = tracker.getYVelocity(fingerId)
        sendScroll(vx / content.width, vy / content.height, Protocol.SCROLL_ENDED)
    }

    private fun pinch(phase: Int, magnification: Float, x: Float, y: Float) {
        val content = contentRect()
        if (content.width <= 1f || content.height <= 1f) return
        val nx = ((x - content.x) / content.width).coerceIn(0f, 1f)
        val ny = ((y - content.y) / content.height).coerceIn(0f, 1f)
        sendPinch(phase, magnification, nx, ny)
    }

    private fun span(event: MotionEvent): Float {
        val lifting = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP) event.actionIndex else -1
        val points = ArrayList<Pair<Float, Float>>(2)
        for (index in 0 until event.pointerCount) {
            if (index == lifting || event.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS) continue
            points.add(event.getX(index) to event.getY(index))
            if (points.size == 2) break
        }
        if (points.size < 2) return 0f
        return hypot(points[0].first - points[1].first, points[0].second - points[1].second)
    }

    private fun scrollBy(dx: Float, dy: Float, phase: Int) {
        val content = contentRect()
        if (content.width <= 1f || content.height <= 1f) return
        sendScroll(dx / content.width, dy / content.height, phase)
    }

    private fun emitPointer(phase: Int, tool: Int, id: Int, x: Float, y: Float, pressure: Float) {
        val (nx, ny) = normalize(x, y) ?: return
        val clamped = if (tool == Protocol.TOOL_PEN) pressure else 1f
        onLocalCursor?.invoke(nx, ny)
        lastX = x
        lastY = y
        sendPointer(phase, tool, id, nx, ny, clamped)
    }

    private fun reset() {
        handler.removeCallbacks(hold)
        mode = Mode.Idle
        fingerId = -1
        twoFingerKind = TwoFingerKind.Undecided
        velocity?.recycle()
        velocity = null
    }

    private fun fingers(event: MotionEvent): Int {
        var count = 0
        for (index in 0 until event.pointerCount) {
            if (event.getToolType(index) != MotionEvent.TOOL_TYPE_STYLUS) count++
        }
        return count
    }

    private fun centroid(event: MotionEvent): Pair<Float, Float> {
        var x = 0f
        var y = 0f
        var count = 0
        val lifting = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP) event.actionIndex else -1
        for (index in 0 until event.pointerCount) {
            if (index == lifting || event.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS) continue
            x += event.getX(index)
            y += event.getY(index)
            count++
        }
        if (count == 0) return event.x to event.y
        return x / count to y / count
    }

    private fun normalize(x: Float, y: Float): Pair<Float, Float>? {
        val content = contentRect()
        if (content.width <= 1f || content.height <= 1f) return null
        val nx = (x - content.x) / content.width
        val ny = (y - content.y) / content.height
        if (nx < 0f || ny < 0f || nx > 1f || ny > 1f) return null
        return nx to ny
    }

    private fun contentRect(): VideoLayout.Rect {
        return VideoLayout.content(
            view.width.toFloat().coerceAtLeast(1f),
            view.height.toFloat().coerceAtLeast(1f),
            videoWidth,
            videoHeight
        )
    }
}
