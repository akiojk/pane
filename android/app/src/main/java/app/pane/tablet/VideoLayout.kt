package app.pane.tablet

internal object VideoLayout {
    data class Rect(val width: Float, val height: Float, val x: Float, val y: Float)

    fun content(viewW: Float, viewH: Float, videoW: Int, videoH: Int): Rect {
        val safeW = viewW.coerceAtLeast(1f)
        val safeH = viewH.coerceAtLeast(1f)
        if (videoW <= 0 || videoH <= 0) return Rect(safeW, safeH, 0f, 0f)
        val viewAspect = safeW / safeH
        val videoAspect = videoW.toFloat() / videoH.toFloat()
        return if (viewAspect > videoAspect) {
            val height = safeH
            val width = height * videoAspect
            Rect(width, height, (safeW - width) / 2f, 0f)
        } else {
            val width = safeW
            val height = width / videoAspect
            Rect(width, height, 0f, (safeH - height) / 2f)
        }
    }
}
