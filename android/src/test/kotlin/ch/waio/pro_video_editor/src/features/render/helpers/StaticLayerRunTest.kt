package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.Effect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.effect.TimestampWrapper
import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerAudioVisualizerConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerBlendMode
import ch.waio.pro_video_editor.src.features.render.models.LayerCensorConfig
import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import org.mockito.Mockito.mock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Pins which layers are drawn into one image and how overlays share effects.
 *
 * Every overlay used to keep its own bitmap and its own Media3 effect for the
 * whole render, so memory grew with every sticker. These are the rules that
 * keep it flat without changing what a layer looks like: only layers that look
 * the same on every frame are drawn together, and only overlays shown over the
 * same time range share an effect.
 */
internal class StaticLayerRunTest {

    private val png = EncodedImage.OfBytes(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte()))
    private val gif = EncodedImage.OfBytes("GIF89a".toByteArray())

    private fun layer(
        image: EncodedImage? = png,
        startUs: Long = -1L,
        endUs: Long = -1L,
        animations: List<LayerAnimationConfig> = emptyList(),
        keyframes: List<KeyframeConfig> = emptyList(),
        censor: LayerCensorConfig? = null,
        audioVisualizer: LayerAudioVisualizerConfig? = null,
        blendMode: LayerBlendMode = LayerBlendMode.NORMAL,
    ) = VideoSequenceBuilder.ImageLayerConfig(
        image = image,
        scaleX = null,
        scaleY = null,
        startUs = startUs,
        endUs = endUs,
        x = 10,
        y = 20,
        width = 100.0,
        height = 50.0,
        animations = animations,
        keyframes = keyframes,
        censor = censor,
        audioVisualizer = audioVisualizer,
        blendMode = blendMode,
    )

    @Test
    fun staticLayersInARowFormOneRun() {
        val layers = List(200) { layer() }

        assertEquals(200, staticLayerRunLength(layers, 0))
        assertEquals(1, staticLayerRunLength(layers, 199))
    }

    @Test
    fun aRunEndsWhereTheTimeRangeChanges() {
        val layers = listOf(
            layer(startUs = 0L, endUs = 1_000_000L),
            layer(startUs = 0L, endUs = 1_000_000L),
            layer(startUs = 0L, endUs = 2_000_000L),
        )

        assertEquals(2, staticLayerRunLength(layers, 0))
    }

    @Test
    fun aRunEndsAtALayerThatChangesOverTime() {
        val fade = LayerAnimationConfig(type = "fade", phase = "animateIn", durationUs = 500_000L)
        val keyframe = KeyframeConfig(timeUs = 0L, x = 0.0, y = 0.0)
        for (moving in listOf(
            layer(animations = listOf(fade)),
            layer(keyframes = listOf(keyframe)),
            layer(image = gif),
        )) {
            assertEquals(1, staticLayerRunLength(listOf(layer(), moving, layer()), 0))
        }
    }

    @Test
    fun aRunEndsAtACensorLayer() {
        val censor = LayerCensorConfig(LayerCensorConfig.Type.BLUR, 10.0)

        assertEquals(1, staticLayerRunLength(listOf(layer(), layer(censor = censor)), 0))
    }

    @Test
    fun aRunEndsAtABlendedLayer() {
        // It blends with the frame beneath it, which an image of the static
        // layers drawn over transparency does not hold.
        val blended = layer(blendMode = LayerBlendMode.SCREEN)

        assertEquals(1, staticLayerRunLength(listOf(layer(), blended, layer()), 0))
        assertEquals(0, staticLayerRunLength(listOf(blended, layer()), 0))
        assertFalse(isStaticImageLayer(blended))
    }

    @Test
    fun aLayerThatIsNotStaticStartsNoRun() {
        val visualizer = LayerAudioVisualizerConfig(
            style = LayerAudioVisualizerConfig.Style.BARS,
            color = 0,
            bandCount = 1,
            levels = floatArrayOf(0f),
            framesPerSecond = 30.0,
        )

        assertEquals(0, staticLayerRunLength(listOf(layer(audioVisualizer = visualizer)), 0))
        assertEquals(0, staticLayerRunLength(listOf(layer(image = null), layer()), 0))
        assertEquals(0, staticLayerRunLength(listOf(layer(image = gif), layer()), 0))
    }

    @Test
    fun aLayerWithAnUnreadableImageIsNotStatic() {
        val missing = EncodedImage.OfFile(java.io.File("/does/not/exist.png"))

        assertFalse(isStaticImageLayer(layer(image = missing)))
        assertTrue(isStaticImageLayer(layer()))
    }

    @Test
    fun emptyTimeRanges() {
        assertFalse(isEmptyTimeRange(-1L, -1L))
        assertFalse(isEmptyTimeRange(-1L, 1L))
        assertFalse(isEmptyTimeRange(5L, -1L))
        assertFalse(isEmptyTimeRange(5L, 6L))
        assertTrue(isEmptyTimeRange(-1L, 0L))
        assertTrue(isEmptyTimeRange(5L, 5L))
        assertTrue(isEmptyTimeRange(5L, 4L))
        assertTrue(isEmptyTimeRange(-2L, 4L))
    }

    @Test
    fun overlaysOverOneTimeRangeShareEffectsOfAtMostFifteen() {
        val effects = mutableListOf<Effect>()
        val batch = OverlayBatch(effects)

        repeat(MAX_OVERLAYS_PER_EFFECT + 1) { batch.add(overlay(), -1L, -1L) }
        batch.flush()

        assertEquals(2, effects.size)
        effects.forEach { assertIs<OverlayEffect>(it) }
    }

    @Test
    fun anOverlayOverAnotherTimeRangeStartsAnotherEffect() {
        val effects = mutableListOf<Effect>()
        val batch = OverlayBatch(effects)

        batch.add(overlay(), 0L, 1_000L)
        batch.add(overlay(), 0L, 1_000L)
        batch.add(overlay(), -1L, -1L)
        batch.add(overlay(), 0L, 1_000L)
        batch.flush()

        assertEquals(3, effects.size)
        val first = assertIs<TimestampWrapper>(effects[0])
        assertEquals(0L, first.startTimeUs)
        assertEquals(1_000L, first.endTimeUs)
        assertIs<OverlayEffect>(effects[1])
        assertIs<TimestampWrapper>(effects[2])
    }

    @Test
    fun anOverlayThatIsNeverShownIsLeftOut() {
        val effects = mutableListOf<Effect>()
        val batch = OverlayBatch(effects)

        batch.add(overlay(), 1_000L, 1_000L)
        batch.flush()

        assertTrue(effects.isEmpty())
    }

    @Test
    fun flushingTwiceAddsNothingTwice() {
        val effects = mutableListOf<Effect>()
        val batch = OverlayBatch(effects)

        batch.add(overlay(), -1L, -1L)
        batch.flush()
        batch.flush()

        assertEquals(1, effects.size)
    }

    private fun overlay(): TextureOverlay = mock(TextureOverlay::class.java)
}
