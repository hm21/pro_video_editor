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

    var isRotated90Deg = videoRotation == 90 || videoRotation == 270;
    if (cropWidth != null) {
        if (isRotated90Deg) {
            videoHeight = cropWidth;
        } else {
            videoWidth = cropWidth;
        }
    }
    if (cropHeight != null) {
        if (isRotated90Deg) {
            videoWidth = cropHeight;
        } else {
            videoHeight = cropHeight;
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
        val scaled = Bitmap.createScaledBitmap(overlayBitmap, videoWidth, videoHeight, true)
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