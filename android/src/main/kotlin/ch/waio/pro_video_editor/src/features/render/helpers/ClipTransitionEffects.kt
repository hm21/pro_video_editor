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
 * — zoom in and out, spin, whip pan, blur, glitch, flash, iris, stretch, light
 * leak, clock and diagonal wipes, flip and cube — on packed I420 frames in
 * display orientation.
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

    /** Progress window in which lightLeak changes clip, hidden under its light. */
    const val LEAK_SWAP_START = 0.35
    const val LEAK_SWAP_END = 0.65

    /** How bright lightLeak's lights are at mid-transition, as a multiple of their colors. */
    const val LEAK_GAIN = 2.2

    /** Width of the soft edge of clockWipe and diagonalWipe, in frame pixels. */
    const val WIPE_EDGE = 2.0

    /** How far the camera is from flip and cube, as a multiple of the side that turns. */
    const val TURN_DISTANCE = 2.0

    /** How much flip and cube darken a face turned edge-on. */
    const val TURN_SHADE = 0.4

    /**
     * One of lightLeak's warm lights: its color (0..1), where its centre
     * starts and ends as fractions of the frame from the top left, and its
     * reach as fractions of the frame's longer side. The colors are the light
     * leak video effect's.
     */
    data class LeakLight(
        val red: Double, val green: Double, val blue: Double,
        val startX: Double, val startY: Double, val endX: Double, val endY: Double,
        val reachX: Double, val reachY: Double,
    )

    /** lightLeak's lights, drifting from the left edge across the frame. */
    val LEAK_LIGHTS = listOf(
        LeakLight(0.95, 0.49, 0.17, -0.2, 0.3, 0.85, 0.5, 0.55, 0.8),
        LeakLight(0.75, 0.21, 0.24, -0.1, -0.05, 1.1, 0.1, 0.6, 0.3),
        LeakLight(0.55, 0.45, 0.28, -0.3, 0.85, 0.7, 0.7, 0.4, 0.4),
    )

    /** Offsets [glitchHash] so slice 0 of pattern 0 does not hash to 0 (0x9E3779B9). */
    private const val GLITCH_SEED = -1640531527

    /** Video-range white, the value a flash brightens toward. */
    private const val LUMA_WHITE = 235.0

    /** Chroma without color. */
    private const val CHROMA_NEUTRAL = 128.0

    private val TYPES = setOf(
        "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
        "lightLeak", "clockWipe", "diagonalWipe", "flip", "cube",
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
            "lightLeak" -> {
                mix(a, b, smoothstep(LEAK_SWAP_START, LEAK_SWAP_END, c), out)
                lightLeak(out, width, height, c)
            }
            "clockWipe" -> clockWipe(a, b, width, height, c, out)
            "diagonalWipe" -> diagonalWipe(a, b, width, height, c, direction, out)
            "flip", "cube" -> turned(
                a, b, width, height, turnedFaces(type, direction, width, height, p), out,
            )
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

    /** How strong lightLeak's lights are at clamped progress [c]: 0 at either end, 1 at the midpoint. */
    fun leakStrength(c: Double): Double {
        val s = sin(PI * c)
        return s * s
    }

    /**
     * The corner diagonalWipe's edge travels toward, a quarter of the way
     * clockwise from [direction]: left → top left, up → top right, right →
     * bottom right, down → bottom left. Each coordinate is 0 for the left or
     * top edge and 1 for the right or bottom one.
     */
    fun diagonalCorner(direction: String): Pair<Int, Int> = when (direction) {
        "right" -> 1 to 1
        "up" -> 1 to 0
        "down" -> 0 to 1
        else -> 0 to 0
    }

    /**
     * One face of flip or cube on screen: whether it shows the outgoing clip,
     * its corners in frame pixels (x, y pairs: top left, top right, bottom
     * right and bottom left of its picture) and how much of its picture's
     * brightness it keeps.
     */
    data class TurnedFace(val outgoing: Boolean, val corners: List<Pair<Double, Double>>, val shade: Double)

    /**
     * The faces flip or cube shows at progress [p] in a [width]×[height]
     * frame, farthest first; a face turned away or edge-on is left out.
     *
     * Flip turns a card about the frame's middle: the outgoing clip on its
     * front until it stands edge-on halfway through, the incoming clip on its
     * back after. Cube turns the outgoing clip away as one side of a cube and
     * brings the incoming clip in as the next side. Both turn about a vertical
     * axis for left and right and a horizontal one for up and down, the edge
     * ahead of the motion coming toward the viewer. They move back just far
     * enough that no edge comes closer than the frame, are seen from
     * [TURN_DISTANCE] times the turning side away, and darken by up to
     * [TURN_SHADE] as they turn.
     */
    fun turnedFaces(type: String, direction: String, width: Int, height: Int, p: Double): List<TurnedFace> {
        val horizontal = direction != "up" && direction != "down"
        // Left and up turn the far end (right or bottom edge) toward the viewer.
        val sign = if (direction == "right" || direction == "down") -1.0 else 1.0
        val side = (if (horizontal) width else height).toDouble()
        val across = (if (horizontal) height else width).toDouble()
        val cube = type == "cube"
        // The faces turn about an axis this far behind the frame.
        val pivot = if (cube) side / 2 else 0.0
        val angles = if (cube) {
            listOf(true to PI / 2 * p, false to PI / 2 * (p - 1))
        } else if (p < 0.5) {
            listOf(true to PI * p)
        } else {
            listOf(false to PI * (p - 1))
        }
        // Each corner along the turning side and across it, as offsets from
        // the middle: top left, top right, bottom right, bottom left.
        val offsets = if (horizontal) {
            listOf(-side / 2 to -across / 2, side / 2 to -across / 2, side / 2 to across / 2, -side / 2 to across / 2)
        } else {
            listOf(-side / 2 to -across / 2, -side / 2 to across / 2, side / 2 to across / 2, side / 2 to -across / 2)
        }
        // Per face, each corner's (along, across, depth).
        val turned = angles.map { (_, angle) ->
            val cos = cos(angle)
            val sin = sin(angle)
            offsets.map { (along, cross) ->
                Triple(along * cos - sign * pivot * sin, cross, sign * along * sin + pivot * cos - pivot)
            }
        }
        val nearest = max(turned.flatten().maxOf { it.third }, 0.0)
        val distance = TURN_DISTANCE * side
        val faces = mutableListOf<Pair<TurnedFace, Double>>()
        for ((face, corners) in angles.zip(turned)) {
            val points = corners.map { (along, cross, depth) ->
                val scale = distance / (distance - (depth - nearest))
                val a = side / 2 + along * scale
                val b = across / 2 + cross * scale
                if (horizontal) a to b else b to a
            }
            if (shoelaceArea(points) <= 1) continue
            faces.add(
                TurnedFace(face.first, points, 1 - TURN_SHADE * abs(sin(face.second))) to
                        corners.sumOf { it.third } / corners.size
            )
        }
        // Equally far, the outgoing face goes first, as on Darwin.
        return faces.sortedWith(compareBy({ it.second }, { !it.first.outgoing })).map { it.first }
    }

    /** The area of the quad [points], positive when they run clockwise on screen as a face seen from the front does. */
    private fun shoelaceArea(points: List<Pair<Double, Double>>): Double {
        var sum = 0.0
        for (i in points.indices) {
            val (x0, y0) = points[i]
            val (x1, y1) = points[(i + 1) % points.size]
            sum += x0 * y1 - x1 * y0
        }
        return sum / 2
    }

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

    /**
     * The incoming clip revealed behind a hand sweeping clockwise from twelve
     * o'clock, a full turn at clamped progress [c].
     *
     * The swept part is the right half and the half-plane behind the hand,
     * each with a soft edge [WIPE_EDGE] wide centred on its line: both at once
     * up to half a turn, either beyond it. Beyond half a turn their sum, kept
     * to 1, leaves no seam where their edges run side by side below the
     * centre — the mask Core Image builds from gradients.
     */
    private fun clockWipe(a: ByteArray, b: ByteArray, width: Int, height: Int, c: Double, out: ByteArray) {
        if (c <= 0) { a.copyInto(out); return }
        if (c >= 1) { b.copyInto(out); return }
        val angle = 2 * PI * c
        val handX = -cos(angle)
        val handY = -sin(angle)
        val pastHalf = angle > PI
        val cx = width / 2.0
        val cy = height / 2.0
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val dy = (y + 0.5) * s - cy
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val dx = (x + 0.5) * s - cx
                    val right = edgeRamp(dx)
                    val hand = edgeRamp(dx * handX + dy * handY)
                    val shown = if (pastHalf) min(1.0, right + hand) else min(right, hand)
                    out[row + x] = blended(a, b, row + x, shown)
                }
            }
        }
    }

    /** How much of a soft [WIPE_EDGE] wide edge covers a point [distance] pixels ahead of its line. */
    private fun edgeRamp(distance: Double): Double = (distance / WIPE_EDGE + 0.5).coerceIn(0.0, 1.0)

    /**
     * The incoming clip revealed by an edge, parallel to the frame's other
     * diagonal, travelling from the corner opposite [diagonalCorner] to it.
     *
     * Like iris, the soft edge runs behind the edge, so nothing shows at 0
     * and the far corner is covered at 1.
     */
    private fun diagonalWipe(
        a: ByteArray, b: ByteArray, width: Int, height: Int, c: Double, direction: String,
        out: ByteArray,
    ) {
        if (c <= 0) { a.copyInto(out); return }
        if (c >= 1) { b.copyInto(out); return }
        val (targetX, targetY) = diagonalCorner(direction)
        val startX = (1 - targetX) * width.toDouble()
        val startY = (1 - targetY) * height.toDouble()
        // Toward the target, across the lines x / width + y / height = constant.
        val towardX = (2 * targetX - 1) / width.toDouble()
        val towardY = (2 * targetY - 1) / height.toDouble()
        val length = hypot(towardX, towardY)
        val normalX = towardX / length
        val normalY = towardY / length
        val edge = c * (2 / length + WIPE_EDGE)
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            forEachRow(plane.height) { y ->
                val alongY = ((y + 0.5) * s - startY) * normalY
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val along = ((x + 0.5) * s - startX) * normalX + alongY
                    out[row + x] = blended(a, b, row + x, ((edge - along) / WIPE_EDGE).coerceIn(0.0, 1.0))
                }
            }
        }
    }

    /** Index [i] of [a] blended toward [b] by [weight]. */
    private fun blended(a: ByteArray, b: ByteArray, i: Int, weight: Double): Byte = when {
        weight <= 0 -> a[i]
        weight >= 1 -> b[i]
        else -> toByte(value(a, i) + (value(b, i) - value(a, i)) * weight)
    }

    /**
     * Brightens [frame] in place by lightLeak's lights at clamped progress
     * [c]: each light, its color times its strength and its smoothstep
     * falloff clamped to 1, screened over the picture in turn, in BT.709
     * video-range RGB.
     *
     * A 2×2 block's chroma is the average of its four lit pixels'.
     */
    private fun lightLeak(frame: ByteArray, width: Int, height: Int, c: Double) {
        val strength = LEAK_GAIN * leakStrength(c)
        // sin(π) is not quite 0; a light this faint changes nothing, while the
        // trip through RGB would round the picture.
        if (strength < 1e-6) return
        val longer = max(width, height).toDouble()
        val lights = LEAK_LIGHTS.map { light ->
            doubleArrayOf(
                (light.startX + (light.endX - light.startX) * c) * width,
                (light.startY + (light.endY - light.startY) * c) * height,
                light.reachX * longer, light.reachY * longer,
                light.red * strength, light.green * strength, light.blue * strength,
            )
        }
        val cw = width / 2
        val ch = height / 2
        val uOffset = width * height
        val vOffset = uOffset + cw * ch
        forEachRow((height + 1) / 2) { pair ->
            val pixel = DoubleArray(3)
            val sums = DoubleArray(2 * (cw + 1))
            val counts = IntArray(cw + 1)
            val chromaRow = min(pair, ch - 1)
            for (y in 2 * pair until min(2 * pair + 2, height)) {
                for (x in 0 until width) {
                    val ci = chromaRow * cw + min(x / 2, cw - 1)
                    val luma = 1.164 * (value(frame, y * width + x) - 16)
                    val u = value(frame, uOffset + ci) - 128.0
                    val v = value(frame, vOffset + ci) - 128.0
                    pixel[0] = ((luma + 1.793 * v) / 255).coerceIn(0.0, 1.0)
                    pixel[1] = ((luma - 0.213 * u - 0.533 * v) / 255).coerceIn(0.0, 1.0)
                    pixel[2] = ((luma + 2.112 * u) / 255).coerceIn(0.0, 1.0)
                    for (light in lights) {
                        val dx = (x + 0.5 - light[0]) / light[2]
                        val dy = (y + 0.5 - light[1]) / light[3]
                        val falloff = smoothstep(0.0, 1.0, 1 - sqrt(dx * dx + dy * dy))
                        if (falloff <= 0) continue
                        for (k in 0..2) {
                            val glow = min(light[4 + k] * falloff, 1.0)
                            pixel[k] = 1 - (1 - pixel[k]) * (1 - glow)
                        }
                    }
                    val red = pixel[0] * 255
                    val green = pixel[1] * 255
                    val blue = pixel[2] * 255
                    frame[y * width + x] = toByte(16 + 0.1826 * red + 0.6142 * green + 0.0620 * blue)
                    val block = x / 2
                    if (block < cw && pair < ch) {
                        sums[2 * block] += 128 - 0.1006 * red - 0.3386 * green + 0.4392 * blue
                        sums[2 * block + 1] += 128 + 0.4392 * red - 0.3989 * green - 0.0403 * blue
                        counts[block]++
                    }
                }
            }
            if (pair < ch) {
                for (block in 0 until cw) {
                    if (counts[block] == 0) continue
                    frame[uOffset + pair * cw + block] = toByte(sums[2 * block] / counts[block])
                    frame[vOffset + pair * cw + block] = toByte(sums[2 * block + 1] / counts[block])
                }
            }
        }
    }

    /**
     * [faces] drawn over black, each picture darkened by its shade and moved
     * onto its corners, its edges softened as bilinear reads into transparency
     * soften them in Core Image.
     */
    private fun turned(
        a: ByteArray, b: ByteArray, width: Int, height: Int, faces: List<TurnedFace>, out: ByteArray,
    ) {
        // Each face maps an output point back into its picture's unit square.
        val inverses = faces.map { invert(squareToQuad(it.corners)) }
        val frameWidth = width.toDouble()
        val frameHeight = height.toDouble()
        for (plane in planes(width, height)) {
            val s = plane.scale.toDouble()
            // Black: the value every face is darkened and composited toward.
            val base = if (plane.scale == 1) 16.0 else CHROMA_NEUTRAL
            forEachRow(plane.height) { y ->
                val fy = (y + 0.5) * s
                val row = plane.offset + y * plane.width
                for (x in 0 until plane.width) {
                    val fx = (x + 0.5) * s
                    var color = 0.0
                    for ((index, face) in faces.withIndex()) {
                        val m = inverses[index]
                        val w = m[6] * fx + m[7] * fy + m[8]
                        val u = (m[0] * fx + m[1] * fy + m[2]) / w
                        val v = (m[3] * fx + m[4] * fy + m[5]) / w
                        val (premultiplied, alpha) = sampleOver(
                            if (face.outgoing) a else b, plane, base,
                            u * frameWidth / s - 0.5, v * frameHeight / s - 0.5,
                        )
                        if (alpha <= 0) continue
                        color = face.shade * premultiplied + (1 - alpha) * color
                    }
                    out[row + x] = toByte(base + color)
                }
            }
        }
    }

    /**
     * Bilinear read of [plane] in [src] at plane coordinates ([x], [y]) where
     * the picture ends rather than repeats: its value less [base], times how
     * much of it the read covers, and that coverage.
     */
    private fun sampleOver(src: ByteArray, plane: Plane, base: Double, x: Double, y: Double): Pair<Double, Double> {
        val x0 = floor(x).toInt()
        val y0 = floor(y).toInt()
        if (x0 < -1 || y0 < -1 || x0 >= plane.width || y0 >= plane.height) return 0.0 to 0.0
        val fx = x - x0
        val fy = y - y0
        var color = 0.0
        var alpha = 0.0
        for (dy in 0..1) {
            val sy = y0 + dy
            if (sy < 0 || sy >= plane.height) continue
            val wy = if (dy == 0) 1 - fy else fy
            for (dx in 0..1) {
                val sx = x0 + dx
                if (sx < 0 || sx >= plane.width) continue
                val weight = wy * (if (dx == 0) 1 - fx else fx)
                color += weight * (value(src, plane.offset + sy * plane.width + sx) - base)
                alpha += weight
            }
        }
        return color to alpha
    }

    /**
     * The projective map from the unit square — (0, 0) top left, (1, 1)
     * bottom right — onto the quad [corners], row-major 3×3 (Heckbert).
     */
    private fun squareToQuad(corners: List<Pair<Double, Double>>): DoubleArray {
        val (x0, y0) = corners[0]
        val (x1, y1) = corners[1]
        val (x2, y2) = corners[2]
        val (x3, y3) = corners[3]
        val dx1 = x1 - x2
        val dx2 = x3 - x2
        val dy1 = y1 - y2
        val dy2 = y3 - y2
        val sx = x0 - x1 + x2 - x3
        val sy = y0 - y1 + y2 - y3
        val den = dx1 * dy2 - dx2 * dy1
        val g = (sx * dy2 - dx2 * sy) / den
        val h = (dx1 * sy - sx * dy1) / den
        return doubleArrayOf(
            x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
            y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
            g, h, 1.0,
        )
    }

    /** The inverse of the row-major 3×3 matrix [m]. */
    private fun invert(m: DoubleArray): DoubleArray {
        val (a, b, c) = Triple(m[0], m[1], m[2])
        val (d, e, f) = Triple(m[3], m[4], m[5])
        val (g, h, i) = Triple(m[6], m[7], m[8])
        val det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return doubleArrayOf(
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        )
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
