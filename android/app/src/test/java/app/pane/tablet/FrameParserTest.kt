package app.pane.tablet

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class FrameParserTest {
    @Test
    fun readsAVideoFrameAndACursorFromOneChunk() {
        val annex = byteArrayOf(0, 0, 0, 1, 0x65)
        val video = frame(Protocol.VIDEO, videoPayload(keyframe = true, pts = 42L, annex = annex))
        val cursor = frame(Protocol.CURSOR_POSITION, cursorPayload(visible = true, x = 0.25f, y = 0.5f))
        val messages = FrameParser().append(video + cursor)
        val picture = messages[0] as Inbound.Video
        val pointer = messages[1] as Inbound.CursorPosition
        assertTrue(picture.keyframe)
        assertEquals(42L, picture.ptsMicros)
        assertArrayEquals(annex, picture.annexB)
        assertTrue(pointer.visible)
        assertEquals(0.25f, pointer.x, 0.0001f)
        assertEquals(0.5f, pointer.y, 0.0001f)
    }

    @Test
    fun waitsForTheRestOfASplitMessage() {
        val packet = frame(Protocol.AUDIO_FORMAT, audioFormatPayload(rate = 48_000, channels = 2))
        val parser = FrameParser()
        assertTrue(parser.append(packet.copyOfRange(0, 3)).isEmpty())
        val message = parser.append(packet.copyOfRange(3, packet.size)).single() as Inbound.AudioFormat
        assertEquals(48_000, message.sampleRate)
        assertEquals(2, message.channels)
    }

    @Test
    fun aBadLengthDoesNotSwallowTheNextMessage() {
        val bad = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(Protocol.MAX_PAYLOAD + 1).array()
        val parser = FrameParser()
        assertTrue(parser.append(bad).isEmpty())
        val audio = parser.append(frame(Protocol.AUDIO, byteArrayOf(1, 2, 3, 4))).single() as Inbound.Audio
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), audio.pcm)
    }

    private fun videoPayload(keyframe: Boolean, pts: Long, annex: ByteArray): ByteArray {
        val payload = ByteBuffer.allocate(1 + 8 + annex.size).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(if (keyframe) 1 else 0)
        payload.putLong(pts)
        payload.put(annex)
        return payload.array()
    }

    private fun cursorPayload(visible: Boolean, x: Float, y: Float): ByteArray {
        val payload = ByteBuffer.allocate(1 + 8).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(if (visible) 1 else 0)
        payload.putFloat(x)
        payload.putFloat(y)
        return payload.array()
    }

    private fun audioFormatPayload(rate: Int, channels: Int): ByteArray {
        val payload = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(rate)
        payload.put(channels.toByte())
        return payload.array()
    }

    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val out = ByteBuffer.allocate(4 + 1 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        out.putInt(payload.size + 1)
        out.put(type.toByte())
        out.put(payload)
        return out.array()
    }
}
