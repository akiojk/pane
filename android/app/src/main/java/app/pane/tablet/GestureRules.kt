package app.pane.tablet

/**
 * The decisions a finger gesture turns into, separate from the Android touch events that feed them.
 * Distances are in pixels. A movement inside the slop is still a tap.
 */
internal object GestureRules {
    const val holdMillis = 400L
    const val twoFingerTapMillis = 300L

    enum class TwoFinger { Undecided, Scroll, Pinch }

    fun becameScroll(distance: Float, slop: Float): Boolean = distance >= slop

    /**
     * Pinch when the fingers open or close at least as much as they travel together, and they did
     * not start on top of each other. Otherwise the pair is a scroll. Neither, while both movements
     * are still inside the slop.
     */
    fun twoFinger(spreadChange: Float, travel: Float, startSpan: Float, slop: Float): TwoFinger {
        if (spreadChange < slop && travel < slop) return TwoFinger.Undecided
        return if (spreadChange >= travel && startSpan > 1f) TwoFinger.Pinch else TwoFinger.Scroll
    }

    fun twoFingerTap(elapsedMillis: Long): Boolean = elapsedMillis < twoFingerTapMillis
}
