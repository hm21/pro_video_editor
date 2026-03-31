package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import ch.waio.pro_video_editor.src.features.render.utils.getRotatedVideoDimensions
import java.io.File
import java.nio.ByteBuffer
import androidx.core.graphics.scale
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TimestampWrapper

/**
 * Applies static image overlay on video.
 *
 * Scales the image to match video dimensions after considering:
 * - Video rotation (dimension swap for 90°/270°)
 * - Applied cropping
 * - Applied scaling
 *
 * The overlay is rendered as a static bitmap on top of the video.
 *
 * @param videoEffects List to add overlay effect to
 * @param inputFile Video file for dimension detection
 * @param imageLayers List of image layers from config
 * @param rotationDegrees Applied rotation (affects dimensions)
 * @param cropWidth Applied crop width (affects overlay size)
 * @param cropHeight Applied crop height (affects overlay size)
 * @param scaleX Applied horizontal scale (affects overlay size)
 * @param scaleY Applied vertical scale (affects overlay size)
 */
@UnstableApi
fun applyImageLayer(
    videoEffects: MutableList<Effect>,
    inputFile: File,
    imageLayers: List<ch.waio.pro_video_editor.src.features.render.models.ImageLayer>,
    rotationDegrees: Float,
    cropWidth: Int?,
    cropHeight: Int?,
    scaleX: Float?,
    scaleY: Float?,
) {
    if (imageLayers.isEmpty()) return

    // The old single-image overlay is now handled via imageLayers.
    // Nothing to do here — timed layers are handled by applyTimedImageLayers.
}

/**
 * Applies time-based image overlays on video.
 *
 * Each image layer has a start and end time, and will only be visible during that time range.
 * Multiple layers can be active simultaneously.
 * When x/y are null, the image is stretched to fill the video frame.
 * When x/y are set, the image is positioned at the specified offset.
 *
 * @param videoEffects List to add overlay effects to
 * @param imageLayers List of image layers with timing information
 * @param videoWidth Width of the video frame for positioning
 * @param videoHeight Height of the video frame for positioning
 */
@UnstableApi
fun applyTimedImageLayers(
    videoEffects: MutableList<Effect>,
    imageLayers: List<VideoSequenceBuilder.ImageLayerConfig>,
    videoWidth: Int,
    videoHeight: Int
) {
    if (imageLayers.isEmpty()) return

    Log.d(
        RENDER_TAG,
        "Applying ${imageLayers.size} time-based image layer(s) to ${videoWidth}x$videoHeight video"
    )
    for (layer in imageLayers) {
        try {
            val imageBytes = layer.imageBytes ?: continue
            val options = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val layerBitmap = BitmapFactory.decodeByteArray(
                imageBytes, 0, imageBytes.size, options
            )

            // Determine if this layer should stretch or be positioned
            val isStretched = layer.x == null && layer.y == null

            val finalOverlay: Bitmap
            val overlaySettings: StaticOverlaySettings
            var baseNormX = 0f
            var baseNormY = 0f

            if (isStretched) {
                // Stretch image to fill the entire video frame
                val scaledOverlay = if (layerBitmap.width != videoWidth || layerBitmap.height != videoHeight) {
                    val scaled = layerBitmap.scale(videoWidth, videoHeight)
                    layerBitmap.recycle()
                    scaled
                } else {
                    layerBitmap
                }

                val unpremultiplied = unpremultiplyAlpha(scaledOverlay)
                if (unpremultiplied !== scaledOverlay) scaledOverlay.recycle()
                finalOverlay = unpremultiplied

                overlaySettings = StaticOverlaySettings.Builder()
                    .setOverlayFrameAnchor(0f, 0f)
                    .setBackgroundFrameAnchor(0f, 0f)
                    .build()

                Log.d(RENDER_TAG, "Layer: stretched to ${videoWidth}x$videoHeight")
            } else {
                // Position image at specified x/y offset
                val imageWidth = layerBitmap.width
                val imageHeight = layerBitmap.height

                val unpremultiplied = unpremultiplyAlpha(layerBitmap)
                if (unpremultiplied !== layerBitmap) layerBitmap.recycle()
                finalOverlay = unpremultiplied

                val x = layer.x ?: 0
                val y = layer.y ?: 0

                // Use OverlaySettings for positioning
                // Media3 uses OpenGL coordinates: x[-1,1] left→right, y[-1,1] bottom→top.
                // Input uses top-left origin, so y must be flipped.
                val centerX = x.toFloat() + imageWidth / 2f
                val centerY = y.toFloat() + imageHeight / 2f
                baseNormX = (centerX / videoWidth) * 2f - 1f
                baseNormY = 1f - (centerY / videoHeight) * 2f

                overlaySettings = StaticOverlaySettings.Builder()
                    .setBackgroundFrameAnchor(baseNormX, baseNormY)
                    .setOverlayFrameAnchor(0f, 0f)
                    .build()

                Log.d(
                    RENDER_TAG,
                    "Layer: positioned at ($x, $y), size=${imageWidth}x${imageHeight}"
                )
            }

            // Convert times from microseconds
            val startTimeUs = layer.startUs
            val endTimeUs = layer.endUs

            Log.d(
                RENDER_TAG,
                "Layer timing: ${if (startTimeUs == -1L) "from start" else "start=${startTimeUs}us"}," +
                        " ${if (endTimeUs == -1L) "until end" else "end=${endTimeUs}us"}"
            )

            val hasAnimations = layer.animations.isNotEmpty()
            val bitmapOverlay: BitmapOverlay

            if (hasAnimations) {
                val imageWidth = finalOverlay.width
                val imageHeight = finalOverlay.height
                bitmapOverlay = AnimatedBitmapOverlay(
                    bitmap = finalOverlay,
                    baseNormX = baseNormX,
                    baseNormY = baseNormY,
                    imageWidth = imageWidth,
                    imageHeight = imageHeight,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    layerStartUs = startTimeUs,
                    layerEndUs = endTimeUs,
                    animations = layer.animations
                )
                Log.d(RENDER_TAG, "Layer: using AnimatedBitmapOverlay with ${layer.animations.size} animation(s)")
            } else {
                bitmapOverlay = BitmapOverlay.createStaticBitmapOverlay(
                    finalOverlay, overlaySettings
                )
            }
            val overlayEffect = OverlayEffect(listOf(bitmapOverlay))

            if (startTimeUs == -1L && endTimeUs == -1L) {
                // No time range set — show for the entire video
                videoEffects += overlayEffect
            } else {
                val effectiveStart = if (startTimeUs == -1L) 0L else startTimeUs
                val effectiveEnd = if (endTimeUs == -1L) Long.MAX_VALUE else endTimeUs
                videoEffects += TimestampWrapper(
                    overlayEffect, effectiveStart, effectiveEnd
                )
            }

        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to decode image layer: ${e.message}")
        }
    }
}

/**
 * Converts premultiplied-alpha pixel data to straight alpha.
 *
 * Required because BitmapFactory produces premultiplied pixels (RGB *= A)
 * but Media3's overlay shader multiplies by alpha again in GLSL.
 *
 * Uses copyPixelsToBuffer/copyPixelsFromBuffer for raw pixel access
 * (unlike getPixels/setPixels which auto-convert).
 * Keeps isPremultiplied=true so downstream Canvas calls don't crash.
 */
private fun unpremultiplyAlpha(bitmap: Bitmap): Bitmap {
    val w = bitmap.width
    val h = bitmap.height
    val out = if (bitmap.isMutable) bitmap
        else bitmap.copy(Bitmap.Config.ARGB_8888, true) ?: return bitmap

    val n = w * h * 4
    val buf = ByteBuffer.allocateDirect(n)
    out.copyPixelsToBuffer(buf)
    val px = ByteArray(n)
    buf.rewind(); buf.get(px)

    // ARGB_8888 raw byte order: R, G, B, A
    for (i in 0 until w * h) {
        val o = i * 4
        val a = px[o + 3].toInt() and 0xFF
        if (a in 1..254) {
            px[o]     = ((px[o].toInt()     and 0xFF) * 255 / a).toByte()
            px[o + 1] = ((px[o + 1].toInt() and 0xFF) * 255 / a).toByte()
            px[o + 2] = ((px[o + 2].toInt() and 0xFF) * 255 / a).toByte()
        }
    }

    buf.rewind(); buf.put(px); buf.rewind()
    out.copyPixelsFromBuffer(buf)
    return out
}