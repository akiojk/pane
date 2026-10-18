package app.pane.tablet

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioClockTest {
    @Test
    fun keepsPacketsNearTheTarget() {
        assertEquals(AudioClock.Plan.Keep, AudioClock.plan(1_000.0, playing = false))
        assertEquals(AudioClock.Plan.Keep, AudioClock.plan(40.0, playing = true))
        assertEquals(AudioClock.Plan.Keep, AudioClock.plan(46.0, playing = true))
        assertEquals(AudioClock.Plan.Keep, AudioClock.plan(34.0, playing = true))
    }

    @Test
    fun removesSamplesAsTheBufferGrows() {
        assertEquals(AudioClock.Plan.RemoveOne, AudioClock.plan(46.1, playing = true))
        assertEquals(AudioClock.Plan.RemoveOne, AudioClock.plan(55.0, playing = true))
        assertEquals(AudioClock.Plan.RemoveTwo, AudioClock.plan(55.1, playing = true))
        assertEquals(AudioClock.Plan.RemoveTwo, AudioClock.plan(60.0, playing = true))
        assertEquals(AudioClock.Plan.Skip, AudioClock.plan(60.1, playing = true))
    }

    @Test
    fun repeatsSamplesAsTheBufferShrinks() {
        assertEquals(AudioClock.Plan.RepeatOne, AudioClock.plan(33.9, playing = true))
        assertEquals(AudioClock.Plan.RepeatOne, AudioClock.plan(25.0, playing = true))
        assertEquals(AudioClock.Plan.RepeatTwo, AudioClock.plan(24.9, playing = true))
    }

    @Test
    fun dropsOrRepeatsOneFrameInTheMiddle() {
        val pcm = packet(8)
        val dropped = AudioClock.adjust(pcm, bytesPerFrame = 4, remove = true, count = 1)
        val repeated = AudioClock.adjust(pcm, bytesPerFrame = 4, remove = false, count = 1)
        assertArrayEquals(packet(0, 1, 2, 3, 5, 6, 7), dropped)
        assertArrayEquals(packet(0, 1, 2, 3, 4, 4, 5, 6, 7), repeated)
    }

    @Test
    fun leavesAPacketAloneWhenItIsTooShortToAdjust() {
        val pcm = packet(3)
        assertArrayEquals(pcm, AudioClock.adjust(pcm, bytesPerFrame = 4, remove = true, count = 1))
    }

    private fun packet(count: Int): ByteArray {
        val pcm = ByteArray(count * 4)
        for (index in 0 until count) writeFrame(pcm, index, index)
        return pcm
    }

    private fun packet(vararg indexes: Int): ByteArray {
        val pcm = ByteArray(indexes.size * 4)
        indexes.forEachIndexed { position, index -> writeFrame(pcm, position, index) }
        return pcm
    }

    private fun writeFrame(pcm: ByteArray, position: Int, index: Int) {
        pcm[position * 4] = index.toByte()
        pcm[position * 4 + 2] = (index + 100).toByte()
    }
}
