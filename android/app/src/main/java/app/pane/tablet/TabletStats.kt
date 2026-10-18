package app.pane.tablet

import android.os.SystemClock
import android.util.Log

/**
 * Per-second decode timings in logcat under the PaneStats tag.
 * Off unless `adb shell setprop log.tag.PaneStats DEBUG`.
 */
internal object TabletStats {
    private const val TAG = "PaneStats"
    val enabled: Boolean = Log.isLoggable(TAG, Log.DEBUG)

    private val lock = Any()
    private var windowStart = SystemClock.elapsedRealtimeNanos()
    private var received = 0
    private var bytes = 0L
    private val arrival = Cadence()
    private var decoded = 0
    private var decodeTotal = 0.0
    private var decodeMax = 0.0
    private val render = Cadence()
    private var dropped = 0

    /** Longest interval and how far intervals stray from an even 60 fps cadence. */
    private class Cadence {
        var last = 0L
        var max = 0.0
        var deviation = 0.0
        var count = 0

        fun tick(now: Long) {
            if (last != 0L) {
                val interval = (now - last) / 1e6
                max = maxOf(max, interval)
                if (interval < 50) {
                    deviation += kotlin.math.abs(interval - 1000.0 / 60)
                    count++
                }
            }
            last = now
        }

        val jitter: Double get() = if (count == 0) 0.0 else deviation / count

        fun reset() {
            max = 0.0
            deviation = 0.0
            count = 0
        }
    }

    fun arrived(size: Int) = record {
        arrival.tick(SystemClock.elapsedRealtimeNanos())
        received++
        bytes += size
    }

    fun rendered(queuedAtNanos: Long) = record {
        val now = SystemClock.elapsedRealtimeNanos()
        val decode = (now - queuedAtNanos) / 1e6
        decoded++
        decodeTotal += decode
        decodeMax = maxOf(decodeMax, decode)
        render.tick(now)
    }

    fun dropped(count: Int) = record { dropped += count }

    private var audioPackets = 0
    private var audioQueuedTotal = 0.0
    private var audioQueuedMax = 0.0
    private var audioQueuedMin = Double.MAX_VALUE
    private var audioUnderruns = 0
    private var audioDrops = 0
    private var audioLastArrival = 0L
    private var audioGapMax = 0.0
    private var audioAdjusted = 0

    /** [queuedMs] is audio written but not yet played. */
    fun audio(queuedMs: Double, underruns: Int) = record {
        val now = SystemClock.elapsedRealtimeNanos()
        if (audioLastArrival != 0L) audioGapMax = maxOf(audioGapMax, (now - audioLastArrival) / 1e6)
        audioLastArrival = now
        audioPackets++
        audioQueuedTotal += queuedMs
        audioQueuedMax = maxOf(audioQueuedMax, queuedMs)
        audioQueuedMin = minOf(audioQueuedMin, queuedMs)
        audioUnderruns = underruns
    }

    /** Frames added or removed to follow clock drift. */
    fun audioAdjusted(frames: Int) = record { audioAdjusted += frames }

    fun audioDropped() = record { audioDrops++ }

    private inline fun record(block: () -> Unit) {
        if (!enabled) return
        synchronized(lock) {
            block()
            val now = SystemClock.elapsedRealtimeNanos()
            if (now - windowStart < 1_000_000_000L) return
            val average = if (decoded == 0) 0.0 else decodeTotal / decoded
            val audioAverage = if (audioPackets == 0) 0.0 else audioQueuedTotal / audioPackets
            Log.d(
                TAG,
                String.format(
                    "received %d %.1fMb gapMax %.1f jitter %.1f | decoded %d decode %.1f/%.1f renderGapMax %.1f jitter %.1f | dropped %d | audio %d packets gapMax %.1f queued %.0f/%.0f/%.0f ms underruns %d drops %d adjusted %d",
                    received, bytes * 8 / 1e6, arrival.max, arrival.jitter,
                    decoded, average, decodeMax, render.max, render.jitter, dropped,
                    audioPackets, audioGapMax, if (audioPackets == 0) 0.0 else audioQueuedMin, audioAverage, audioQueuedMax,
                    audioUnderruns, audioDrops, audioAdjusted
                )
            )
            windowStart = now
            received = 0; bytes = 0; arrival.reset()
            decoded = 0; decodeTotal = 0.0; decodeMax = 0.0; render.reset(); dropped = 0
            audioPackets = 0; audioQueuedTotal = 0.0; audioQueuedMax = 0.0; audioQueuedMin = Double.MAX_VALUE
            audioDrops = 0; audioGapMax = 0.0; audioAdjusted = 0
        }
    }
}
