package app.pane.tablet

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.util.ArrayDeque

/**
 * Hardware H.264 decoder. Frames that arrive before the surface or the
 * parameter sets are kept only until the next keyframe, so a late join
 * still starts on a complete picture.
 */
internal class H264Decoder(
    private val onFirstFrame: () -> Unit,
    private val onError: (String) -> Unit,
    private val onNeedKeyframe: () -> Unit
) {
    private val thread = HandlerThread("pane-decoder").also { it.start() }
    private val handler = Handler(thread.looper)
    private val pending = ArrayDeque<ByteArray>()
    private var surface: Surface? = null
    private var width = 0
    private var height = 0
    private var codec: MediaCodec? = null
    private var inputIndices = ArrayDeque<Int>()
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var started = false
    private var rendered = false
    private var closed = false
    private var waitingForKeyframe = false
    private var lastKeyframeAsk = 0L
    private var inCodec = 0
    private var nextPtsUs = 0L
    private val queuedAt = HashMap<Long, Long>()

    fun setSurface(surface: Surface?) {
        handler.post {
            this.surface = surface
            if (surface == null) {
                releaseCodec()
            } else {
                tryStart()
            }
        }
    }

    fun setDimensions(width: Int, height: Int) {
        handler.post {
            if (width <= 0 || height <= 0) return@post
            if (this.width != width || this.height != height) {
                this.width = width
                this.height = height
                releaseCodec()
                tryStart()
            }
        }
    }

    fun submit(annexB: ByteArray, keyframe: Boolean) {
        handler.post {
            if (closed) return@post
            val split = NalUnits.split(annexB)
            if (split.sps != null) sps = split.sps
            if (split.pps != null) pps = split.pps
            val vcl = split.vcl ?: return@post
            if (!started) {
                if (!keyframe && pending.isEmpty()) {
                    // The decoder was rebuilt, for example after returning to the app. Do not wait for the next scheduled keyframe.
                    if (surface != null) askKeyframe()
                    return@post
                }
                pending.clear()
                if (keyframe) pending.add(vcl)
                tryStart()
                return@post
            }
            if (keyframe) {
                waitingForKeyframe = false
                pending.clear()
                pending.add(vcl)
                pump()
                return@post
            }
            if (waitingForKeyframe) return@post
            pending.add(vcl)
            // A burst from the cable decodes faster than real time, so only give up on a real backlog.
            if (pending.size > 8) {
                TabletStats.dropped(pending.size)
                pending.clear()
                waitingForKeyframe = true
                askKeyframe()
                return@post
            }
            pump()
        }
    }

    fun release() {
        handler.post {
            closed = true
            releaseCodec()
            thread.quitSafely()
        }
    }

    private fun tryStart() {
        if (started || closed) return
        val surface = surface ?: return
        val sps = sps ?: return
        val pps = pps ?: return
        if (width <= 0 || height <= 0 || !surface.isValid) return
        var last: Exception? = null
        for (level in Tuning.entries) {
            try {
                startCodec(surface, sps, pps, level)
                if (TabletStats.enabled) android.util.Log.d("PaneStats", "decoder ${codec?.name} tuning $level")
                return
            } catch (error: Exception) {
                last = error
                releaseCodec()
            }
        }
        onError("Decoder failed to start. ${last?.message ?: "unknown error"}")
    }

    /** Tried in order until the decoder accepts one. */
    private enum class Tuning { Qualcomm, Standard, Plain }

    private fun startCodec(surface: Surface, sps: ByteArray, pps: ByteArray, tuning: Tuning) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(sps))
        format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(pps))
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4_000_000)
        if (tuning != Tuning.Plain) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            if (Build.VERSION.SDK_INT >= 30) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }
        if (tuning == Tuning.Qualcomm) {
            // Output each frame as soon as it is decoded instead of holding it for display reordering.
            format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        }
        val codec = createDecoder()
        try {
            codec.setCallback(callback, handler)
            codec.configure(format, surface, null, 0)
            codec.start()
        } catch (error: Exception) {
            try {
                codec.release()
            } catch (_: Exception) {
            }
            throw error
        }
        this.codec = codec
        started = true
        if (Build.VERSION.SDK_INT >= 30) {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_LOW_LATENCY, 1)
            codec.setParameters(params)
        }
        pump()
    }

    private fun askKeyframe() {
        val now = System.nanoTime()
        if (now - lastKeyframeAsk < 80_000_000L) return
        lastKeyframeAsk = now
        onNeedKeyframe()
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            if (codec !== this@H264Decoder.codec) return
            inputIndices.add(index)
            pump()
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (codec !== this@H264Decoder.codec) return
            inCodec = (inCodec - 1).coerceAtLeast(0)
            val render = info.size > 0
            if (render) {
                // A timestamp of "now" lets the compositor skip older frames when several land in one refresh.
                codec.releaseOutputBuffer(index, System.nanoTime())
            } else {
                codec.releaseOutputBuffer(index, false)
            }
            if (TabletStats.enabled) {
                queuedAt.remove(info.presentationTimeUs)?.let { if (render) TabletStats.rendered(it) }
            }
            if (render && !rendered) {
                rendered = true
                onFirstFrame()
            }
            pump()
        }

        override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
            if (codec !== this@H264Decoder.codec) return
            releaseCodec()
            onError("Decoder error. ${error.message ?: "codec reset"}")
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit
    }

    private fun pump() {
        val codec = codec ?: return
        while (inputIndices.isNotEmpty() && pending.isNotEmpty() && inCodec < 3) {
            val index = inputIndices.removeFirst()
            val frame = pending.removeFirst()
            val buffer = codec.getInputBuffer(index)
            if (buffer == null || frame.size > buffer.capacity()) {
                codec.queueInputBuffer(index, 0, 0, 0, 0)
                continue
            }
            buffer.clear()
            buffer.put(frame)
            val pts = nextPtsUs
            nextPtsUs += 16_667
            if (TabletStats.enabled) {
                if (queuedAt.size > 64) queuedAt.clear()
                queuedAt[pts] = android.os.SystemClock.elapsedRealtimeNanos()
            }
            codec.queueInputBuffer(index, 0, frame.size, pts, 0)
            inCodec += 1
        }
    }

    private fun createDecoder(): MediaCodec {
        val preferred = lowLatencyDecoderName()
        if (preferred != null) {
            try {
                return MediaCodec.createByCodecName(preferred)
            } catch (_: Exception) {
            }
        }
        return MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    }

    private fun lowLatencyDecoderName(): String? {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        var hardware: String? = null
        for (info in list.codecInfos) {
            if (info.isEncoder) continue
            if (info.supportedTypes.none { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true) }) continue
            val name = info.name
            val lower = name.lowercase()
            if (lower.contains("low_latency") || lower.contains("lowlatency")) return name
            if (hardware == null && (lower.contains("qti") || lower.contains("qcom") || lower.contains("exynos")) && !lower.contains("secure")) {
                hardware = name
            }
        }
        return hardware
    }

    private fun releaseCodec() {
        val codec = codec ?: run {
            started = false
            return
        }
        this.codec = null
        started = false
        rendered = false
        inCodec = 0
        nextPtsUs = 0
        queuedAt.clear()
        inputIndices.clear()
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        try {
            codec.release()
        } catch (_: Exception) {
        }
    }
}
