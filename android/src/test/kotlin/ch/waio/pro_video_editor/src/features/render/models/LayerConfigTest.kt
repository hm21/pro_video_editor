package ch.waio.pro_video_editor.src.features.render.models

import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins how a composition layer's mask is read off the channel map that
 * `VideoLayer.toAsyncMap` sends: a file-backed matte as `maskPath`, any other as
 * `maskData`.
 *
 * Scope: map parsing only. `BitmapFactory` returns null for everything on the
 * JVM, so the matte's decode and the shader are covered by the example's
 * `layer_mask_test` integration test.
 */
internal class LayerConfigTest {

    private val clip = mapOf<String, Any?>("inputPath" to "/videos/pip.mp4")

    private fun layer(extra: Map<String, Any?> = emptyMap()): LayerConfig? =
        LayerConfig.fromMap(mapOf<String, Any?>("clips" to listOf(clip)) + extra)

    @Test
    fun aLayerWithoutMaskShowsItsClipsWhole() {
        assertNull(layer()!!.mask)
    }

    @Test
    fun readsAFileBackedMatteAsItsPath() {
        val mask = layer(mapOf("maskPath" to "/mattes/circle.png"))!!.mask

        assertTrue(mask is EncodedImage.OfFile)
        assertEquals("/mattes/circle.png", mask.file.path)
    }

    @Test
    fun readsAnInMemoryMatteAsItsBytes() {
        val mask = layer(mapOf("maskData" to byteArrayOf(1, 2, 3)))!!.mask

        assertTrue(mask is EncodedImage.OfBytes)
        assertContentEquals(byteArrayOf(1, 2, 3), mask.data)
    }

    @Test
    fun keepsTheMatteApartFromTheChromaKeyBackground() {
        // Both are images on the same layer map; reading one key for the other
        // would key the clip into the shape of its mask.
        val parsed = layer(
            mapOf(
                "maskData" to byteArrayOf(7),
                "chromaKey" to mapOf<String, Any?>(
                    "keyColor" to 0xFF00B140.toInt(),
                    "bgImageData" to byteArrayOf(9),
                ),
            )
        )!!

        assertContentEquals(byteArrayOf(7), (parsed.mask as EncodedImage.OfBytes).data)
        assertContentEquals(
            byteArrayOf(9),
            (parsed.chromaKey!!.backgroundImage as EncodedImage.OfBytes).data
        )
    }

    @Test
    fun theMatteSurvivesTheHdrRetargetOfTheClips() {
        // RenderVideo swaps the clips of every layer for their SDR transcodes
        // with `copy`, and the mask has to stay on the layer through that.
        val parsed = layer(mapOf("maskPath" to "/mattes/heart.png"))!!
        val retargeted = parsed.copy(
            clips = parsed.clips.map { it.copy(inputPath = "/cache/transcoded_pip.mp4") }
        )

        assertEquals(parsed.mask, retargeted.mask)
    }

    @Test
    fun everyLayerOfACompositionKeepsItsOwnMatte() {
        val composition = CompositionConfig.fromMap(
            mapOf(
                "layers" to listOf(
                    mapOf<String, Any?>("clips" to listOf(clip)),
                    mapOf<String, Any?>(
                        "clips" to listOf(clip),
                        "maskPath" to "/mattes/rounded.png",
                    ),
                ),
            )
        )!!

        assertNull(composition.layers[0].mask)
        assertEquals(
            "/mattes/rounded.png",
            (composition.layers[1].mask as EncodedImage.OfFile).file.path
        )
    }
}
