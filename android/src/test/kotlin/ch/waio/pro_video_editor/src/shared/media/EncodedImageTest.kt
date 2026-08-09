package ch.waio.pro_video_editor.src.shared.media

import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins how a caller-supplied image is read off a channel map.
 *
 * Every image the plugin takes — stop-motion frames, image layers, the
 * chroma-key background — arrives either as a path or as bytes, and picking the
 * wrong one is what the sum type exists to prevent: choosing bytes for a
 * file-backed image puts the copy back that the path was meant to avoid, and
 * choosing a blank path decodes nothing at all.
 *
 * Scope: a JVM unit test over map parsing and file I/O. `BitmapFactory` returns
 * null for everything here, so the decode itself is covered on-device by the
 * example integration tests.
 */
internal class EncodedImageTest {

    @Test
    fun aPathWinsOverBytes() {
        val image = EncodedImage.fromMap(
            mapOf("imagePath" to "/photos/frame.jpg", "imageData" to byteArrayOf(1, 2)),
            pathKey = "imagePath",
            dataKey = "imageData",
        )

        assertTrue(image is EncodedImage.OfFile)
        assertEquals("/photos/frame.jpg", image.file.path)
    }

    @Test
    fun bytesAreUsedWhenThereIsNoPath() {
        val image = EncodedImage.fromMap(
            mapOf("imageData" to byteArrayOf(1, 2, 3)),
            pathKey = "imagePath",
            dataKey = "imageData",
        )

        assertTrue(image is EncodedImage.OfBytes)
        assertContentEquals(byteArrayOf(1, 2, 3), image.data)
    }

    /**
     * A blank path and an empty byte array are both "nothing here", not a
     * source that happens to decode to nothing.
     */
    @Test
    fun emptySourcesAreNoSourceAtAll() {
        val blankPathWithBytes = EncodedImage.fromMap(
            mapOf("imagePath" to "  ", "imageData" to byteArrayOf(9)),
            pathKey = "imagePath",
            dataKey = "imageData",
        )
        assertTrue(blankPathWithBytes is EncodedImage.OfBytes)

        assertNull(
            EncodedImage.fromMap(
                mapOf("imagePath" to "", "imageData" to ByteArray(0)),
                pathKey = "imagePath",
                dataKey = "imageData",
            )
        )
        assertNull(
            EncodedImage.fromMap(emptyMap(), pathKey = "imagePath", dataKey = "imageData")
        )
    }

    /** The keys differ per feature, so they are never assumed. */
    @Test
    fun theKeysAreTheOnesTheCallerNames() {
        val image = EncodedImage.fromMap(
            mapOf("bgImagePath" to "/photos/bg.jpg"),
            pathKey = "bgImagePath",
            dataKey = "bgImageData",
        )

        assertTrue(image is EncodedImage.OfFile)
        assertNull(
            EncodedImage.fromMap(
                mapOf("bgImagePath" to "/photos/bg.jpg"),
                pathKey = "imagePath",
                dataKey = "imageData",
            )
        )
    }

    /**
     * A format sniff must not pull the whole file in — that is the copy the
     * path exists to avoid.
     */
    @Test
    fun aHeaderReadStopsAtTheRequestedLength() {
        val file = File.createTempFile("encoded_image", ".gif")
        file.deleteOnExit()
        file.writeBytes("GIF89a".toByteArray() + ByteArray(4096))

        assertContentEquals(
            "GIF".toByteArray(),
            EncodedImage.OfFile(file).readHeader(3),
        )
        assertContentEquals(
            "GIF".toByteArray(),
            EncodedImage.OfBytes(file.readBytes()).readHeader(3),
        )
    }

    /** A file shorter than the request comes back short rather than padded. */
    @Test
    fun aShortFileYieldsWhatItHas() {
        val file = File.createTempFile("encoded_image_short", ".bin")
        file.deleteOnExit()
        file.writeBytes(byteArrayOf(1, 2))

        assertContentEquals(byteArrayOf(1, 2), EncodedImage.OfFile(file).readHeader(8))
    }

    @Test
    fun anUnreadableFileReportsNothingInsteadOfThrowing() {
        val missing = EncodedImage.OfFile(File("/definitely/not/an/image.jpg"))

        assertNull(missing.readHeader(3))
        assertNull(missing.readBytes())
    }

    /**
     * The configs holding an image are plain data classes, so their equality
     * rests on this being structural rather than by reference.
     */
    @Test
    fun equalityLooksAtTheContent() {
        assertEquals(
            EncodedImage.OfBytes(byteArrayOf(1, 2, 3)),
            EncodedImage.OfBytes(byteArrayOf(1, 2, 3)),
        )
        assertEquals(
            EncodedImage.OfFile(File("/a.jpg")),
            EncodedImage.OfFile(File("/a.jpg")),
        )
        assertTrue(
            EncodedImage.OfBytes(byteArrayOf(1)) != EncodedImage.OfBytes(byteArrayOf(2))
        )
        assertTrue(
            EncodedImage.OfFile(File("/a.jpg")) != EncodedImage.OfFile(File("/b.jpg"))
        )
    }

    /** A decode failure has to be able to name which image it was. */
    @Test
    fun aSourceDescribesItself() {
        assertEquals("/photos/frame.jpg", EncodedImage.OfFile(File("/photos/frame.jpg")).describe())
        assertEquals("3 bytes", EncodedImage.OfBytes(byteArrayOf(1, 2, 3)).describe())
    }
}
