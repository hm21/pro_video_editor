package ch.waio.pro_video_editor.src.features.render.models

import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Pins how an image layer's `frames` list is read off the method channel. */
internal class ImageLayerFrameConfigTest {

    @Test
    fun readsEachFrameInOrderWithItsDuration() {
        val bytes = byteArrayOf(1, 2, 3)

        val frames = ImageLayerFrameConfig.listFrom(
            listOf(
                mapOf("imageData" to bytes, "durationUs" to 40_000),
                mapOf("imagePath" to "/tmp/frame.png", "durationUs" to 60_000L),
            )
        )

        assertEquals(
            listOf(
                ImageLayerFrameConfig(EncodedImage.OfBytes(bytes), 40_000L),
                ImageLayerFrameConfig(EncodedImage.OfFile(File("/tmp/frame.png")), 60_000L),
            ),
            frames,
        )
    }

    @Test
    fun leavesOutAFrameWithoutAnImageOrWithoutTime() {
        val bytes = byteArrayOf(1)

        val frames = ImageLayerFrameConfig.listFrom(
            listOf(
                mapOf("durationUs" to 40_000),
                mapOf("imageData" to bytes, "durationUs" to 0),
                mapOf("imageData" to bytes),
                mapOf("imageData" to bytes, "durationUs" to 40_000),
            )
        )

        assertEquals(listOf(ImageLayerFrameConfig(EncodedImage.OfBytes(bytes), 40_000L)), frames)
    }

    @Test
    fun readsNoFramesFromALayerWithout() {
        assertTrue(ImageLayerFrameConfig.listFrom(null).isEmpty())
    }
}
