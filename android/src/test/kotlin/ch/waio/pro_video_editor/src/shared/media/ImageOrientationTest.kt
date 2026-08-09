package ch.waio.pro_video_editor.src.shared.media

import androidx.exifinterface.media.ExifInterface
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the EXIF-orientation contract for caller-supplied images.
 *
 * A phone stores a portrait photo as *landscape* pixels plus an `Orientation`
 * tag; every path that takes encoded bytes from the caller — the chroma-key
 * background, image layers, stop-motion frames — decodes through
 * [ImageOrientation] so the image renders the way the user sees it in their
 * photo library. iOS and macOS pin the same contract for `decodeOrientedImage`
 * in `DecodeOrientedImageTests`.
 *
 * The fixtures are built here rather than checked in because the usual encoders
 * bake the orientation into the pixels and drop the tag, so a "landscape pixels
 * + Orientation=6" image cannot be produced by round-tripping one; the APP1 EXIF
 * segment is written out by hand in [jpegWithOrientation].
 *
 * Scope: this is a JVM unit test, where `BitmapFactory` returns null for
 * everything, so it drives [ImageOrientation.probeOf] — the seam
 * [ImageOrientation.probe] hands its header-decoded size to, and the one
 * `ChromaKeyEffect` sizes its background texture from — with the stored size
 * supplied directly. The pixel decode itself is covered on-device by the Swift
 * tests and the example integration tests.
 */
internal class ImageOrientationTest {

    /** A stored frame that is landscape, as a portrait phone photo is. */
    private val storedWidth = 1600
    private val storedHeight = 1200

    @Test
    fun taggedImageReportsItsOrientation() {
        val tagged = jpegWithOrientation(ExifInterface.ORIENTATION_ROTATE_90)

        assertEquals(ExifInterface.ORIENTATION_ROTATE_90, ImageOrientation.read(tagged))
    }

    @Test
    fun taggedImageSwapsTheDimensionsOfTheStoredPixels() {
        val tagged = jpegWithOrientation(ExifInterface.ORIENTATION_ROTATE_90)

        val probe = ImageOrientation.probeOf(storedWidth, storedHeight, tagged)

        assertEquals(storedHeight, probe.width)
        assertEquals(storedWidth, probe.height)
        assertEquals(ExifInterface.ORIENTATION_ROTATE_90, probe.orientation)
    }

    /**
     * The counter-test: without it, "rotate everything" would satisfy
     * [taggedImageSwapsTheDimensionsOfTheStoredPixels].
     */
    @Test
    fun untaggedImageIsNotRotated() {
        val untagged = jpegWithOrientation(null)

        val probe = ImageOrientation.probeOf(storedWidth, storedHeight, untagged)

        assertEquals(storedWidth, probe.width)
        assertEquals(storedHeight, probe.height)
        assertEquals(ExifInterface.ORIENTATION_NORMAL, probe.orientation)
        assertFalse(ImageOrientation.swapsDimensions(probe.orientation))
    }

    /**
     * Bytes that are not an image, and tags outside the eight defined values,
     * must not be treated as rotated.
     */
    @Test
    fun unreadableOrNonsenseOrientationsFallBackToNoRotation() {
        val cases = mapOf(
            "garbage" to byteArrayOf(0x00, 0x01, 0x02, 0x03),
            "empty" to ByteArray(0),
            "out-of-range tag" to jpegWithOrientation(42),
        )

        for ((label, bytes) in cases) {
            assertEquals(ExifInterface.ORIENTATION_NORMAL, ImageOrientation.read(bytes), label)
            val probe = ImageOrientation.probeOf(storedWidth, storedHeight, bytes)
            assertEquals(storedWidth, probe.width, label)
            assertEquals(storedHeight, probe.height, label)
        }
    }

    @Test
    fun onlyQuarterTurnsExchangeWidthAndHeight() {
        val swapping = listOf(
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_ROTATE_270,
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_TRANSVERSE,
        )
        val keeping = listOf(
            ExifInterface.ORIENTATION_UNDEFINED,
            ExifInterface.ORIENTATION_NORMAL,
            ExifInterface.ORIENTATION_ROTATE_180,
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL,
            ExifInterface.ORIENTATION_FLIP_VERTICAL,
        )

        for (orientation in swapping) {
            assertTrue(ImageOrientation.swapsDimensions(orientation), "orientation $orientation")
            assertEquals(
                Pair(storedHeight, storedWidth),
                ImageOrientation.orientedSize(storedWidth, storedHeight, orientation),
                "orientation $orientation"
            )
        }
        for (orientation in keeping) {
            assertFalse(ImageOrientation.swapsDimensions(orientation), "orientation $orientation")
            assertEquals(
                Pair(storedWidth, storedHeight),
                ImageOrientation.orientedSize(storedWidth, storedHeight, orientation),
                "orientation $orientation"
            )
        }
    }

    /**
     * Every one of the eight EXIF orientations must round-trip through the APP1
     * segment, so a photo tagged with any of them is read as itself.
     */
    @Test
    fun everyOrientationRoundTripsThroughTheExifSegment() {
        for (orientation in 1..8) {
            assertEquals(
                orientation,
                ImageOrientation.read(jpegWithOrientation(orientation)),
                "orientation $orientation"
            )
        }
    }

    /**
     * A stop-motion frame is handed over as a file path rather than as bytes, so
     * a long sequence never sits in the managed heap all at once. That only
     * holds up if a frame read off disk is oriented like the same bytes in
     * memory — reading EXIF from the wrong end of a file, or not at all, would
     * put every photo in the export back on its side.
     */
    @Test
    fun aFileIsOrientedLikeTheSameBytesInMemory() {
        for (orientation in 1..8) {
            val bytes = jpegWithOrientation(orientation)
            val file = File.createTempFile("frame_$orientation", ".jpg")
            file.deleteOnExit()
            file.writeBytes(bytes)

            assertEquals(
                ImageOrientation.read(bytes),
                ImageOrientation.read(EncodedImage.OfFile(file)),
                "orientation $orientation"
            )
            assertEquals(
                ImageOrientation.probeOf(storedWidth, storedHeight, bytes).width,
                ImageOrientation.probeOf(
                    storedWidth, storedHeight, EncodedImage.OfFile(file)
                ).width,
                "orientation $orientation"
            )
        }
    }

    /** An unreadable frame falls back to "no transform" instead of throwing. */
    @Test
    fun aMissingFileReportsTheNormalOrientation() {
        val missing = File("/definitely/not/a/frame.jpg")

        assertEquals(
            ExifInterface.ORIENTATION_NORMAL,
            ImageOrientation.read(EncodedImage.OfFile(missing))
        )
    }

    @Test
    fun sampleSizeHalvesUntilTheTargetWouldBeUndershot() {
        // 1600×1200 into 400×300: two halvings land exactly on the target, a
        // third would fall below it.
        assertEquals(4, ImageOrientation.sampleSizeFor(1600, 1200, 400, 300))
        assertEquals(1, ImageOrientation.sampleSizeFor(1600, 1200, 1600, 1200))
        // A non-positive target means "full resolution".
        assertEquals(1, ImageOrientation.sampleSizeFor(1600, 1200, 0, 0))
    }

    /**
     * A JPEG container carrying nothing but an APP1 EXIF segment declaring
     * [orientation] — or no segment at all when it is null.
     *
     * Only the metadata matters here: the JVM test harness has no `BitmapFactory`
     * to decode pixels with, and [ImageOrientation.read] looks at the APP1
     * segment alone.
     */
    private fun jpegWithOrientation(orientation: Int?): ByteArray {
        val soi = byteArrayOf(0xFF.toByte(), 0xD8.toByte())
        val eoi = byteArrayOf(0xFF.toByte(), 0xD9.toByte())
        val app1 = if (orientation == null) ByteArray(0) else byteArrayOf(
            0xFF.toByte(), 0xE1.toByte(), 0x00, 0x22, // APP1, length 34 = 2 + 32
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00,       // "Exif\0\0"
            0x4D, 0x4D, 0x00, 0x2A,                   // TIFF header, big-endian
            0x00, 0x00, 0x00, 0x08,                   // IFD0 sits 8 bytes in
            0x00, 0x01,                               // one entry
            0x01, 0x12,                               // tag 0x0112: Orientation
            0x00, 0x03,                               // type 3: SHORT
            0x00, 0x00, 0x00, 0x01,                   // count 1
            0x00, orientation.toByte(), 0x00, 0x00,   // the value, left-aligned
            0x00, 0x00, 0x00, 0x00,                   // no next IFD
        )
        return soi + app1 + eoi
    }
}
