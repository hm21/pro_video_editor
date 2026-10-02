package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.VideoEffectBand
import ch.waio.pro_video_editor.src.features.render.models.VideoEffectFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Cross-platform parity guard for the video effect pipeline.
 *
 * The [goldens] are duplicated verbatim in the Swift test
 * (`example/macos/RunnerTests/RunnerTests.swift`, `VideoEffectTests`), which
 * checks the Core Image stage against them. They were computed by an
 * implementation independent of both, so a platform that drifts from the spec
 * in [VideoEffectMath] fails here or there instead of looking slightly
 * different on iOS.
 *
 * **When you change the spec, regenerate the checksums in both files.**
 */
internal class VideoEffectMathTest {

    private val width = 24
    private val height = 16

    /** A deterministic test image with a different gradient per channel. */
    private val source = IntArray(width * height) { i ->
        val x = i % width
        val y = i / width
        val r = (x * 37 + y * 11) % 256
        val g = (x * 13 + y * 29 + 64) % 256
        val b = (x * 7 + y * 53 + 128) % 256
        (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private data class Golden(
        val name: String,
        val frame: VideoEffectFrame,
        val checksum: Long,
        /** The output at (5, 6), as `0xRRGGBB`. */
        val sample: Int,
    )

    private val goldens = listOf(
        Golden("identity", VideoEffectFrame.NONE, 0x8c5f1e40, 0xfb2fe1),
        Golden("pixelate", VideoEffectFrame(pixelSize = 0.25), 0xe43cd600, 0xd26c72),
        Golden(
            "bands and split",
            VideoEffectFrame(
                rgbShift = 0.1,
                bands = listOf(
                    VideoEffectBand(0.25, 0.5, 0.2),
                    VideoEffectBand(0.4, 0.9, -0.125),
                ),
            ),
            0x5f7e3216,
            0x8ceebe,
        ),
        Golden(
            "scanlines and noise",
            VideoEffectFrame(
                scanlines = 0.4,
                scanlinePeriod = 0.25,
                noise = 0.3,
                noiseCellSize = 0.125,
                noiseOffsetX = 5,
                noiseOffsetY = 120,
            ),
            0x12b26fc6,
            0xac329c,
        ),
        Golden(
            "everything",
            VideoEffectFrame(
                pixelSize = 0.125,
                rgbShift = -0.05,
                scanlines = 0.25,
                scanlinePeriod = 0.1875,
                noise = 0.2,
                noiseCellSize = 0.0625,
                noiseOffsetX = 127,
                noiseOffsetY = 3,
                bands = listOf(
                    VideoEffectBand(0.0, 0.3, 0.5),
                    VideoEffectBand(0.6, 1.0, -0.3),
                ),
            ),
            0xea95b6e7,
            0xee4c31,
        ),
        Golden(
            "tones",
            VideoEffectFrame(sepia = 0.6, brightness = -0.1, invert = 0.25, flash = 0.2),
            0xff2a26c6,
            0xb08fa1,
        ),
        Golden(
            "vignette",
            VideoEffectFrame(vignette = 0.8, vignetteRadius = 0.25),
            0x9028d182,
            0xf22dd9,
        ),
        Golden(
            "old film",
            VideoEffectFrame(
                noise = 0.3,
                noiseCellSize = 0.125,
                noiseOffsetX = 9,
                noiseOffsetY = 77,
                sepia = 0.85,
                brightness = -0.04,
                vignette = 0.6,
                vignetteRadius = 0.3,
            ),
            0xcd38dc88,
            0x936a6c,
        ),
        Golden(
            "sepia overflow",
            VideoEffectFrame(sepia = 1.0, brightness = -0.3),
            0x10e68ca5,
            0x7c6e56,
        ),
        Golden(
            "noisy vignette",
            VideoEffectFrame(
                noise = 0.5,
                noiseCellSize = 0.0625,
                noiseOffsetX = 33,
                noiseOffsetY = 90,
                vignette = 0.9,
                vignetteRadius = 0.1,
            ),
            0xa50243e8,
            0xdc25c4,
        ),
        Golden(
            "strong vignette",
            VideoEffectFrame(vignette = 1.5, vignetteRadius = 0.1),
            0x5ade77f4,
            0xd027ba,
        ),
        Golden(
            "zoom and offset",
            VideoEffectFrame(zoom = 0.3, offsetX = 0.05, offsetY = -0.03125),
            0xd7ef0dfc,
            0x364c51,
        ),
        Golden("mirror", VideoEffectFrame(mirrorX = 0.5), 0x8eba3800, 0xfb2fe1),
        Golden(
            "kaleidoscope",
            VideoEffectFrame(mirrorX = 0.35, mirrorY = 0.5),
            0x15a001c0,
            0xfb2fe1,
        ),
        Golden("tiles", VideoEffectFrame(tiles = 2), 0x32710580, 0x4e3360),
        Golden("zoomed tiles", VideoEffectFrame(zoom = 0.3, tiles = 2), 0xd3df8920, 0x5e1929),
        Golden(
            "wave",
            VideoEffectFrame(waveAmplitude = 0.05, wavePeriod = 0.5, wavePhase = 0.125),
            0xecd22b5b,
            0x9635e4,
        ),
        // The wave effect's own shape: the bend first, then a zoom that hides
        // the edges it uncovers.
        Golden(
            "zoomed wave",
            VideoEffectFrame(zoom = 0.11, waveAmplitude = 0.05, wavePeriod = 0.5, wavePhase = 0.125),
            0xe075e137,
            0x5140ca,
        ),
        Golden(
            "backward wave",
            VideoEffectFrame(waveAmplitude = -0.08, wavePeriod = 0.3, wavePhase = 0.9),
            0xf1c3cb72,
            0x4248ee,
        ),
        Golden(
            "geometry under everything",
            VideoEffectFrame(
                pixelSize = 0.125,
                rgbShift = 0.05,
                scanlines = 0.25,
                scanlinePeriod = 0.25,
                bands = listOf(VideoEffectBand(0.25, 0.5, 0.2)),
                zoom = 0.4,
                offsetX = 0.02,
                offsetY = 0.01,
                mirrorX = 0.35,
                mirrorY = 0.5,
                tiles = 2,
                waveAmplitude = 0.04,
                wavePeriod = 0.75,
                wavePhase = 0.4,
            ),
            0x73ef363b,
            0xa5991b,
        ),
        Golden(
            "negative over noise",
            VideoEffectFrame(
                noise = 0.4,
                noiseCellSize = 0.0625,
                noiseOffsetX = 64,
                noiseOffsetY = 1,
                invert = 1.0,
            ),
            0x0a1db883,
            0x08d422,
        ),
    )

    /** An order-sensitive hash of every red, green and blue byte. */
    private fun checksum(pixels: IntArray): Long {
        var h = 0L
        for (p in pixels) {
            for (shift in intArrayOf(16, 8, 0)) {
                h = (h * 31 + ((p shr shift) and 0xFF)) and 0xFFFFFFFFL
            }
        }
        return h
    }

    @Test
    fun goldens_matchTheSharedSpec() {
        for (golden in goldens) {
            val out = VideoEffectMath.apply(source, width, height, golden.frame)
            assertEquals(golden.checksum, checksum(out), golden.name)
            assertEquals(golden.sample, out[6 * width + 5] and 0xFFFFFF, golden.name)
        }
    }

    @Test
    fun pixelate_fillsEachBlockWithItsCenterPixel() {
        // 24 * 0.25 = 6 px blocks; the block at the origin takes (3, 3).
        val out = VideoEffectMath.apply(source, width, height, VideoEffectFrame(pixelSize = 0.25))
        for (y in 0 until 6) for (x in 0 until 6) {
            assertEquals(source[3 * width + 3], out[y * width + x], "($x, $y)")
        }
    }

    @Test
    fun rgbShift_movesRedLeftAndBlueRight() {
        // 24 * 0.1 = 2.4, rounded to 2 px.
        val out = VideoEffectMath.apply(source, width, height, VideoEffectFrame(rgbShift = 0.1))
        val x = 10
        val y = 4
        assertEquals((source[y * width + x + 2] shr 16) and 0xFF, (out[y * width + x] shr 16) and 0xFF)
        assertEquals((source[y * width + x] shr 8) and 0xFF, (out[y * width + x] shr 8) and 0xFF)
        assertEquals(source[y * width + x - 2] and 0xFF, out[y * width + x] and 0xFF)
    }

    @Test
    fun bands_repeatTheEdgeColumnWhereTheyPullInFromOutside() {
        // A band over the top half, moved right by 24 * 0.5 = 12 px.
        val frame = VideoEffectFrame(bands = listOf(VideoEffectBand(0.0, 0.5, 0.5)))
        val out = VideoEffectMath.apply(source, width, height, frame)
        for (x in 0 until 12) assertEquals(source[0], out[x], "column $x")
        assertEquals(source[11], out[23])
        // Below the band nothing moves.
        assertEquals(source[8 * width + 3], out[8 * width + 3])
    }

    @Test
    fun scanlines_darkenTheLowerHalfOfEveryPeriod() {
        // Period 16 * 0.25 = 4 rows: rows 2 and 3 of each period are dark.
        val frame = VideoEffectFrame(scanlines = 1.0, scanlinePeriod = 0.25)
        val out = VideoEffectMath.apply(source, width, height, frame)
        for (y in 0 until height) {
            val dark = y % 4 >= 2
            assertEquals(dark, out[y * width + 7] and 0xFFFFFF == 0, "row $y")
        }
    }

    @Test
    fun vignette_keepsTheCenterAndDarkensTheCornersMost() {
        fun factor(x: Int, y: Int) = VideoEffectMath.vignetteFactor(x, y, width, height, 1.0, 0.5)
        assertEquals(1.0, factor(11, 7))
        assertTrue(factor(0, 7) < 1.0)
        assertTrue(factor(0, 0) < factor(0, 7))
        // Symmetric about both center lines.
        assertEquals(factor(0, 0), factor(width - 1, height - 1), 1e-12)
    }

    @Test
    fun mirror_showsTheLeftHalfMirroredOnTheRight() {
        val out = VideoEffectMath.apply(source, width, height, VideoEffectFrame(mirrorX = 0.5))
        for (y in 0 until height) for (x in 0 until width / 2) {
            assertEquals(source[y * width + x], out[y * width + x], "($x, $y)")
            assertEquals(source[y * width + x], out[y * width + width - 1 - x], "mirror of ($x, $y)")
        }
    }

    @Test
    fun tiles_showTheWholePictureAtHalfSizeInEachQuarter() {
        val out = VideoEffectMath.apply(source, width, height, VideoEffectFrame(tiles = 2))
        // Each pixel of a quarter averages a 2x2 block of the source.
        fun channel(p: Int, shift: Int) = (p shr shift) and 0xFF
        for ((x, y) in listOf(0 to 0, 5 to 3, 11 to 7)) {
            for (shift in intArrayOf(16, 8, 0)) {
                val block = listOf(0 to 0, 1 to 0, 0 to 1, 1 to 1).sumOf { (dx, dy) ->
                    channel(source[(2 * y + dy) * width + 2 * x + dx], shift)
                }
                for ((qx, qy) in listOf(0 to 0, 12 to 0, 0 to 8, 12 to 8)) {
                    val actual = channel(out[(qy + y) * width + qx + x], shift)
                    assertTrue(
                        kotlin.math.abs(actual - block / 4.0) <= 0.5 + 1e-9,
                        "($x, $y) in the quarter at ($qx, $qy): $actual for ${block / 4.0}",
                    )
                }
            }
        }
    }

    @Test
    fun wave_movesEachRowByTheWaveAtItsCenter() {
        // Row 0's center, half a pixel down, sits on the crest of the wave:
        // t = (0.5 / 8 + 0.1875) * 16 = 4, where the sine is 1.
        val frame = VideoEffectFrame(waveAmplitude = 1.0 / 24, wavePeriod = 0.5, wavePhase = 0.1875)
        assertEquals(1.0, VideoEffectMath.waveShift(0.5, width, height, frame))
        val out = VideoEffectMath.apply(source, width, height, frame)
        // The row moves one pixel right and repeats its edge pixel.
        assertEquals(source[0], out[0])
        for (x in 1 until width) assertEquals(source[x - 1], out[x], "column $x")
        // Between knots the wave runs straight: halfway to the next one.
        assertEquals(
            (1.0 + kotlin.math.sin(2 * Math.PI * 5 / 16)) / 2,
            VideoEffectMath.waveShift(0.75, width, height, frame),
            1e-12,
        )
    }

    @Test
    fun noise_isDeterministicAndCentered() {
        var sum = 0.0
        for (u in 0 until VideoEffectMath.NOISE_TILE) for (v in 0 until VideoEffectMath.NOISE_TILE) {
            val n = VideoEffectMath.noiseAt(u, v)
            assertTrue(n >= 0.0 && n < 1.0)
            sum += n
        }
        val mean = sum / (VideoEffectMath.NOISE_TILE * VideoEffectMath.NOISE_TILE)
        assertEquals(0.5, mean, 0.01)
        assertEquals(VideoEffectMath.noiseAt(17, 99), VideoEffectMath.noiseAt(17, 99))
    }
}
