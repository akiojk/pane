package app.pane.tablet

/**
 * Keeps the tablet's playback buffer near [targetMs]. The Mac and the tablet clocks drift, so a
 * packet that would make the buffer too full loses a sample frame, and one that would leave it too
 * empty repeats one. Far enough from the target, two frames change. A burst well above the target
 * drops the whole packet.
 */
internal object AudioClock {
    const val targetMs = 40.0
    const val bandMs = 6.0
    const val farMs = 15.0
    const val skipAboveMs = 60.0

    enum class Plan { Keep, Skip, RemoveOne, RemoveTwo, RepeatOne, RepeatTwo }

    fun plan(queuedMs: Double, playing: Boolean): Plan {
        if (!playing) return Plan.Keep
        return when {
            queuedMs > skipAboveMs -> Plan.Skip
            queuedMs > targetMs + farMs -> Plan.RemoveTwo
            queuedMs > targetMs + bandMs -> Plan.RemoveOne
            queuedMs < targetMs - farMs -> Plan.RepeatTwo
            queuedMs < targetMs - bandMs -> Plan.RepeatOne
            else -> Plan.Keep
        }
    }

    /** Removes or repeats single frames spread evenly through the packet, so no two changes sit together. */
    fun adjust(pcm: ByteArray, bytesPerFrame: Int, remove: Boolean, count: Int): ByteArray {
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
}
