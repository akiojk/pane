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

        val plan = AudioClock.plan(queuedMs, playing)
        var data = pcm
        when (plan) {
            AudioClock.Plan.Keep -> Unit
            AudioClock.Plan.Skip -> {
                TabletStats.audioDropped()
                return
            }
            AudioClock.Plan.RemoveOne, AudioClock.Plan.RemoveTwo -> {
                val count = if (plan == AudioClock.Plan.RemoveTwo) 2 else 1
                data = AudioClock.adjust(pcm, bytesPerFrame, remove = true, count = count)
                TabletStats.audioAdjusted(-count)
            }
            AudioClock.Plan.RepeatOne, AudioClock.Plan.RepeatTwo -> {
                val count = if (plan == AudioClock.Plan.RepeatTwo) 2 else 1
                data = AudioClock.adjust(pcm, bytesPerFrame, remove = false, count = count)
                TabletStats.audioAdjusted(count)
            }
        }

        val written = track.write(data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING)
        if (written > 0) framesWritten += written / bytesPerFrame
        if (!playing && ms(framesWritten) >= AudioClock.targetMs) {
            track.play()
            playing = true
        }
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
