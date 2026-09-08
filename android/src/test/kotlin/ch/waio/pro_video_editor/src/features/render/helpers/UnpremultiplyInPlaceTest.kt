package ch.waio.pro_video_editor.src.features.render.helpers

import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [unpremultiplyInPlace], which undoes the premultiplication
 * `BitmapFactory` applies so Media3's overlay shader does not multiply by alpha
 * a second time.
 *
 * It runs in place on the buffer the bitmap was copied into, because a second
 * full-frame `ByteArray` would double the Java-heap peak on a path that already
 * reached Android's per-app growth limit once per overlay layer. In-place
 * mutation makes the read/write order load-bearing in a way the copy-out
 * version did not, so the arithmetic is pinned here.
 */
internal class UnpremultiplyInPlaceTest {

    /** Raw ARGB_8888 byte order is R, G, B, A — not the name's order. */
    private fun buffer(vararg bytes: Int): ByteBuffer =
        ByteBuffer.allocate(bytes.size).apply {
            bytes.forEach { put(it.toByte()) }
            rewind()
        }

    private fun ByteBuffer.bytes(): List<Int> =
        (0 until capacity()).map { get(it).toInt() and 0xFF }

    @Test
    fun halfAlphaDoublesTheColour() {
        val buf = buffer(64, 32, 16, 128)

        unpremultiplyInPlace(buf, 4)

        assertEquals(listOf(127, 63, 31, 128), buf.bytes())
    }

    /** Opaque pixels carry no premultiplication to undo. */
    @Test
    fun fullyOpaqueIsUntouched() {
        val buf = buffer(10, 20, 30, 255)

        unpremultiplyInPlace(buf, 4)

        assertEquals(listOf(10, 20, 30, 255), buf.bytes())
    }

    /** `a == 0` carries no colour to recover, and dividing by it would throw. */
    @Test
    fun fullyTransparentIsUntouched() {
        val buf = buffer(0, 0, 0, 0)

        unpremultiplyInPlace(buf, 4)

        assertEquals(listOf(0, 0, 0, 0), buf.bytes())
    }

    /** A channel above its own alpha saturates rather than wrapping negative. */
    @Test
    fun theResultIsClampedByTheByteItFitsIn() {
        val buf = buffer(200, 100, 50, 100)

        unpremultiplyInPlace(buf, 4)

        // 200 * 255 / 100 = 510, which does not fit a byte; the cast keeps the
        // low 8 bits (510 -> 254). Pinned so a future clamp is a deliberate
        // change rather than a silent one.
        assertEquals(listOf(254, 255, 127, 100), buf.bytes())
    }

    @Test
    fun everyPixelIsConvertedIndependently() {
        val buf = buffer(
            64, 32, 16, 128,
            10, 20, 30, 255,
            9, 9, 9, 0,
        )

        unpremultiplyInPlace(buf, 12)

        assertEquals(
            listOf(127, 63, 31, 128, 10, 20, 30, 255, 9, 9, 9, 0),
            buf.bytes(),
        )
    }

    /** Bytes past [byteCount] belong to no pixel and must not be touched. */
    @Test
    fun bytesBeyondTheCountAreLeftAlone() {
        val buf = buffer(64, 32, 16, 128, 64, 32, 16, 128)

        unpremultiplyInPlace(buf, 4)

        assertEquals(listOf(127, 63, 31, 128, 64, 32, 16, 128), buf.bytes())
    }

    /** A trailing partial pixel is not read past the end of the buffer. */
    @Test
    fun aTruncatedTrailingPixelIsSkipped() {
        val buf = buffer(64, 32, 16, 128, 64, 32)

        unpremultiplyInPlace(buf, 6)

        assertEquals(listOf(127, 63, 31, 128, 64, 32), buf.bytes())
    }
}
