package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.ChromaKeyConfig
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Cross-platform parity guard for the chroma-key formula.
 *
 * The [golden] table below is duplicated verbatim in the Swift test
 * (`example/macos/RunnerTests/RunnerTests.swift`, `ChromaKeyMathTests`). Both
 * run it against their own implementation — Kotlin's [ChromaKeyMath], which the
 * GLSL shader mirrors, and Swift's `chromaKeyed(r:g:b:_:)`, which is baked into
 * the Core Image color cube. If either platform drifts, one of these two tests
 * fails immediately instead of the difference surfacing later as "the key looks
 * slightly different on iOS".
 *
 * **When you change the formula, regenerate both tables.**
 */
internal class ChromaKeyMathTest {

    /**
     * The config the golden table was computed for: SMPTE green with
     * similarity 0.15. Pinned explicitly rather than taken from the defaults,
     * so raising the library default never silently invalidates the table.
     */
    private val config = ChromaKeyConfig(
        keyR = 0x00 / 255.0,
        keyG = 0xB1 / 255.0,
        keyB = 0x40 / 255.0,
        similarity = 0.15,
        smoothness = 0.08,
        spill = 0.5,
    )

    private val tolerance = 1e-4

    private data class Golden(
        val name: String,
        val r: Double,
        val g: Double,
        val b: Double,
        val outR: Double,
        val outG: Double,
        val outB: Double,
        val alpha: Double,
    )

    private val golden = listOf(
        // The key color itself and its neighbourhood: removed completely.
        Golden("key color", 0.0, 0.694118, 0.25098, 0.218029, 0.565088, 0.343519, 0.0),
        Golden("near key", 0.05, 0.72, 0.28, 0.261122, 0.595058, 0.369608, 0.0),
        Golden("bright screen", 0.35, 0.9, 0.5, 0.525426, 0.796183, 0.574457, 0.0),
        // Half-lit screen: past the default similarity, so only mostly removed.
        // This is the documented brightness sensitivity, pinned on purpose.
        Golden("dim screen 50%", 0.0, 0.347059, 0.12549, 0.109015, 0.282544, 0.17176, 0.081671),
        // Neutrals sit at the chroma origin, far from any saturated key.
        Golden("black", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0),
        Golden("mid gray", 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0),
        Golden("white", 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0),
        // Skin tone — the calibration anchor quoted in the Dart docs.
        Golden("skin tone", 0.86, 0.65, 0.53, 0.86, 0.65, 0.53, 1.0),
        Golden("pure red", 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0),
        Golden("pure blue", 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0),
        // Kept, but despilled: the green cast is pulled out at full alpha.
        Golden(
            "green-spilled gray", 0.55, 0.75, 0.55,
            0.616767, 0.710487, 0.578338, 1.0,
        ),
        // Leans away from the key hue, so despill leaves it alone.
        Golden("magenta", 0.8, 0.2, 0.8, 0.8, 0.2, 0.8, 1.0),
    )

    @Test
    fun goldenTable_matchesTheSharedFormula() {
        for (row in golden) {
            val out = ChromaKeyMath.evaluate(row.r, row.g, row.b, config)
            val expected = doubleArrayOf(row.outR, row.outG, row.outB, row.alpha)
            val labels = listOf("r", "g", "b", "alpha")

            for (i in 0..3) {
                assertTrue(
                    abs(out[i] - expected[i]) < tolerance,
                    "${row.name}: ${labels[i]} was ${out[i]}, expected ${expected[i]}",
                )
            }
        }
    }

    @Test
    fun keyColor_isRemovedCompletely() {
        val out = ChromaKeyMath.evaluate(config.keyR, config.keyG, config.keyB, config)
        assertEquals(0.0, out[3], tolerance)
    }

    @Test
    fun softEdge_producesPartialAlphaBetweenTheThresholds() {
        // Walk the key color toward neutral gray and collect the alpha ramp.
        // Between "fully keyed" and "fully opaque" there must be intermediate
        // values, or the edge would be a hard cutout.
        val ramp = (0..60).map { step ->
            val t = step / 60.0
            ChromaKeyMath.evaluate(
                config.keyR + (0.5 - config.keyR) * t,
                config.keyG + (0.5 - config.keyG) * t,
                config.keyB + (0.5 - config.keyB) * t,
                config,
            )[3]
        }

        assertTrue(ramp.any { it == 0.0 }, "expected a fully keyed sample")
        assertTrue(ramp.any { it == 1.0 }, "expected a fully opaque sample")
        assertTrue(
            ramp.any { it > 0.01 && it < 0.99 },
            "expected a soft edge, but alpha jumped straight from 0 to 1",
        )
    }

    @Test
    fun alpha_isMonotonicInChromaDistance() {
        // Alpha must never dip as a pixel moves further from the key, or the
        // matte would show rings.
        var previous = -1.0
        for (step in 0..100) {
            val t = step / 100.0
            val alpha = ChromaKeyMath.evaluate(
                config.keyR + (0.5 - config.keyR) * t,
                config.keyG + (0.5 - config.keyG) * t,
                config.keyB + (0.5 - config.keyB) * t,
                config,
            )[3]
            assertTrue(alpha >= previous - tolerance, "alpha dipped at t=$t")
            previous = alpha
        }
    }

    @Test
    fun matte_isBrightnessSensitive_asDocumented() {
        // Cb/Cr scale with brightness, so a dimly lit patch of the screen sits
        // closer to the neutral origin and further from the key point. At the
        // 0.15 used here that is roughly 55%..100% of the reference brightness;
        // the library default of 0.20 reaches down to ~40%, which is what a
        // real studio screen needs (its darkest corners measured 0.18). Pinned
        // because the Dart docs promise exactly this behaviour.
        fun screenAt(fraction: Double) = ChromaKeyMath.evaluate(
            config.keyR * fraction,
            config.keyG * fraction,
            config.keyB * fraction,
            config,
        )[3]

        assertEquals(0.0, screenAt(1.0), tolerance)
        assertEquals(0.0, screenAt(0.7), tolerance)
        assertEquals(0.0, screenAt(0.55), tolerance)
        assertTrue(screenAt(0.5) > 0.0, "a half-lit screen should start to survive")

        // Widening similarity brings the dim end back under the key.
        val wide = config.copy(similarity = 0.35)
        assertEquals(
            0.0,
            ChromaKeyMath.evaluate(
                config.keyR * 0.4, config.keyG * 0.4, config.keyB * 0.4, wide,
            )[3],
            tolerance,
        )
    }

    @Test
    fun spill_pullsTheKeyCastOutWithoutDarkening() {
        // A green-tinted gray, the classic bounce off a screen.
        val r = 0.55
        val g = 0.75
        val b = 0.55

        val without = ChromaKeyMath.evaluate(r, g, b, config.copy(spill = 0.0))
        val with = ChromaKeyMath.evaluate(r, g, b, config.copy(spill = 1.0))

        val castBefore = without[1] - maxOf(without[0], without[2])
        val castAfter = with[1] - maxOf(with[0], with[2])
        assertTrue(
            castAfter < castBefore,
            "despill did not reduce the green cast ($castBefore -> $castAfter)",
        )

        // Luma is preserved, so despill never darkens the subject.
        assertEquals(
            ChromaKeyMath.luma(without[0], without[1], without[2]),
            ChromaKeyMath.luma(with[0], with[1], with[2]),
            1e-3,
        )
    }

    @Test
    fun spill_leavesTheComplementaryHueAlone() {
        // Magenta leans away from green, so despill must not touch it.
        val without = ChromaKeyMath.evaluate(0.8, 0.2, 0.8, config.copy(spill = 0.0))
        val with = ChromaKeyMath.evaluate(0.8, 0.2, 0.8, config.copy(spill = 1.0))

        assertEquals(without[0], with[0], tolerance)
        assertEquals(without[1], with[1], tolerance)
        assertEquals(without[2], with[2], tolerance)
    }

    @Test
    fun spillOff_leavesColorsUntouched() {
        val out = ChromaKeyMath.evaluate(0.55, 0.75, 0.55, config.copy(spill = 0.0))

        assertEquals(0.55, out[0], tolerance)
        assertEquals(0.75, out[1], tolerance)
        assertEquals(0.55, out[2], tolerance)
    }

    @Test
    fun neutralKeyColor_disablesDespillInsteadOfDividingByZero() {
        // A gray key has no hue to pull out; the direction vector collapses to
        // zero rather than producing NaN.
        val gray = ChromaKeyConfig(keyR = 0.5, keyG = 0.5, keyB = 0.5, spill = 1.0)
        assertEquals(0.0, gray.keyDirCb, tolerance)
        assertEquals(0.0, gray.keyDirCr, tolerance)

        val out = ChromaKeyMath.evaluate(0.8, 0.2, 0.4, gray)
        assertTrue(out.none { it.isNaN() }, "despill produced NaN: ${out.toList()}")
    }

    @Test
    fun zeroSmoothness_doesNotDivideByZero() {
        val hard = config.copy(smoothness = 0.0)

        assertEquals(0.0, ChromaKeyMath.evaluate(0.0, 0.694118, 0.25098, hard)[3], tolerance)
        assertEquals(1.0, ChromaKeyMath.evaluate(1.0, 1.0, 1.0, hard)[3], tolerance)
    }

    @Test
    fun higherSimilarity_keysMore() {
        // A color that survives the default key must fall to the wider one.
        val narrow = ChromaKeyMath.evaluate(0.35, 0.6, 0.4, config)[3]
        val wide = ChromaKeyMath.evaluate(0.35, 0.6, 0.4, config.copy(similarity = 0.5))[3]

        assertTrue(wide < narrow, "widening similarity did not key more ($narrow -> $wide)")
    }

    @Test
    fun skinTone_keepsAWideMarginFromTheKey() {
        // The margin quoted in the Dart docs: skin sits ~0.43 from SMPTE green,
        // nearly 3x the default similarity, which is why the default is safe.
        val skin = ChromaKeyMath.chroma(0.86, 0.65, 0.53)
        val distance = hypot(skin[0] - config.keyCb, skin[1] - config.keyCr)

        assertEquals(0.4259, distance, 1e-3)
        assertTrue(distance > config.similarity * 2.5)
    }

    @Test
    fun derivedKeyChroma_isAUnitDirection() {
        val length = hypot(config.keyDirCb, config.keyDirCr)
        assertEquals(1.0, length, tolerance)
    }
}
