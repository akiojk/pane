package app.pane.tablet

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

internal object Protocol {
    const val HELLO: Int = 1
    const val HELLO_ACK: Int = 2
    const val VIDEO: Int = 3
    const val POINTER: Int = 4
    const val SCROLL: Int = 5
    const val KEYFRAME_REQUEST: Int = 6
    const val GOODBYE: Int = 7
    const val CURSOR_POSITION: Int = 8
    const val CURSOR_SHAPE: Int = 9
    const val PINCH: Int = 10
    const val AUDIO_FORMAT: Int = 11
    const val AUDIO: Int = 12
    /** Empty reply that makes the tablet's TCP acknowledge right away. The Mac ignores it. */
    const val ACK: Int = 13
    const val MAX_PAYLOAD = 8_000_000

    const val PHASE_MOVE = 0
    const val PHASE_DOWN = 1
    const val PHASE_UP = 2
    const val PHASE_CANCEL = 3
    const val PHASE_RIGHT_CLICK = 4

    const val SCROLL_BEGAN = 1
    const val SCROLL_CHANGED = 2
    /** dx and dy carry the fling velocity in display fractions per second. */
    const val SCROLL_ENDED = 3
    const val SCROLL_CANCELLED = 4

    const val TOOL_FINGER = 0
    const val TOOL_PEN = 1

    fun hello(name: String, width: Int, height: Int, refresh: Int, capabilities: Int, densityDpi: Int): ByteArray {
        val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
        val payload = ByteBuffer.allocate(2 + nameBytes.size + 2 + 2 + 2 + 1 + 2).order(ByteOrder.LITTLE_ENDIAN)
        payload.putShort(nameBytes.size.toShort())
        payload.put(nameBytes)
        payload.putShort(width.toShort())
        payload.putShort(height.toShort())
        payload.putShort(refresh.toShort())
        payload.put(capabilities.toByte())
        payload.putShort(densityDpi.toShort())
        return frame(HELLO, payload.array())
    }

    fun pointer(phase: Int, tool: Int, pointerId: Int, x: Float, y: Float, pressure: Float): ByteArray {
        val payload = ByteBuffer.allocate(1 + 1 + 2 + 4 + 4 + 4).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(phase.toByte())
        payload.put(tool.toByte())
        payload.putShort(pointerId.toShort())
        payload.putFloat(x)
        payload.putFloat(y)
        payload.putFloat(pressure)
        return frame(POINTER, payload.array())
    }

    /** dx and dy are fractions of the display, positive right and down, following the finger. */
    fun scroll(dx: Float, dy: Float, phase: Int): ByteArray {
        val payload = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
        payload.putFloat(dx)
        payload.putFloat(dy)
        payload.put(phase.toByte())
        return frame(SCROLL, payload.array())
    }

    /**
     * A two-finger pinch. [phase] uses the scroll phase values. [magnification] is the change since
     * the last message, 0.05 meaning 5% larger. [x] and [y] are the point between the fingers, normalized.
     */
    fun pinch(phase: Int, magnification: Float, x: Float, y: Float): ByteArray {
        val payload = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(phase.toByte())
        payload.putFloat(magnification)
        payload.putFloat(x)
        payload.putFloat(y)
        return frame(PINCH, payload.array())
    }

    fun keyframeRequest(): ByteArray = frame(KEYFRAME_REQUEST, ByteArray(0))

    fun ack(): ByteArray = frame(ACK, ByteArray(0))

    fun goodbye(): ByteArray = frame(GOODBYE, ByteArray(0))

    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val out = ByteBuffer.allocate(4 + 1 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        out.putInt(payload.size + 1)
        out.put(type.toByte())
        out.put(payload)
        return out.array()
    }
}

internal class FrameParser {
    private var buffer = ByteArray(0)
    private var start = 0

    fun append(chunk: ByteArray): List<Inbound> {
        if (chunk.isEmpty()) return emptyList()
        val combined = ByteArray(buffer.size - start + chunk.size)
        System.arraycopy(buffer, start, combined, 0, buffer.size - start)
        System.arraycopy(chunk, 0, combined, buffer.size - start, chunk.size)
        buffer = combined
        start = 0
        val messages = ArrayList<Inbound>()
        while (buffer.size - start >= 4) {
            val length = readInt(buffer, start)
            if (length <= 0 || length > Protocol.MAX_PAYLOAD) {
                buffer = ByteArray(0)
                start = 0
                break
            }
            val total = 4 + length
            if (buffer.size - start < total) break
            messages.add(decode(buffer, start + 4, length))
            start += total
        }
        if (start > 64 * 1024 && start == buffer.size) {
            buffer = ByteArray(0)
            start = 0
        }
        return messages
    }

    companion object {
        /**
         * Reads one message straight off a blocking stream, so a large video frame is copied once.
         * Returns null when the stream ends.
         */
        fun read(input: java.io.DataInputStream): Inbound? {
            val header = ByteArray(4)
            try {
                input.readFully(header)
            } catch (_: java.io.EOFException) {
                return null
            }
            val length = (header[0].toInt() and 0xFF) or
                ((header[1].toInt() and 0xFF) shl 8) or
                ((header[2].toInt() and 0xFF) shl 16) or
                ((header[3].toInt() and 0xFF) shl 24)
            if (length <= 0 || length > Protocol.MAX_PAYLOAD) throw java.io.IOException("Bad message length $length")
            val body = ByteArray(length)
            input.readFully(body)
            return FrameParser().decode(body, 0, length)
        }
    }

    private fun decode(data: ByteArray, offset: Int, length: Int): Inbound {
        if (length < 1) return Inbound.Ignored
        val type = data[offset].toInt() and 0xFF
        val payload = ByteBuffer.wrap(data, offset + 1, length - 1).order(ByteOrder.LITTLE_ENDIAN)
        return when (type) {
            Protocol.HELLO_ACK -> {
                if (payload.remaining() < 7) return Inbound.Ignored
                Inbound.HelloAck(
                    width = payload.short.toInt() and 0xFFFF,
                    height = payload.short.toInt() and 0xFFFF,
                    fps = payload.short.toInt() and 0xFFFF
                )
            }
            Protocol.VIDEO -> {
                if (payload.remaining() < 9) return Inbound.Ignored
                val flags = payload.get().toInt() and 0xFF
                val pts = payload.long
                val annex = ByteArray(payload.remaining())
                payload.get(annex)
                Inbound.Video(keyframe = flags and 1 != 0, ptsMicros = pts, annexB = annex)
            }
            Protocol.CURSOR_POSITION -> {
                if (payload.remaining() < 9) return Inbound.Ignored
                val visible = payload.get().toInt() and 0xFF != 0
                Inbound.CursorPosition(visible = visible, x = payload.float, y = payload.float)
            }
            Protocol.CURSOR_SHAPE -> {
                if (payload.remaining() < 17) return Inbound.Ignored
                val hotX = payload.float
                val hotY = payload.float
                val width = payload.float
                val height = payload.float
                val png = ByteArray(payload.remaining())
                payload.get(png)
                Inbound.CursorShape(hotX = hotX, hotY = hotY, width = width, height = height, png = png)
            }
            Protocol.AUDIO_FORMAT -> {
                if (payload.remaining() < 5) return Inbound.Ignored
                Inbound.AudioFormat(sampleRate = payload.int, channels = payload.get().toInt() and 0xFF)
            }
            Protocol.AUDIO -> {
                val pcm = ByteArray(payload.remaining())
                payload.get(pcm)
                Inbound.Audio(pcm)
            }
            else -> Inbound.Ignored
        }
    }

    private fun readInt(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8) or
            ((data[offset + 2].toInt() and 0xFF) shl 16) or
            ((data[offset + 3].toInt() and 0xFF) shl 24)
    }
}

internal sealed class Inbound {
    data class HelloAck(val width: Int, val height: Int, val fps: Int) : Inbound()
    data class Video(val keyframe: Boolean, val ptsMicros: Long, val annexB: ByteArray) : Inbound()

    /** Normalized to the Mac display. Not visible means the pointer is on another screen. */
    data class CursorPosition(val visible: Boolean, val x: Float, val y: Float) : Inbound()

    /** Hotspot and size are fractions of the Mac display. */
    class CursorShape(val hotX: Float, val hotY: Float, val width: Float, val height: Float, val png: ByteArray) : Inbound()
    data class AudioFormat(val sampleRate: Int, val channels: Int) : Inbound()

    /** Signed 16-bit little-endian PCM, channels interleaved. */
    class Audio(val pcm: ByteArray) : Inbound()

    data object Ignored : Inbound()
}

internal object NalUnits {
    const val SPS = 7
    const val PPS = 8
    const val IDR = 5

    data class Split(
        val sps: ByteArray?,
        val pps: ByteArray?,
        val vcl: ByteArray?
    )

    fun split(annexB: ByteArray): Split {
        val ranges = startCodeOffsets(annexB)
        if (ranges.isEmpty()) return Split(null, null, null)
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        val vcl = ArrayList<ByteArray>()
        for (i in ranges.indices) {
            val from = ranges[i]
            val to = if (i + 1 < ranges.size) ranges[i + 1] else annexB.size
            if (to <= from) continue
            val header = nalHeaderOffset(annexB, from) ?: continue
            if (header >= to) continue
            val type = annexB[header].toInt() and 0x1F
            val nal = annexB.copyOfRange(from, to)
            when (type) {
                SPS -> sps = nal
                PPS -> pps = nal
                1, IDR -> vcl.add(nal)
            }
        }
        return Split(sps, pps, concat(vcl))
    }

    private fun concat(parts: List<ByteArray>): ByteArray? {
        if (parts.isEmpty()) return null
        val size = parts.sumOf { it.size }
        val out = ByteArray(size)
        var cursor = 0
        for (part in parts) {
            System.arraycopy(part, 0, out, cursor, part.size)
            cursor += part.size
        }
        return out
    }

    /** Offsets of each start code, not the NAL header that follows it. */
    private fun startCodeOffsets(data: ByteArray): List<Int> {
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 3 < data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (i + 3 < data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    starts.add(i)
                    i += 4
                    continue
                }
                if (data[i + 2] == 1.toByte()) {
                    starts.add(i)
                    i += 3
                    continue
                }
            }
            i++
        }
        return starts
    }

    private fun nalHeaderOffset(data: ByteArray, startCode: Int): Int? {
        if (startCode + 4 < data.size &&
            data[startCode + 2] == 0.toByte() &&
            data[startCode + 3] == 1.toByte()
        ) {
            return startCode + 4
        }
        if (startCode + 3 < data.size && data[startCode + 2] == 1.toByte()) {
            return startCode + 3
        }
        return null
    }
}
