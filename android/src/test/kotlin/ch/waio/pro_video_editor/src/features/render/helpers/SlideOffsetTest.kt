package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class SlideOffsetTest {

    private val tol = 1e-6f

    // A layer that is small relative to the canvas: half-width 0.2, half-height 0.2
    // in [-1, 1] units (e.g. 200/1000 px wide, 100/500 px tall).
    private val halfNormW = 0.2f
    private val halfNormH = 0.2f

    @Test
    fun centeredLayer_slidesFullyOutAtInvPOne() {
        val left = slideOffset("left", 1f, 0f, 0f, halfNormW, halfNormH)
        val right = slideOffset("right", 1f, 0f, 0f, halfNormW, halfNormH)
        val top = slideOffset("top", 1f, 0f, 0f, halfNormW, halfNormH)
        val bottom = slideOffset("bottom", 1f, 0f, 0f, halfNormW, halfNormH)

        // Old (buggy) behavior moved exactly one layer size (full width = 0.4),
        // leaving the layer partly visible. Edge-aware moves a full half past −1/+1.
        assertEquals(-1.2f, left.x, tol)
        assertEquals(0f, left.y, tol)
        assertEquals(1.2f, right.x, tol)
        assertEquals(0f, right.y, tol)
        assertEquals(1.2f, top.y, tol)
        assertEquals(0f, top.x, tol)
        assertEquals(-1.2f, bottom.y, tol)
        assertEquals(0f, bottom.x, tol)
    }

    @Test
    fun trailingEdgeLandsExactlyOnCanvasEdge() {
        val baseNormX = 0.5f // off-center layer
        val baseNormY = -0.3f

        // left: right edge (base + half) must end on the left canvas edge (−1).
        val left = slideOffset("left", 1f, baseNormX, baseNormY, halfNormW, halfNormH)
        assertEquals(-1f, baseNormX + halfNormW + left.x, tol)

        // right: left edge (base − half) must end on the right canvas edge (+1).
        val right = slideOffset("right", 1f, baseNormX, baseNormY, halfNormW, halfNormH)
        assertEquals(1f, baseNormX - halfNormW + right.x, tol)

        // top: bottom edge (base − half, Y up) must end on the top canvas edge (+1).
        val top = slideOffset("top", 1f, baseNormX, baseNormY, halfNormW, halfNormH)
        assertEquals(1f, baseNormY - halfNormH + top.y, tol)

        // bottom: top edge (base + half, Y up) must end on the bottom canvas edge (−1).
        val bottom = slideOffset("bottom", 1f, baseNormX, baseNormY, halfNormW, halfNormH)
        assertEquals(-1f, baseNormY + halfNormH + bottom.y, tol)
    }

    @Test
    fun atRestProgressProducesNoOffset() {
        for (dir in listOf("left", "right", "top", "bottom")) {
            val off = slideOffset(dir, 0f, 0.5f, -0.5f, halfNormW, halfNormH)
            assertEquals(0f, off.x, tol)
            assertEquals(0f, off.y, tol)
        }
    }

    @Test
    fun offsetScalesLinearlyWithInvP() {
        val full = slideOffset("left", 1f, 0f, 0f, halfNormW, halfNormH)
        val half = slideOffset("left", 0.5f, 0f, 0f, halfNormW, halfNormH)
        assertEquals(full.x / 2f, half.x, tol)
    }

    @Test
    fun unknownDirectionProducesNoOffset() {
        val off = slideOffset("diagonal", 1f, 0f, 0f, halfNormW, halfNormH)
        assertEquals(0f, off.x, tol)
        assertEquals(0f, off.y, tol)
    }

    // ── resolveAnchor: split a center into background + overlay anchors ──

    @Test
    fun inRangeCenterUsesOnlyBackgroundAnchor() {
        val a = resolveAnchor(0.5f, halfNormW)
        assertEquals(0.5f, a.backgroundAnchor, tol)
        assertEquals(0f, a.overlayAnchor, tol)
    }

    @Test
    fun fullyOutCenterIsReproducedByBothAnchors() {
        // Centered layer slid fully left: center at −1 − halfNormW.
        val center = -1f - halfNormW
        val a = resolveAnchor(center, halfNormW)
        // Background pinned to the edge, overlay supplies the off-canvas half.
        assertEquals(-1f, a.backgroundAnchor, tol)
        assertEquals(1f, a.overlayAnchor, tol)
        // overlayCenter = background − overlayAnchor * halfNorm reproduces center.
        assertEquals(center, a.backgroundAnchor - a.overlayAnchor * halfNormW, tol)
    }

    @Test
    fun anchorsAlwaysStayWithinMedia3Range() {
        // Media3 rejects anchors outside [-1, 1]; resolveAnchor must never emit
        // such a value, even for centers far beyond the canvas.
        for (center in listOf(-5f, -1.5f, -1f, 0f, 1f, 1.5f, 5f)) {
            val a = resolveAnchor(center, halfNormW)
            assertTrue(a.backgroundAnchor in -1f..1f, "bg ${a.backgroundAnchor}")
            assertTrue(a.overlayAnchor in -1f..1f, "overlay ${a.overlayAnchor}")
        }
    }

    @Test
    fun zeroHalfSizeFallsBackToBackgroundOnly() {
        val a = resolveAnchor(1.5f, 0f)
        assertEquals(1f, a.backgroundAnchor, tol)
        assertEquals(0f, a.overlayAnchor, tol)
    }

    @Test
    fun slideOutThenResolveStaysInRangeForCenteredLayer() {
        // End-to-end: the centered-layer slide-out that used to crash Media3.
        for (dir in listOf("left", "right", "top", "bottom")) {
            val off = slideOffset(dir, 1f, 0f, 0f, halfNormW, halfNormH)
            val ax = resolveAnchor(0f + off.x, halfNormW)
            val ay = resolveAnchor(0f + off.y, halfNormH)
            assertTrue(ax.backgroundAnchor in -1f..1f && ax.overlayAnchor in -1f..1f, dir)
            assertTrue(ay.backgroundAnchor in -1f..1f && ay.overlayAnchor in -1f..1f, dir)
        }
    }
}
