package app.pane.tablet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GestureRulesTest {
    private val slop = 8f

    @Test
    fun aSmallMoveStaysATapAndALargerMoveScrolls() {
        assertFalse(GestureRules.becameScroll(7.9f, slop))
        assertTrue(GestureRules.becameScroll(8f, slop))
    }

    @Test
    fun fingersThatOpenBecomeAPinchAndFingersThatTravelScroll() {
        assertEquals(
            GestureRules.TwoFinger.Undecided,
            GestureRules.twoFinger(spreadChange = 3f, travel = 3f, startSpan = 80f, slop = slop)
        )
        assertEquals(
            GestureRules.TwoFinger.Pinch,
            GestureRules.twoFinger(spreadChange = 20f, travel = 5f, startSpan = 80f, slop = slop)
        )
        assertEquals(
            GestureRules.TwoFinger.Scroll,
            GestureRules.twoFinger(spreadChange = 5f, travel = 20f, startSpan = 80f, slop = slop)
        )
    }

    @Test
    fun fingersThatStartTogetherDoNotPinch() {
        assertEquals(
            GestureRules.TwoFinger.Scroll,
            GestureRules.twoFinger(spreadChange = 20f, travel = 5f, startSpan = 1f, slop = slop)
        )
    }

    @Test
    fun aQuickTwoFingerLiftIsARightClick() {
        assertTrue(GestureRules.twoFingerTap(299))
        assertFalse(GestureRules.twoFingerTap(GestureRules.twoFingerTapMillis))
        assertEquals(400L, GestureRules.holdMillis)
    }
}
