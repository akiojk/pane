package app.pane.tablet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View

/**
 * Debug builds only: plays two-finger gestures into the touch layer, so gestures that adb's
 * `input` command cannot produce can still be tested end to end.
 *
 * adb shell am broadcast -a app.pane.tablet.GESTURE --es name pinch   (also: tap2, scroll2)
 */
internal class GestureProbe(private val target: View) {
    private val handler = Handler(Looper.getMainLooper())

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            play(intent.getStringExtra("name") ?: return)
        }
    }

    fun register(context: Context) {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val filter = IntentFilter("app.pane.tablet.GESTURE")
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    fun unregister(context: Context) {
        try {
            context.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
    }

    private fun play(name: String) {
        val cx = target.width / 2f
        val cy = target.height / 2f
        // Each frame is the two finger positions. Fingers sit side by side along x.
        val frames: List<Pair<Pair<Float, Float>, Pair<Float, Float>>> = when (name) {
            "tap2" -> List(5) { (cx - 150 to cy) to (cx + 150 to cy) }
            "pinch" -> List(31) { i -> val d = 150f + i * 15; (cx - d to cy) to (cx + d to cy) }
            "scroll2" -> List(31) { i -> val y = cy + 250 - i * 20; (cx - 150 to y) to (cx + 150 to y) }
            else -> return
        }
        val down = SystemClock.uptimeMillis()
        frames.forEachIndexed { index, (a, b) ->
            handler.postAtTime({
                val time = SystemClock.uptimeMillis()
                when (index) {
                    0 -> {
                        dispatch(down, time, MotionEvent.ACTION_DOWN, listOf(a))
                        dispatch(down, time, MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), listOf(a, b))
                    }
                    frames.lastIndex -> {
                        dispatch(down, time, MotionEvent.ACTION_MOVE, listOf(a, b))
                        dispatch(down, time, MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), listOf(a, b))
                        dispatch(down, time, MotionEvent.ACTION_UP, listOf(a))
                    }
                    else -> dispatch(down, time, MotionEvent.ACTION_MOVE, listOf(a, b))
                }
            }, down + index * 16L)
        }
    }

    private fun dispatch(down: Long, time: Long, action: Int, points: List<Pair<Float, Float>>) {
        val properties = Array(points.size) { i ->
            MotionEvent.PointerProperties().apply {
                id = i
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(points.size) { i ->
            MotionEvent.PointerCoords().apply {
                x = points[i].first
                y = points[i].second
                pressure = 1f
                size = 0.05f
            }
        }
        val event = MotionEvent.obtain(down, time, action, points.size, properties, coords, 0, 0, 1f, 1f, 0, 0, 0, 0)
        target.dispatchTouchEvent(event)
        event.recycle()
    }
}
