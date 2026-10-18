package app.pane.tablet

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View

/**
 * Draws the Mac pointer on top of the video so it does not wait for the next frame.
 * The shape comes from the Mac. The arrow is only used until the first shape arrives.
 */
internal class CursorOverlay @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    var videoWidth = 0
    var videoHeight = 0

    private var nx = 0f
    private var ny = 0f
    private var shown = false
    private var image: CursorImage? = null
    private val imagePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val imageRect = RectF()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt(); style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF1A1A1A.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 2f * resources.displayMetrics.density
        strokeJoin = Paint.Join.ROUND
    }
    private val arrow = Path()

    fun showAt(x: Float, y: Float) {
        nx = x
        ny = y
        shown = true
        invalidate()
    }

    fun hide() {
        if (!shown) return
        shown = false
        invalidate()
    }

    fun setImage(next: CursorImage) {
        image = next
        if (shown) invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (!shown) return
        val rect = VideoLayout.content(width.toFloat(), height.toFloat(), videoWidth, videoHeight)
        val tipX = rect.x + nx * rect.width
        val tipY = rect.y + ny * rect.height
        val current = image
        if (current != null) {
            val left = tipX - current.hotX * rect.width
            val top = tipY - current.hotY * rect.height
            imageRect.set(left, top, left + current.width * rect.width, top + current.height * rect.height)
            canvas.drawBitmap(current.bitmap, null, imageRect, imagePaint)
            return
        }
        val s = 1.15f * resources.displayMetrics.density
        arrow.reset()
        arrow.moveTo(tipX, tipY)
        arrow.lineTo(tipX, tipY + 18f * s)
        arrow.lineTo(tipX + 4.5f * s, tipY + 13.5f * s)
        arrow.lineTo(tipX + 8.5f * s, tipY + 20f * s)
        arrow.lineTo(tipX + 11f * s, tipY + 18.5f * s)
        arrow.lineTo(tipX + 7f * s, tipY + 12f * s)
        arrow.lineTo(tipX + 13f * s, tipY + 12f * s)
        arrow.close()
        canvas.drawPath(arrow, fill)
        canvas.drawPath(arrow, stroke)
    }
}
