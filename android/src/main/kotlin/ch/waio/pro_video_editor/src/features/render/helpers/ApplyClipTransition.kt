package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.StaticOverlaySettings
import kotlin.math.max

/**
 * Full-frame solid-color overlay used to implement "dip" clip transitions
 * (fade-to-black / fade-to-white).
 *
 * A single instance is attached to a clip's effect pipeline. The overlay alpha
 * is computed per frame from the clip-local presentation time:
 * - [fadeInUs]  > 0: the clip fades **in from the dip color** over its first
 *   window (alpha 1 → 0).
 * - [fadeOutUs] > 0: the clip fades **out to the dip color** over its last
 *   window (alpha 0 → 1).
 *
 * Timestamps are clip-local (each [androidx.media3.transformer.EditedMediaItem]
 * in a sequence is processed with its own timeline), and the overlay is added
 * **after** any per-clip [androidx.media3.effect.SpeedChangeEffect] so the
 * windows are expressed in output-local time via [clipDurationUs].
 *
 * @param dipColor ARGB color the clip dips to/from (e.g. black or white).
 */
@UnstableApi
internal class ClipFadeOverlay(
    videoWidth: Int,
    videoHeight: Int,
    dipColor: Int,
    private val clipDurationUs: Long,
    private val fadeInUs: Long,
    private val fadeOutUs: Long,
    private val curve: String,
) : BitmapOverlay() {

    private val dipBitmap: Bitmap =
        Bitmap.createBitmap(
            max(1, videoWidth),
            max(1, videoHeight),
            Bitmap.Config.ARGB_8888,
        ).apply { eraseColor(dipColor) }

    private val settingsBuilder = StaticOverlaySettings.Builder()
        .setOverlayFrameAnchor(0f, 0f)
        .setBackgroundFrameAnchor(0f, 0f)

    /**
     * Smallest presentation timestamp seen so far. Media3 does **not** present
     * clip-local 0-based timestamps to per-clip effects (a trimmed/non-first
     * clip starts at its own offset), so we normalize against the first frame
     * the overlay sees. This makes the windows clip-relative regardless of the
     * underlying timestamp domain (source-based or cumulative).
     */
    private var firstTimeUs = Long.MIN_VALUE

    override fun getBitmap(presentationTimeUs: Long): Bitmap = dipBitmap

    override fun getOverlaySettings(presentationTimeUs: Long): StaticOverlaySettings {
        if (firstTimeUs == Long.MIN_VALUE || presentationTimeUs < firstTimeUs) {
            firstTimeUs = presentationTimeUs
        }
        val localUs = (presentationTimeUs - firstTimeUs).coerceAtLeast(0L)

        var alpha = 0f

        if (fadeInUs > 0 && localUs < fadeInUs) {
            val p = (localUs.toDouble() / fadeInUs).coerceIn(0.0, 1.0)
            // Fade in from black: opaque at start, transparent at the window end.
            alpha = (1.0 - applyEasing(p, curve)).toFloat()
        }

        if (fadeOutUs > 0) {
            val outStart = clipDurationUs - fadeOutUs
            if (localUs > outStart) {
                val p = ((localUs - outStart).toDouble() / fadeOutUs)
                    .coerceIn(0.0, 1.0)
                // Fade out to black: transparent at the window start, opaque at end.
                alpha = max(alpha, applyEasing(p, curve).toFloat())
            }
        }

        return settingsBuilder
            .setAlphaScale(alpha.coerceIn(0f, 1f))
            .build()
    }
}
