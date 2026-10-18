package app.pane.tablet

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack

/**
 * Plays the Mac's sound with a short, steady buffer.
 *
 * The Mac and the tablet each have their own audio clock, and the two never run at exactly the same
 * speed. Left alone the buffer slowly fills up (more delay) or runs dry (gaps). Instead of dropping
 * whole packets, which clicks, one sample frame per packet is removed or repeated until the buffer is
 * back near its target. That is under half a percent of speed and cannot be heard.
 */
internal class AudioPlayer {
    private var track: AudioTrack? = null
    private var sampleRate = 48_000
    private var channels = 2
    private var framesWritten = 0L
    private var playing = false

    private fun ms(frames: Long) = frames * 1000.0 / sampleRate

    /** Packets from the cable usually arrive within 10 to 20 ms of each other, and now and then up to about 35. */
    private val targetMs = 40.0
    /** Within this distance of the target, nothing is adjusted. */
    private val bandMs = 6.0
    /** Beyond this distance, two frames per packet are adjusted to get back sooner. */
    private val farMs = 15.0
    /** Far above the target, as after a burst at startup, whole packets are skipped to catch up quickly. */
    private val skipAboveMs = 60.0

    fun configure(rate: Int, channelCount: Int) {
        release()
        sampleRate = rate
        channels = channelCount
        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val bufferBytes = maxOf(minimum, rate * channels * 2 / 5)
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(mask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setBufferSizeInBytes(bufferBytes)
            .build()
        framesWritten = 0
        playing = false
    }

    fun write(pcm: ByteArray) {
        val track = track ?: return
        val bytesPerFrame = channels * 2
        val queuedMs = ms(framesWritten - (track.playbackHeadPosition.toLong() and 0xFFFFFFFFL))
        TabletStats.audio(queuedMs, track.underrunCount)

        var data = pcm
        if (playing) {
            when {
                queuedMs > skipAboveMs -> {
                    TabletStats.audioDropped()
                    return
                }
                queuedMs > targetMs + bandMs -> {
                    val count = if (queuedMs > targetMs + farMs) 2 else 1
                    data = adjust(pcm, bytesPerFrame, remove = true, count = count)
                    TabletStats.audioAdjusted(-count)
                }
                queuedMs < targetMs - bandMs -> {
                    val count = if (queuedMs < targetMs - farMs) 2 else 1
                    data = adjust(pcm, bytesPerFrame, remove = false, count = count)
                    TabletStats.audioAdjusted(count)
                }
            }
        }

        val written = track.write(data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING)
        if (written > 0) framesWritten += written / bytesPerFrame
        if (!playing && ms(framesWritten) >= targetMs) {
            track.play()
            playing = true
        }
    }

    /** Removes or repeats single frames spread evenly through the packet, so no two changes sit together. */
    private fun adjust(pcm: ByteArray, bytesPerFrame: Int, remove: Boolean, count: Int): ByteArray {
        val frames = pcm.size / bytesPerFrame
        if (frames < 4 * count) return pcm
        val output = java.io.ByteArrayOutputStream(pcm.size + count * bytesPerFrame)
        val step = frames / (count + 1)
        var from = 0
        for (index in 1..count) {
            val at = index * step * bytesPerFrame
            if (remove) {
                output.write(pcm, from, at - from)
                from = at + bytesPerFrame
            } else {
                output.write(pcm, from, at + bytesPerFrame - from)
                from = at
            }
        }
        output.write(pcm, from, pcm.size - from)
        return output.toByteArray()
    }

    fun release() {
        val track = track ?: return
        this.track = null
        try {
            track.pause()
            track.flush()
            track.release()
        } catch (_: Exception) {
        }
    }
}
