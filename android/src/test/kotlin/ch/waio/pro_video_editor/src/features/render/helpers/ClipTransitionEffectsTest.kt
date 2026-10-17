package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.PI
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

internal class ClipTransitionEffectsTest {

    private val width = 48
    private val height = 64
    private val types = listOf(
        "zoomIn", "zoomOut", "spin", "whipPan", "blur", "glitch", "flash", "iris", "stretch",
    )

    /** A packed I420 frame whose luma is [luma] at each pixel and whose chroma is flat. */
    private fun frame(u: Int = 128, v: Int = 128, luma: (Int, Int) -> Int): ByteArray {
        val cw = width / 2
        val ch = height / 2
        val out = ByteArray(width * height + 2 * cw * ch)
        for (y in 0 until height) for (x in 0 until width) {
            out[y * width + x] = luma(x, y).toByte()
        }
        for (i in 0 until cw * ch) {
            out[width * height + i] = u.toByte()
            out[width * height + cw * ch + i] = v.toByte()
        }
        return out
    }

    private fun lumaAt(frame: ByteArray, x: Int, y: Int) = frame[y * width + x].toInt() and 0xFF

    private fun uAt(frame: ByteArray, x: Int, y: Int) =
        frame[width * height + (y / 2) * (width / 2) + x / 2].toInt() and 0xFF

    private fun compose(type: String, a: ByteArray, b: ByteArray, p: Double, direction: String = "left") =
        ClipTransitionEffects.compose(type, direction, a, b, width, height, p, p, 500_000L)

    // A picture with detail everywhere, so a misplaced pixel shows.
    private val outgoing = frame(u = 90, v = 170) { x, y -> 16 + (x * 7 + y * 3) % 200 }
    private val incoming = frame(u = 160, v = 80) { x, y -> 230 - (x * 5 + y * 11) % 200 }

    @Test
    fun everyTypeStartsOnTheOutgoingFrameAndEndsOnTheIncomingOne() {
        for (type in types) {
            for (direction in listOf("left", "right", "up", "down")) {
                assertTrue(
                    compose(type, outgoing, incoming, 0.0, direction).contentEquals(outgoing),
                    "$type $direction at 0",
                )
                assertTrue(
                    compose(type, outgoing, incoming, 1.0, direction).contentEquals(incoming),
                    "$type $direction at 1",
                )
            }
        }
    }

    @Test
    fun rejectsTheTransitionsTheRendererBlendsItself() {
        for (type in listOf("dissolve", "slide", "push", "wipe", "fadeToBlack")) {
            assertTrue(!ClipTransitionEffects.handles(type), type)
            assertFailsWith<IllegalArgumentException> { compose(type, outgoing, incoming, 0.5) }
        }
        types.forEach { assertTrue(ClipTransitionEffects.handles(it), it) }
    }

    @Test
    fun irisShowsTheIncomingClipInTheMiddleAndTheOutgoingOneInTheCorners() {
        val black = frame { _, _ -> 16 }
        val white = frame { _, _ -> 235 }

        val out = compose("iris", black, white, 0.5)

        assertEquals(235, lumaAt(out, width / 2, height / 2))
        assertEquals(16, lumaAt(out, 0, 0))
        assertEquals(16, lumaAt(out, width - 1, height - 1))
    }

    @Test
    fun zoomInGrowsTheIncomingClipOutOfTheCenter() {
        val black = frame { _, _ -> 16 }
        val white = frame { _, _ -> 235 }

        // Half size and fully opaque at 0.5: the middle half is the incoming
        // clip, the frame around it the outgoing one.
        val out = compose("zoomIn", black, white, 0.5)

        assertEquals(235, lumaAt(out, width / 2, height / 2))
        assertEquals(235, lumaAt(out, width / 4 + 1, height / 4 + 1))
        assertEquals(16, lumaAt(out, width / 4 - 2, height / 2))
        assertEquals(16, lumaAt(out, 0, 0))
    }

    @Test
    fun zoomOutShrinksTheOutgoingClipOverTheIncomingOne() {
        val black = frame { _, _ -> 16 }
        val white = frame { _, _ -> 235 }

        val out = compose("zoomOut", black, white, 0.5)

        assertEquals(16, lumaAt(out, width / 2, height / 2))
        assertEquals(235, lumaAt(out, 0, 0))
    }

    @Test
    fun spinKeepsTheFrameCoveredAtEveryAngle() {
        // Each clip is one flat color, so any pixel off both pictures would
        // show as something in between or an edge artifact.
        val dark = frame(u = 100, v = 100) { _, _ -> 40 }
        val light = frame(u = 100, v = 100) { _, _ -> 200 }

        for (step in 0..20) {
            val p = step / 20.0
            val out = compose("spin", dark, light, p)
            val first = lumaAt(out, 0, 0)
            for (y in 0 until height) for (x in 0 until width) {
                assertEquals(first, lumaAt(out, x, y), "p=$p at $x,$y")
            }
        }
    }

    @Test
    fun coverScaleZoomsAQuarterTurnedPortraitFrameByItsAspectRatio() {
        assertEquals(1.0, ClipTransitionEffects.coverScale(1080, 1920, 0.0), 1e-9)
        assertEquals(1920.0 / 1080, ClipTransitionEffects.coverScale(1080, 1920, PI / 2), 1e-9)
        assertEquals(1.0, ClipTransitionEffects.coverScale(1080, 1920, PI), 1e-9)
    }

    @Test
    fun whipPanBlursOnlyAlongItsMotion() {
        // Rows alternate dark and light, so a horizontal blur leaves them
        // as they are and a vertical one evens them out.
        val stripes = frame { _, y -> if (y % 2 == 0) 40 else 200 }

        val sideways = compose("whipPan", stripes, stripes, 0.5, "left")
        val upward = compose("whipPan", stripes, stripes, 0.5, "up")

        assertEquals(40, lumaAt(sideways, width / 2, height / 2))
        assertEquals(200, lumaAt(sideways, width / 2, height / 2 + 1))
        assertTrue(abs(lumaAt(upward, width / 2, height / 2) - 120) <= 10)
        assertTrue(abs(lumaAt(upward, width / 2, height / 2 + 1) - 120) <= 10)
    }

    @Test
    fun blurEvensOutDetailAtMidTransition() {
        val checks = frame { x, y -> if ((x + y) % 2 == 0) 40 else 200 }

        val out = compose("blur", checks, checks, 0.5)

        for (y in 8 until height - 8) for (x in 8 until width - 8) {
            assertTrue(abs(lumaAt(out, x, y) - 120) <= 3, "$x,$y = ${lumaAt(out, x, y)}")
        }
    }

    @Test
    fun flashIsWhiteAtItsPeak() {
        val out = compose("flash", outgoing, incoming, 0.5)

        for (y in 0 until height) for (x in 0 until width) {
            assertEquals(235, lumaAt(out, x, y))
            assertEquals(128, uAt(out, x, y))
        }
    }

    @Test
    fun flashStrengthPeaksOnlyAtTheMidpoint() {
        assertEquals(0.0, ClipTransitionEffects.flashStrength(0.0))
        assertEquals(1.0, ClipTransitionEffects.flashStrength(0.5))
        assertEquals(0.0, ClipTransitionEffects.flashStrength(1.0))
        // Under a sixth of its peak a quarter of the way in.
        assertTrue(ClipTransitionEffects.flashStrength(0.25) < 1.0 / 6)
    }

    @Test
    fun stretchSqueezesBothClipsIntoTheirShareOfTheFrame() {
        val ramp = frame { x, _ -> 20 + x * 4 }
        val flat = frame { _, _ -> 235 }

        // Moving left at 0.25: the incoming clip takes the right quarter and
        // the outgoing ramp is squeezed into the left three quarters.
        val out = compose("stretch", ramp, flat, 0.25, "left")

        assertEquals(235, lumaAt(out, width - 1, height / 2))
        assertEquals(235, lumaAt(out, width * 3 / 4, height / 2))
        // Output column 18 reads the ramp at 18.5 / 0.75 - 0.5 = 24.17.
        assertEquals(20 + 4 * 24 + 1, lumaAt(out, 18, height / 2))
    }

    @Test
    fun stretchEntersFromTheEdgeOppositeItsDirection() {
        val black = frame { _, _ -> 16 }
        val white = frame { _, _ -> 235 }

        val right = compose("stretch", black, white, 0.25, "right")
        val down = compose("stretch", black, white, 0.25, "down")
        val up = compose("stretch", black, white, 0.25, "up")

        assertEquals(235, lumaAt(right, 0, height / 2))
        assertEquals(16, lumaAt(right, width - 1, height / 2))
        assertEquals(235, lumaAt(down, width / 2, 0))
        assertEquals(16, lumaAt(down, width / 2, height - 1))
        assertEquals(235, lumaAt(up, width / 2, height - 1))
        assertEquals(16, lumaAt(up, width / 2, 0))
    }

    @Test
    fun glitchCutsToTheIncomingClipHalfwayThrough() {
        val black = frame { _, _ -> 16 }
        val white = frame { _, _ -> 235 }

        // A band that does not move shows the clip of its half.
        val phase = ClipTransitionEffects.glitchPhase(0.7, 500_000L)
        val early = ClipTransitionEffects.glitchBands(0.3, phase, width)
        val late = ClipTransitionEffects.glitchBands(0.7, phase, width)
        assertTrue(early.filter { it.shift == 0 }.none { it.showsIncoming })
        assertTrue(late.filter { it.shift == 0 }.all { it.showsIncoming })

        val out = compose("glitch", black, white, 0.7)
        val bandHeight = height / ClipTransitionEffects.GLITCH_BANDS
        late.forEachIndexed { index, band ->
            if (band.shift == 0) {
                assertTrue(lumaAt(out, width / 2, index * bandHeight) > 200, "band $index")
            }
        }
    }

    @Test
    fun glitchHashMatchesTheDarwinPin() {
        // ClipTransitionEffectsTests.swift pins the same values, so both
        // platforms draw the same glitch.
        assertEquals(0.5737507424782962, ClipTransitionEffects.glitchHash(0, 0, 0), 1e-15)
        assertEquals(0.36553404899314046, ClipTransitionEffects.glitchHash(3, 7, 1), 1e-15)
        assertEquals(0.9913903491105884, ClipTransitionEffects.glitchHash(15, 40, 2), 1e-15)
    }

    @Test
    fun glitchPatternChangesFifteenTimesASecond() {
        assertEquals(0, ClipTransitionEffects.glitchPhase(0.0, 1_000_000L))
        assertEquals(7, ClipTransitionEffects.glitchPhase(0.5, 1_000_000L))
        assertEquals(15, ClipTransitionEffects.glitchPhase(1.0, 1_000_000L))
        assertEquals(3, ClipTransitionEffects.glitchPhase(1.0, 250_000L))
    }
}
