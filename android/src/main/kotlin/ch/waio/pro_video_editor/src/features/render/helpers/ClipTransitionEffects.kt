package ch.waio.pro_video_editor.src.features.render.helpers

import java.util.stream.IntStream
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pixel math for the overlap transitions that move, blur or flash the picture
 * — zoom in and out, spin, whip pan, blur, glitch, flash, iris and stretch —
 * on packed I420 frames in display orientation.
 *
 * [ClipTransitionRenderer] blends dissolve, slide, push and wipe itself and
 * hands every type [handles] reports to [compose]. Free of Android types so
 * the JVM tests can run it. `ClipTransitionType` in Dart specifies what each
 * transition shows; the Darwin pipeline draws the same with Core Image in
 * `ClipTransitionEffects.swift`, which shares the constants below.
 *
 * Geometry is worked out in frame pixels and read back per plane, so the
 * half-size chroma planes follow the luma exactly. Sources are read
 * bilinearly, with their edge pixels repeated beyond the frame. Rows are
 * drawn in parallel: a 1080×1920 frame takes several times what a dissolve
 * does, and the preview waits for every frame of the blend.
 */
internal object ClipTransitionEffects {

    /** How far zoomIn zooms into the outgoing clip, and zoomOut out of the incoming one. */
    const val ZOOM_AMOUNT = 0.5

    /** Progress by which zoomIn's incoming clip is fully opaque. */
    const val ZOOM_FADE_IN_END = 0.4

    /** Progress from which zoomOut's outgoing clip fades out. */
    const val ZOOM_FADE_OUT_START = 0.6

    /** Progress window in which spin changes clip. */
    const val SPIN_SWAP_START = 0.35
    const val SPIN_SWAP_END = 0.65

    /** whipPan's motion blur at mid-transition, as a fraction of the frame along its motion. */
    const val WHIP_BLUR_LENGTH = 0.25

    /** blur's Gaussian sigma at mid-transition, as a fraction of the frame's shorter side. */
    const val BLUR_SIGMA = 0.05

    /** Progress window in which blur changes clip. */
    const val BLUR_SWAP_START = 0.3
    const val BLUR_SWAP_END = 0.7

    /** Horizontal slices the glitch moves. */
    const val GLITCH_BANDS = 16

    /** How often per second the glitch pattern changes. */
    const val GLITCH_RATE_HZ = 15.0

    /** Chance that a slice moves, at full glitch strength. */
    const val GLITCH_BAND_CHANCE = 0.7

    /** Chance that a moved slice shows the other clip. */
    const val GLITCH_SWAP_CHANCE = 0.4

    /** A slice's largest move, as a fraction of the frame width. */
    const val GLITCH_MAX_SHIFT = 0.12

    /** How far red and blue split apart, as a fraction of the frame width. */
    const val GLITCH_SPLIT = 0.02

    /** Progress window in which flash changes clip, hidden under its peak. */
    const val FLASH_SWAP_START = 0.45
    const val FLASH_SWAP_END = 0.55

    /** Sharpness of the flash: its strength is the triangle 0 → 1 → 0 to this power. */
    const val FLASH_POWER = 4.0

    /** Width of iris's soft circle edge, in frame pixels. */
    const val IRIS_EDGE = 2.0

    /** Offsets [glitchHash] so slice 0 of pattern 0 does not hash to 0 (0x9E3779B9). */
    private const val GLITCH_SEED = -1640531527

    /** Video-range white, the value a flash brightens toward. */
    private const val LUMA_WHITE = 235.0

    /** Chroma without color. */
    private const val CHROMA_NEUTRAL = 128.0

    private val TYPES = setOf(
        "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
    )

    /** Whether [compose] draws [type]. */
    fun handles(type: String): Boolean = type in TYPES

    /**
     * Draws one frame of the transition from outgoing frame [a] into incoming
     * frame [b], both [width]×[height] packed I420.
     *
     * @param progress Eased progress, 0 = only [a], 1 = only [b]; an elastic
     *  curve overshoots it.
     * @param linearProgress Progress before easing, 0..1. The glitch pattern
     *  changes with it, so it keeps its pace whatever the curve.
     * @param durationUs Output duration of the transition.
     */
    fun compose(
        type: String, direction: String,
        a: ByteArray, b: ByteArray, width: Int, height: Int,
        progress: Double, linearProgress: Double, durationUs: Long,
    ): ByteArray {
        val out = ByteArray(a.size)
        val p = progress
        val c = progress.coerceIn(0.0, 1.0)
        when (type) {
            "zoomIn" -> layered(
                bottom = a, bottomPlacement = placementAbout(width, height, 1 + ZOOM_AMOUNT * p),
                top = b, topPlacement = placementAbout(width, height, p),
                topOpacity = smoothstep(0.0, ZOOM_FADE_IN_END, c), topCovers = false,
                width = width, height = height, out = out,
            )
            "zoomOut" -> layered(
                bottom = b, bottomPlacement = placementAbout(width, height, 1 + ZOOM_AMOUNT * (1 - p)),
                top = a, topPlacement = placementAbout(width, height, 1 - p),
                topOpacity = 1 - smoothstep(ZOOM_FADE_OUT_START, 1.0, c), topCovers = false,
                width = width, height = height, out = out,
            )
            "spin" -> {
                val outgoing = PI * p
                val incoming = PI * (p - 1)
                layered(
                    bottom = a,
                    bottomPlacement = placementAbout(
                        width, height, coverScale(width, height, outgoing), outgoing
                    ),
                    top = b,
                    topPlacement = placementAbout(
                        width, height, coverScale(width, height, incoming), incoming
                    ),
                    topOpacity = smoothstep(SPIN_SWAP_START, SPIN_SWAP_END, c), topCovers = true,
                    width = width, height = height, out = out,
                )
            }
            "whipPan" -> {
                pushed(a, b, width, height, p, direction, out)
                val horizontal = direction == "left" || direction == "right"
                val length = WHIP_BLUR_LENGTH * (if (horizontal) width else height) * sin(PI * c)
                motionBlur(out, width, height, horizontal, length)
            }
            "blur" -> {
                mix(a, b, smoothstep(BLUR_SWAP_START, BLUR_SWAP_END, c), out)
                gaussianBlur(out, width, height, BLUR_SIGMA * min(width, height) * sin(PI * c))
            }
            "glitch" -> glitch(a, b, width, height, c, linearProgress, durationUs, out)
            "flash" -> {
                mix(a, b, smoothstep(FLASH_SWAP_START, FLASH_SWAP_END, c), out)
                brighten(out, width, height, flashStrength(c))
            }
            "iris" -> iris(a, b, width, height, p, out)
            "stretch" -> stretched(a, b, width, height, p, direction, out)
            else -> throw IllegalArgumentException("Not a transition drawn here: $type")
        }
        return out
    }

    // ---------------------------------------------------------------------
    // SHARED MATH (mirrored in ClipTransitionEffects.swift)
    // ---------------------------------------------------------------------

    /** Hermite smoothstep of [x] between [edge0] and [edge1]. */
    fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /**
     * How much a [width]×[height] frame turned by [angle] about its center
     * must be scaled to still cover the whole frame.
     */
    fun coverScale(width: Int, height: Int, angle: Double): Double {
        val c = abs(cos(angle))
        val s = abs(sin(angle))
        return max((width * c + height * s) / width, (width * s + height * c) / height)
    }

    /** The flash's strength at clamped progress [c]: 0 at either end, 1 at the midpoint. */
    fun flashStrength(c: Double): Double = (1 - abs(2 * c - 1)).pow(FLASH_POWER)

    /**
     * A deterministic value in 0..1 for slice [band] in glitch pattern [phase];
     * [salt] picks one of several independent values. Integer math wraps the
     * same way on the JVM and in Swift's `&*`, so both platforms glitch alike.
     */
    fun glitchHash(band: Int, phase: Int, salt: Int): Double {
        var h = band * 374761393 + phase * 668265263 + salt * 1442695041 + GLITCH_SEED
        h = (h xor (h ushr 13)) * 1274126177
        h = h xor (h ushr 16)
        return (h.toLong() and 0xFFFFFFFFL).toDouble() / 4294967296.0
    }

    /** One slice of the glitch: how far it moves right and which clip it shows. */
    data class GlitchBand(val shift: Int, val showsIncoming: Boolean)

    /**
     * The glitch's slices at clamped progress [c] in pattern [phase] for a
     * frame [width] pixels wide.
     */
    fun glitchBands(c: Double, phase: Int, width: Int): List<GlitchBand> {
        val strength = sin(PI * c)
        val cut = c >= 0.5
        return (0 until GLITCH_BANDS).map { band ->
            val moves = glitchHash(band, phase, 0) < GLITCH_BAND_CHANCE * strength
            if (!moves) {
                GlitchBand(0, cut)
            } else {
                val shift = ((glitchHash(band, phase, 1) * 2 - 1) *
                        GLITCH_MAX_SHIFT * strength * width).roundToInt()
                val swaps = glitchHash(band, phase, 2) < GLITCH_SWAP_CHANCE
                GlitchBand(shift, if (swaps) !cut else cut)
            }
        }
    }

    /** The glitch pattern shown at [linearProgress] of a transition [durationUs] long. */
    fun glitchPhase(linearProgress: Double, durationUs: Long): Int =
        floor(linearProgress * durationUs / 1_000_000.0 * GLITCH_RATE_HZ).toInt()

    /** How far the glitch splits red and blue apart at clamped progress [c]. */
    fun glitchSplit(c: Double, width: Int): Int =
        (GLITCH_SPLIT * sin(PI * c) * width).roundToInt()

    // ---------------------------------------------------------------------
    // PLANES AND SAMPLING
    // ---------------------------------------------------------------------

    /**
     * One plane of a packed I420 frame: [scale] frame pixels per plane pixel
     * along each axis, [white] its value in a white picture.
     */
    private class Plane(
        val offset: Int, val width: Int, val height: Int, val scale: Int, val white: Double,
    )

    private fun planes(width: Int, height: Int): Array<Plane> {
        val cw = width / 2
        val ch = height / 2
        return arrayOf(
            Plane(0, width, height, 1, LUMA_WHITE),
            Plane(width * height, cw, ch, 2, CHROMA_NEUTRAL),
            Plane(width * height + cw * ch, cw, ch, 2, CHROMA_NEUTRAL),
        )
    }

    /** Bilinear read of [plane] in [src] at plane coordinates ([x], [y]), edges repeated. */
    private fun sample(src: ByteArray, plane: Plane, x: Double, y: Double): Double {
        val maxX = plane.width - 1
        val maxY = plane.height - 1
        val cx = x.coerceIn(0.0, maxX.toDouble())
        val cy = y.coerceIn(0.0, maxY.toDouble())
        val x0 = cx.toInt()
        val y0 = cy.toInt()
        val x1 = if (x0 < maxX) x0 + 1 else x0
        val y1 = if (y0 < maxY) y0 + 1 else y0
        val fx = cx - x0
        val fy = cy - y0
        val row0 = plane.offset + y0 * plane.width
        val row1 = plane.offset + y1 * plane.width
        val p00 = (src[row0 + x0].toInt() and 0xFF).toDouble()
        val p01 = (src[row0 + x1].toInt() and 0xFF).toDouble()
        val p10 = (src[row1 + x0].toInt() and 0xFF).toDouble()
        val p11 = (src[row1 + x1].toInt() and 0xFF).toDouble()
        val top = p00 + (p01 - p00) * fx
        val bottom = p10 + (p11 - p10) * fx
        return top + (bottom - top) * fy
    }

    private fun toByte(value: Double): Byte = value.roundToInt().coerceIn(0, 255).toByte()

    /**
     * Runs [body] for every index below [count] across the CPU's cores. Each
     * call writes only its own row (or column, or chunk), so they never touch
     * the same bytes. [ClipTransitionRenderer] blends its own transitions
     * with it too.
     */
    internal inline fun forEachRow(count: Int, crossinline body: (Int) -> Unit) {
        IntStream.range(0, count).parallel().forEach { body(it) }
    }

    private fun value(src: ByteArray, index: Int): Int = src[index].toInt() and 0xFF

    // ---------------------------------------------------------------------
    // LAYERS
    // ---------------------------------------------------------------------

    /**
     * Where a layer reads its picture: output frame point (x, y) shows the
     * layer's source at (a·x + b·y + tx, c·x + d·y + ty), all in frame pixels.
     */
    private class Placement(
        val a: Double, val b: Double, val c: Double, val d: Double,
        val tx: Double, val ty: Double,
    )

    /**
     * A layer scaled by [scale] and turned clockwise by [angle] radians about
     * the frame center, or null when [scale] leaves nothing to draw.
     */
    private fun placementAbout(width: Int, height: Int, scale: Double, angle: Double = 0.0): Placement? {
        if (scale <= 1e-6) return null
        val cx = width / 2.0
        val cy = height / 2.0
        // The inverse of "turn clockwise, then scale": turn back, then shrink.
        val cos = cos(angle) / scale
        val sin = sin(angle) / scale
        return Placement(
            a = cos, b = sin, c = -sin, d = cos,
            tx = cx - (cos * cx + sin * cy),
            ty = cy - (-sin * cx + cos * cy),
        )
    }

    /**
     * Draws [bottom] at [bottomPlacement] and [top] at [topPlacement] over it
     * at [topOpacity]. Unless [topCovers], the top layer covers only its own
     * picture, with a one-plane-pixel soft edge; the bottom layer always
     * fills the frame.
     */
    private fun layered(
        bottom: ByteArray, bottomPlacement: Placement?,
        top: ByteArray, topPlacement: Placement?, topOpacity: Double, topCovers: Boolean,
        width: Int, height: Int, out: ByteArray,
    ) {
        val frameWidth = width.toDouble()
        val frameHeight = height.toDouble()
        val drawsTop = topPlacement != null && topOpacity > 0
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val fy = (y + 0.5) * s
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val fx = (x + 0.5) * s
                    var v = if (bottomPlacement == null) {
                        value(bottom, row + x).toDouble()
                    } else {
                        val sx = bottomPlacement.a * fx + bottomPlacement.b * fy + bottomPlacement.tx
                        val sy = bottomPlacement.c * fx + bottomPlacement.d * fy + bottomPlacement.ty
                        sample(bottom, plane, sx / s - 0.5, sy / s - 0.5)
                    }
                    if (drawsTop) {
                        val placement = topPlacement!!
                        val sx = placement.a * fx + placement.b * fy + placement.tx
                        val sy = placement.c * fx + placement.d * fy + placement.ty
                        val cover = if (topCovers) 1.0 else {
                            val inside = min(min(sx, frameWidth - sx), min(sy, frameHeight - sy))
                            (inside / s + 0.5).coerceIn(0.0, 1.0)
                        }
                        if (cover > 0) {
                            val t = sample(top, plane, sx / s - 0.5, sy / s - 0.5)
                            v += (t - v) * topOpacity * cover
                        }
                    }
                    out[row + x] = toByte(v)
                }
            }
        }
    }

    /** Per-component blend of [a] into [b] by [weight] into [out]. */
    private fun mix(a: ByteArray, b: ByteArray, weight: Double, out: ByteArray) {
        if (weight <= 0) {
            a.copyInto(out); return
        }
        if (weight >= 1) {
            b.copyInto(out); return
        }
        val inv = 1 - weight
        val chunk = 4096
        forEachRow((a.size + chunk - 1) / chunk) { part ->
            for (i in part * chunk until min(a.size, (part + 1) * chunk)) {
                out[i] = toByte(value(a, i) * inv + value(b, i) * weight)
            }
        }
    }

    /**
     * Both frames moving together toward [direction] by [p] of the frame, the
     * incoming one following the outgoing one in — a push with sub-pixel
     * movement.
     */
    private fun pushed(
        a: ByteArray, b: ByteArray, width: Int, height: Int, p: Double, direction: String,
        out: ByteArray,
    ) {
        val frameWidth = width.toDouble()
        val frameHeight = height.toDouble()
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val fy = (y + 0.5) * s
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val fx = (x + 0.5) * s
                    var sx = fx
                    var sy = fy
                    var incoming = false
                    when (direction) {
                        "right" -> {
                            sx = fx - p * frameWidth
                            if (sx < 0) { incoming = true; sx += frameWidth }
                        }
                        "up" -> {
                            sy = fy + p * frameHeight
                            if (sy >= frameHeight) { incoming = true; sy -= frameHeight }
                        }
                        "down" -> {
                            sy = fy - p * frameHeight
                            if (sy < 0) { incoming = true; sy += frameHeight }
                        }
                        else -> {
                            sx = fx + p * frameWidth
                            if (sx >= frameWidth) { incoming = true; sx -= frameWidth }
                        }
                    }
                    val src = if (incoming) b else a
                    out[row + x] = toByte(sample(src, plane, sx / s - 0.5, sy / s - 0.5))
                }
            }
        }
    }

    /** The incoming clip inside a circle about the center, growing with [p]. */
    private fun iris(a: ByteArray, b: ByteArray, width: Int, height: Int, p: Double, out: ByteArray) {
        val cx = width / 2.0
        val cy = height / 2.0
        // The soft edge runs inside the radius, so nothing shows at 0 and
        // the corners are covered at 1.
        val radius = max(p, 0.0) * (hypot(cx, cy) + IRIS_EDGE)
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val dy = (y + 0.5) * s - cy
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val dx = (x + 0.5) * s - cx
                    val inside = ((radius - sqrt(dx * dx + dy * dy)) / IRIS_EDGE)
                        .coerceIn(0.0, 1.0)
                    val i = row + x
                    out[i] = when {
                        inside <= 0 -> a[i]
                        inside >= 1 -> b[i]
                        else -> toByte(value(a, i) + (value(b, i) - value(a, i)) * inside)
                    }
                }
            }
        }
    }

    /**
     * The incoming clip squeezed into a share [p] of the frame at the edge it
     * enters from, the outgoing clip into the rest.
     */
    private fun stretched(
        a: ByteArray, b: ByteArray, width: Int, height: Int, p: Double, direction: String,
        out: ByteArray,
    ) {
        val horizontal = direction != "up" && direction != "down"
        // The incoming clip enters at the far end (right or bottom edge) when
        // it travels left or up, at the near end otherwise.
        val entersAtFarEnd = direction != "right" && direction != "down"
        val length = (if (horizontal) width else height).toDouble()
        val boundary = if (entersAtFarEnd) length * (1 - p) else length * p
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val fy = (y + 0.5) * s
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val fx = (x + 0.5) * s
                    val along = if (horizontal) fx else fy
                    val incoming: Boolean
                    val source: Double
                    if (entersAtFarEnd) {
                        incoming = along >= boundary
                        source = if (incoming) (along - boundary) / p else along / (1 - p)
                    } else {
                        incoming = along < boundary
                        source = if (incoming) along / p else (along - boundary) / (1 - p)
                    }
                    val sx = if (horizontal) source else fx
                    val sy = if (horizontal) fy else source
                    out[row + x] = toByte(
                        sample(if (incoming) b else a, plane, sx / s - 0.5, sy / s - 0.5)
                    )
                }
            }
        }
    }

    /** Lerps every plane of [frame] toward white by [strength]. */
    private fun brighten(frame: ByteArray, width: Int, height: Int, strength: Double) {
        if (strength <= 0) return
        for (plane in planes(width, height)) {
            forEachRow(plane.height) { y ->
                val row = plane.offset + y * plane.width
                for (i in row until row + plane.width) {
                    val v = value(frame, i)
                    frame[i] = toByte(v + (plane.white - v) * strength)
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // BLUR
    // ---------------------------------------------------------------------

    /**
     * Blurs [frame] along one axis with a box [length] frame pixels long, the
     * average of the picture moved across that span.
     */
    private fun motionBlur(frame: ByteArray, width: Int, height: Int, horizontal: Boolean, length: Double) {
        for (plane in planes(width, height)) {
            val radius = ((length / plane.scale - 1) / 2).roundToInt()
            if (radius < 1) continue
            if (horizontal) boxBlurRows(frame, plane, radius) else boxBlurColumns(frame, plane, radius)
        }
    }

    /**
     * Approximates a Gaussian blur of [sigma] frame pixels with three box
     * blurs, whose variances add up to sigma².
     */
    private fun gaussianBlur(frame: ByteArray, width: Int, height: Int, sigma: Double) {
        for (plane in planes(width, height)) {
            val planeSigma = sigma / plane.scale
            // Three boxes of width w have variance 3·(w² − 1)/12.
            val boxWidth = sqrt(4 * planeSigma * planeSigma + 1)
            val radius = ((boxWidth - 1) / 2).roundToInt()
            if (radius < 1) continue
            repeat(3) {
                boxBlurRows(frame, plane, radius)
                boxBlurColumns(frame, plane, radius)
            }
        }
    }

    /** Averages each pixel of [plane] with [radius] neighbours on either side in its row, edges repeated. */
    private fun boxBlurRows(frame: ByteArray, plane: Plane, radius: Int) {
        forEachRow(plane.height) { y ->
            val row = plane.offset + y * plane.width
            val line = IntArray(plane.width) { x -> value(frame, row + x) }
            boxBlurLine(line, radius) { x, v -> frame[row + x] = v }
        }
    }

    /** Like [boxBlurRows], down each column. */
    private fun boxBlurColumns(frame: ByteArray, plane: Plane, radius: Int) {
        forEachRow(plane.width) { x ->
            val line = IntArray(plane.height) { y -> value(frame, plane.offset + y * plane.width + x) }
            boxBlurLine(line, radius) { y, v -> frame[plane.offset + y * plane.width + x] = v }
        }
    }

    /** Sliding-window box average over [line], each result handed to [write]. */
    private inline fun boxBlurLine(line: IntArray, radius: Int, write: (Int, Byte) -> Unit) {
        val last = line.size - 1
        val span = 2 * radius + 1
        var sum = 0
        for (i in -radius..radius) sum += line[i.coerceIn(0, last)]
        for (i in line.indices) {
            write(i, ((sum + span / 2) / span).coerceIn(0, 255).toByte())
            sum += line[(i + radius + 1).coerceAtMost(last)] - line[(i - radius).coerceAtLeast(0)]
        }
    }

    // ---------------------------------------------------------------------
    // GLITCH
    // ---------------------------------------------------------------------

    /**
     * The glitch: slices of the picture moved right by their shift (edges
     * repeated) and showing their own clip, then red read [glitchSplit]
     * pixels to the right and blue as far to the left.
     */
    private fun glitch(
        a: ByteArray, b: ByteArray, width: Int, height: Int,
        c: Double, linearProgress: Double, durationUs: Long, out: ByteArray,
    ) {
        val bands = glitchBands(c, glitchPhase(linearProgress, durationUs), width)
        val split = glitchSplit(c, width)
        val cw = width / 2
        val ch = height / 2
        val uOffset = width * height
        val vOffset = uOffset + cw * ch
        val last = width - 1

        forEachRow(height) { y ->
            val band = bands[(y * GLITCH_BANDS / height).coerceAtMost(GLITCH_BANDS - 1)]
            val src = if (band.showsIncoming) b else a
            val chromaRow = (y / 2).coerceAtMost(ch - 1)
            val writesChroma = y % 2 == 0 && y / 2 < ch
            val shift = band.shift
            for (x in 0 until width) {
                // The slice is moved first and the channels split after, both
                // with edges repeated — the order Core Image applies them in.
                val g = moved(x, shift, last)
                val writesChromaHere = writesChroma && x % 2 == 0 && x / 2 < cw
                if (split == 0) {
                    out[y * width + x] = src[y * width + g]
                    if (writesChromaHere) {
                        val ci = chromaRow * cw + (g / 2).coerceAtMost(cw - 1)
                        out[uOffset + (y / 2) * cw + x / 2] = src[uOffset + ci]
                        out[vOffset + (y / 2) * cw + x / 2] = src[vOffset + ci]
                    }
                    continue
                }
                val red = rgbAt(src, width, height, moved(x + split, shift, last), y, 0)
                val green = rgbAt(src, width, height, g, y, 1)
                val blue = rgbAt(src, width, height, moved(x - split, shift, last), y, 2)
                out[y * width + x] = toByte(16 + 0.1826 * red + 0.6142 * green + 0.0620 * blue)
                if (writesChromaHere) {
                    out[uOffset + (y / 2) * cw + x / 2] =
                        toByte(128 - 0.1006 * red - 0.3386 * green + 0.4392 * blue)
                    out[vOffset + (y / 2) * cw + x / 2] =
                        toByte(128 + 0.4392 * red - 0.3989 * green - 0.0403 * blue)
                }
            }
        }
    }

    /**
     * The column a glitched pixel at [at] reads: the split's column, kept in
     * the frame, then the slice's [shift] undone, kept in the frame again.
     */
    private fun moved(at: Int, shift: Int, last: Int): Int =
        (at.coerceIn(0, last) - shift).coerceIn(0, last)

    /** One BT.709 video-range RGB [channel] (0 red, 1 green, 2 blue) of pixel ([x], [y]), 0..255. */
    private fun rgbAt(src: ByteArray, width: Int, height: Int, x: Int, y: Int, channel: Int): Double {
        val cw = width / 2
        val ch = height / 2
        val luma = 1.164 * (value(src, y * width + x) - 16)
        val ci = (y / 2).coerceAtMost(ch - 1) * cw + (x / 2).coerceAtMost(cw - 1)
        val u = value(src, width * height + ci) - 128.0
        val v = value(src, width * height + cw * ch + ci) - 128.0
        val result = when (channel) {
            0 -> luma + 1.793 * v
            1 -> luma - 0.213 * u - 0.533 * v
            else -> luma + 2.112 * u
        }
        return result.coerceIn(0.0, 255.0)
    }
}
