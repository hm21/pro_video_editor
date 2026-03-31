package ch.waio.pro_video_editor.src.features.render.helpers

import android.graphics.Bitmap
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.StaticOverlaySettings
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Applies an easing function to a linear progress value (0..1).
 */
internal fun applyEasing(t: Double, curve: String): Double {
    return when (curve) {
        "easeIn" -> t * t
        "easeOut" -> t * (2 - t)
        "easeInOut" -> if (t < 0.5) 2 * t * t else -1 + (4 - 2 * t) * t
        "easeInCubic" -> t * t * t
        "easeOutCubic" -> {
            val p = 1 - t
            1 - p * p * p
        }
        "easeInOutCubic" -> if (t < 0.5) 4 * t * t * t else 1 - (-2 * t + 2).pow(3) / 2
        "bounceIn" -> 1 - applyEasing(1 - t, "bounceOut")
        "bounceOut" -> when {
            t < 1 / 2.75 -> 7.5625 * t * t
            t < 2 / 2.75 -> {
                val t2 = t - 1.5 / 2.75
                7.5625 * t2 * t2 + 0.75
            }
            t < 2.5 / 2.75 -> {
                val t2 = t - 2.25 / 2.75
                7.5625 * t2 * t2 + 0.9375
            }
            else -> {
                val t2 = t - 2.625 / 2.75
                7.5625 * t2 * t2 + 0.984375
            }
        }
        "bounceInOut" -> if (t < 0.5) {
            (1 - applyEasing(1 - 2 * t, "bounceOut")) / 2
        } else {
            (1 + applyEasing(2 * t - 1, "bounceOut")) / 2
        }
        "elasticIn" -> 1 - applyEasing(1 - t, "elasticOut")
        "elasticOut" -> {
            if (t == 0.0 || t == 1.0) t
            else 2.0.pow(-10 * t) * sin((t - 0.075) * (2 * Math.PI) / 0.3) + 1
        }
        "elasticInOut" -> if (t < 0.5) {
            (1 - applyEasing(1 - 2 * t, "elasticOut")) / 2
        } else {
            (1 + applyEasing(2 * t - 1, "elasticOut")) / 2
        }
        else -> t // "linear"
    }
}

/**
 * Custom BitmapOverlay that computes per-frame overlay settings for animations.
 *
 * Uses [getOverlaySettings] to dynamically compute alpha, position offsets,
 * and scale based on the current presentation time and animation configs.
 */
@UnstableApi
internal class AnimatedBitmapOverlay(
    private val bitmap: Bitmap,
    private val baseNormX: Float,
    private val baseNormY: Float,
    private val imageWidth: Int,
    private val imageHeight: Int,
    private val videoWidth: Int,
    private val videoHeight: Int,
    private val layerStartUs: Long,
    private val layerEndUs: Long,
    private val animations: List<LayerAnimationConfig>
) : BitmapOverlay() {

    override fun getBitmap(presentationTimeUs: Long): Bitmap = bitmap

    override fun getOverlaySettings(presentationTimeUs: Long): StaticOverlaySettings {
        var alpha = 1.0f
        var offsetX = 0f
        var offsetY = 0f
        var scaleVal = 1.0f

        val effectiveStartUs = if (layerStartUs == -1L) 0L else layerStartUs
        val effectiveEndUs = if (layerEndUs == -1L) Long.MAX_VALUE else layerEndUs

        for (anim in animations) {
            val durationUs = anim.durationUs
            if (durationUs <= 0) continue

            // Determine progress for animateIn and/or animateOut
            var inProgress: Double? = null
            var outProgress: Double? = null

            if (anim.phase == "animateIn" || anim.phase == "animateInOut") {
                val elapsed = presentationTimeUs - effectiveStartUs
                if (elapsed < durationUs) {
                    inProgress = applyEasing(
                        max(0.0, min(1.0, elapsed.toDouble() / durationUs)),
                        anim.curve
                    )
                }
            }

            if (anim.phase == "animateOut" || anim.phase == "animateInOut") {
                val remaining = effectiveEndUs - presentationTimeUs
                if (remaining < durationUs) {
                    outProgress = applyEasing(
                        max(0.0, min(1.0, remaining.toDouble() / durationUs)),
                        anim.curve
                    )
                }
            }

            // Use the minimum progress (most visible animation effect)
            val progress: Double? = when {
                inProgress != null && outProgress != null -> min(inProgress, outProgress)
                else -> inProgress ?: outProgress
            }

            if (progress == null) continue

            when (anim.type) {
                "fade" -> alpha *= progress.toFloat()
                "slide" -> {
                    val invP = (1.0 - progress).toFloat()
                    // Normalized offset in OpenGL coordinates [-1, 1]
                    val normWidth = (imageWidth.toFloat() / videoWidth) * 2f
                    val normHeight = (imageHeight.toFloat() / videoHeight) * 2f
                    when (anim.slideDirection) {
                        "left" -> offsetX -= normWidth * invP
                        "right" -> offsetX += normWidth * invP
                        "top" -> offsetY += normHeight * invP  // OpenGL Y is up
                        "bottom" -> offsetY -= normHeight * invP
                    }
                }
                "scale" -> {
                    val scaleFrom = anim.scaleFrom?.toFloat() ?: 0f
                    scaleVal *= scaleFrom + (1f - scaleFrom) * progress.toFloat()
                }
            }
        }

        // Clamp values — elastic/bounce curves can overshoot [0,1]
        val clampedAlpha = alpha.coerceIn(0f, 1f)
        val clampedScale = scaleVal.coerceAtLeast(0f)

        return StaticOverlaySettings.Builder()
            .setAlphaScale(clampedAlpha)
            .setBackgroundFrameAnchor(baseNormX + offsetX, baseNormY + offsetY)
            .setOverlayFrameAnchor(0f, 0f)
            .setScale(clampedScale, clampedScale)
            .build()
    }
}
