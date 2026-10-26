package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskShape
import ch.waio.pro_video_editor.src.features.render.models.ShapeMaskState
import java.nio.ByteBuffer

/**
 * Draws a shape mask into an image of [width] x [height] pixels: opaque white
 * where the masked image shows, transparent where it does not, and partly
 * transparent across a soft edge. Only the alpha counts.
 *
 * The drawing follows the `LayerMask.paint` of pro_image_editor, which draws
 * the editor preview: a hard edge is an anti-aliased fill, a soft one the same
 * fill blurred by a Gaussian of `feather / 2.56`, a linear edge a straight
 * gradient, and an inverted mask everything but the shape.
 *
 * Keeps the last mask it drew, so a mask that holds still between keyframes is
 * drawn once. [config] is the bitmap's: ARGB_8888 to upload it as a texture,
 * ALPHA_8 to read its alpha a quarter of the size.
 */
internal class ShapeMaskPainter(
    val width: Int,
    val height: Int,
    config: Bitmap.Config = Bitmap.Config.ARGB_8888,
) {

    /** The drawn mask, in [config], premultiplied. */
    val bitmap: Bitmap = Bitmap.createBitmap(width, height, config)

    private val canvas = Canvas(bitmap)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    /** The mask [bitmap] holds, or `null` before the first one is drawn. */
    var painted: ShapeMaskState? = null
        private set

    /** Draws [state], unless it is the mask already drawn; returns whether it drew. */
    fun paint(state: ShapeMaskState): Boolean {
        if (state == painted) return false
        bitmap.eraseColor(Color.TRANSPARENT)
        draw(state)
        painted = state
        return true
    }

    /**
     * Copies the mask last drawn into [bytes], at least [Bitmap.getByteCount]
     * long, row by row [Bitmap.getRowBytes] apart.
     */
    fun copyPixels(bytes: ByteArray) {
        bitmap.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
    }

    fun recycle() {
        bitmap.recycle()
    }

    private fun draw(state: ShapeMaskState) {
        if (width <= 0 || height <= 0) return
        val featherPx = ShapeMaskGeometry.featherPx(state, width, height)
        paint.reset()
        paint.isAntiAlias = true
        paint.color = Color.WHITE

        if (state.shape == ShapeMaskShape.LINEAR) {
            drawLinear(state, featherPx)
            return
        }

        val path = outlinePath(state)
        val radius = ShapeMaskGeometry.blurRadius(ShapeMaskGeometry.blurSigma(featherPx))
        if (radius > 0) {
            paint.maskFilter = BlurMaskFilter(radius.toFloat(), BlurMaskFilter.Blur.NORMAL)
        }
        if (state.invert) {
            // Everything shows but the shape: a full fill with the shape
            // taken out of it, its edge as soft as the shape's own.
            canvas.drawColor(Color.WHITE)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
        }
        canvas.drawPath(path, paint)
    }

    /** A straight edge through the centre, the image showing above it while unturned. */
    private fun drawLinear(state: ShapeMaskState, featherPx: Double) {
        val (cx, cy) = ShapeMaskGeometry.pivot(state, width, height)
        val reach = ShapeMaskGeometry.linearReach(state, width, height).toFloat()
        canvas.save()
        canvas.translate(cx.toFloat(), cy.toFloat())
        canvas.rotate(Math.toDegrees(state.rotation).toFloat())
        if (featherPx > 0) {
            val shown = Color.WHITE
            val hidden = Color.TRANSPARENT
            val half = (featherPx / 2).toFloat()
            paint.shader = LinearGradient(
                0f, -half, 0f, half,
                if (state.invert) hidden else shown,
                if (state.invert) shown else hidden,
                Shader.TileMode.CLAMP,
            )
            canvas.drawRect(-reach, -reach, reach, reach, paint)
        } else if (state.invert) {
            canvas.drawRect(-reach, 0f, reach, reach, paint)
        } else {
            canvas.drawRect(-reach, -reach, reach, 0f, paint)
        }
        canvas.restore()
    }

    /** The shape's outline, mirrored and turned around its centre. */
    private fun outlinePath(state: ShapeMaskState): Path {
        val path = Path()
        when (val outline = ShapeMaskGeometry.outline(state, width, height)) {
            is MaskOutline.Oval -> path.addOval(outline.rect.toRectF(), Path.Direction.CW)
            is MaskOutline.RoundRect -> {
                val radius = outline.radius.toFloat()
                path.addRoundRect(outline.rect.toRectF(), radius, radius, Path.Direction.CW)
            }
            is MaskOutline.Ops -> for (op in outline.ops) {
                when (op) {
                    is MaskPathOp.MoveTo -> path.moveTo(op.x.toFloat(), op.y.toFloat())
                    is MaskPathOp.LineTo -> path.lineTo(op.x.toFloat(), op.y.toFloat())
                    is MaskPathOp.CubicTo -> path.cubicTo(
                        op.x1.toFloat(), op.y1.toFloat(),
                        op.x2.toFloat(), op.y2.toFloat(),
                        op.x.toFloat(), op.y.toFloat(),
                    )
                    is MaskPathOp.ArcTo -> path.arcTo(
                        op.oval.toRectF(), op.startDegrees.toFloat(), op.sweepDegrees.toFloat(),
                        /* forceMoveTo= */ false,
                    )
                    MaskPathOp.Close -> path.close()
                }
            }
        }
        val (cx, cy) = ShapeMaskGeometry.pivot(state, width, height)
        val place = Matrix()
        if (state.mirrored) place.postScale(-1f, 1f, cx.toFloat(), cy.toFloat())
        place.postRotate(Math.toDegrees(state.rotation).toFloat(), cx.toFloat(), cy.toFloat())
        path.transform(place)
        return path
    }

    private fun MaskRect.toRectF() =
        RectF(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
}
