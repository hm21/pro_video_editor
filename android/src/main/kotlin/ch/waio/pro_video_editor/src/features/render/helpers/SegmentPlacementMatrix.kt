package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.cos
import kotlin.math.sin

/**
 * Pure geometry for placing a composition clip on the render canvas.
 *
 * Builds the column-major 4x4 matrix that maps the unit draw quad (`[-1, 1]`
 * in x and y, as handed to the vertex shader) onto its destination rectangle
 * in normalized device coordinates, optionally turned clockwise around that
 * rectangle's own centre.
 *
 * NDC is **not** square: one unit spans `renderWidth / 2` px across and
 * `renderHeight / 2` px down. Turning in NDC would therefore shear the clip on
 * any non-square canvas, so the turn happens in pixel space —
 * `M = T · (NDC←px) · R · (px←NDC) · S` — written out in closed form below.
 * At zero rotation the matrix collapses to the plain translate-and-scale it has
 * always been.
 *
 * Kept free of any Android/Media3 types (in particular `android.opengl.Matrix`,
 * which `unitTests.returnDefaultValues` stubs into a no-op) so the geometry can
 * be unit-tested on the JVM.
 */
internal object SegmentPlacementMatrix {

    /**
     * Builds the placement matrix for a draw rectangle on the canvas.
     *
     * @param x Destination left edge in canvas pixels, top-left origin.
     * @param y Destination top edge in canvas pixels, top-left origin.
     * @param targetWidth Destination width in canvas pixels.
     * @param targetHeight Destination height in canvas pixels.
     * @param renderWidth Canvas width in pixels.
     * @param renderHeight Canvas height in pixels.
     * @param rotation Clockwise on-screen turn around the rectangle's centre,
     *  in radians. Ignored when the canvas has no extent.
     * @return A 16-element column-major matrix, as OpenGL expects it.
     */
    fun build(
        x: Float,
        y: Float,
        targetWidth: Float,
        targetHeight: Float,
        renderWidth: Int,
        renderHeight: Int,
        rotation: Double
    ): FloatArray {
        // sx and sy are half-widths in NDC (relative to a 2.0 wide space).
        val sx = if (renderWidth > 0) targetWidth / renderWidth else 1f
        val sy = if (renderHeight > 0) targetHeight / renderHeight else 1f

        // Convert pixel (x, y) to NDC top-left.
        val leftNDC = if (renderWidth > 0) (2f * x / renderWidth) - 1f else -1f
        val topNDC = if (renderHeight > 0) 1f - (2f * y / renderHeight) else 1f

        // Target center in NDC for a quad that is 2x2 centered at 0,0.
        val matrix = FloatArray(16)
        matrix[10] = 1f
        matrix[15] = 1f
        matrix[12] = leftNDC + sx
        matrix[13] = topNDC - sy

        val halfW = renderWidth / 2f
        val halfH = renderHeight / 2f
        if (rotation == 0.0 || halfW <= 0f || halfH <= 0f) {
            matrix[0] = sx
            matrix[5] = sy
            return matrix
        }

        // Screen y points down and NDC y points up, so a clockwise on-screen
        // angle turns the other way here. Expanding
        // `S(1/halfW, 1/halfH) · R(-rotation) · S(halfW, halfH) · S(sx, sy)`
        // leaves the aspect ratio only in the off-diagonal terms, which is what
        // keeps the box a box instead of shearing it.
        val c = cos(rotation).toFloat()
        val s = sin(rotation).toFloat()
        matrix[0] = c * sx
        matrix[1] = -s * (halfW / halfH) * sx
        matrix[4] = s * (halfH / halfW) * sy
        matrix[5] = c * sy
        return matrix
    }
}
