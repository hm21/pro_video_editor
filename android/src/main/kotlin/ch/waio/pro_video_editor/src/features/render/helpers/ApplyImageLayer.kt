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
 * @param imageBytes PNG/JPEG image as byte array
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
    imageBytes: ByteArray?,
    rotationDegrees: Float,
    cropWidth: Int?,
    cropHeight: Int?,
    scaleX: Float?,
    scaleY: Float?,
) {
    if (imageBytes == null) return

    var (videoWidth, videoHeight, videoRotation) = getRotatedVideoDimensions(
        inputFile,
        rotationDegrees
    )

    val isRotated90Deg = videoRotation == 90 || videoRotation == 270
    if (cropWidth != null) {
        if (isRotated90Deg) {
            videoHeight = cropWidth
        } else {
            videoWidth = cropWidth
        }
    }
    if (cropHeight != null) {
        if (isRotated90Deg) {
            videoWidth = cropHeight
        } else {
            videoHeight = cropHeight
        }
    }

    if (scaleX != null) videoWidth = (videoWidth * scaleX).toInt()
    if (scaleY != null) videoHeight = (videoHeight * scaleY).toInt()

    Log.d(
        RENDER_TAG,
        "Applying image overlay: ${imageBytes.size / 1024} KB, scaled to ${videoWidth}x$videoHeight"
    )

    // Decode as premultiplied (default) so Canvas-based scaling works
    val options = BitmapFactory.Options().apply {
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }
    val overlayBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, options)

    // Use createScaledBitmap for cleaner scaling that preserves alpha correctly
    val scaledOverlay = if (overlayBitmap.width != videoWidth || overlayBitmap.height != videoHeight) {
        val scaled = overlayBitmap.scale(videoWidth, videoHeight)
        overlayBitmap.recycle()
        scaled
    } else {
        overlayBitmap
    }

    // Media3's overlay GLSL shader uses straight-alpha blending:
    //   output.rgb = overlay.rgb * overlay.a + video.rgb * (1 - overlay.a)
    // But Android's BitmapFactory produces premultiplied alpha (RGB already
    // multiplied by A). This causes double alpha multiplication and darkens
    // semi-transparent areas.
    // Fix: manually convert pixels from premultiplied to straight alpha.
    // We keep isPremultiplied=true on the Bitmap so Canvas/Media3 don't
    // complain - only the actual pixel data is converted to straight alpha.
    val finalOverlay = unpremultiplyAlpha(scaledOverlay)
    if (finalOverlay !== scaledOverlay) scaledOverlay.recycle()

    // Create static bitmap overlay
    // Color issues are fixed by using WORKING_COLOR_SPACE_ORIGINAL in RenderVideo.kt
    val bitmapOverlay = BitmapOverlay.createStaticBitmapOverlay(finalOverlay)
    val overlayEffect = OverlayEffect(listOf(bitmapOverlay))

    videoEffects += overlayEffect
}

/**
 * Applies time-based image overlays on video.
 *
 * Each image layer has a start and end time, and will only be visible during that time range.
 * Multiple layers can be active simultaneously.
 * Images are positioned at the specified x/y offset from the bottom-left of the video frame.
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

            val imageWidth = layerBitmap.width
            val imageHeight = layerBitmap.height

            // Convert from premultiplied to straight alpha
            val finalOverlay = unpremultiplyAlpha(layerBitmap)
            if (finalOverlay !== layerBitmap) layerBitmap.recycle()

            // Convert times from microseconds to seconds
            val startTimeUs = layer.startUs
            val endTimeUs = layer.endUs

            Log.d(
                RENDER_TAG,
                "Layer: ${if (startTimeUs == -1L) "from start" else "start=${startTimeUs}us"}," +
                        " ${if (endTimeUs == -1L) "until end" else "end=${endTimeUs}us"}," +
                        " size=${imageWidth}x${imageHeight}, offset=(${layer.x}, ${layer.y})"
            )

            // Use OverlaySettings for positioning instead of allocating a
            // full-frame (videoWidth×videoHeight) canvas bitmap per layer.
            // Media3 uses OpenGL coordinates: x[-1,1] left→right, y[-1,1] bottom→top.
            // Input uses top-left origin, so y must be flipped.
            val centerX = layer.x.toFloat() + imageWidth / 2f
            val centerY = layer.y.toFloat() + imageHeight / 2f
            val normX = (centerX / videoWidth) * 2f - 1f
            val normY = 1f - (centerY / videoHeight) * 2f

            val overlaySettings = StaticOverlaySettings.Builder()
                .setBackgroundFrameAnchor(normX, normY)
                .setOverlayFrameAnchor(0f, 0f)
                .build()

            val bitmapOverlay = BitmapOverlay.createStaticBitmapOverlay(
                finalOverlay, overlaySettings
            )

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