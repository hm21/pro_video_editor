package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import java.io.File
import java.nio.ByteBuffer
import androidx.core.graphics.scale
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TimestampWrapper
import ch.waio.pro_video_editor.src.features.render.models.ImageLayer
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

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
    imageLayers: List<ImageLayer>,
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
            val startTimeUs = layer.startUs
            val endTimeUs = layer.endUs
            val hasAnimations = layer.animations.isNotEmpty()

            Log.d(
                RENDER_TAG,
                "Layer timing: ${if (startTimeUs == -1L) "from start" else "start=${startTimeUs}us"}," +
                        " ${if (endTimeUs == -1L) "until end" else "end=${endTimeUs}us"}"
            )

            // Animated GIFs decode to several frames; everything else (PNG/JPEG
            // and static GIFs) decodes to a single bitmap.
            val gifFrames = GifDecoder.decode(imageBytes)

            val bitmapOverlay: BitmapOverlay
            if (gifFrames != null) {
                // Prepare every frame identically so they share dimensions and
                // anchor; the overlay swaps frames over time.
                val prepared = gifFrames.map {
                    prepareOverlay(it.bitmap, layer, videoWidth, videoHeight)
                }
                val first = prepared.first()
                bitmapOverlay = AnimatedBitmapOverlay(
                    frames = prepared.map { it.bitmap },
                    frameDurationsUs = gifFrames.map { it.durationUs },
                    baseNormX = first.baseNormX,
                    baseNormY = first.baseNormY,
                    imageWidth = first.bitmap.width,
                    imageHeight = first.bitmap.height,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    layerStartUs = startTimeUs,
                    layerEndUs = endTimeUs,
                    loop = layer.loop,
                    animations = layer.animations
                )
                Log.d(
                    RENDER_TAG,
                    "Layer: animated GIF with ${gifFrames.size} frame(s), loop=${layer.loop}"
                )
            } else {
                val options = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                val layerBitmap = BitmapFactory.decodeByteArray(
                    imageBytes, 0, imageBytes.size, options
                )
                val prepared = prepareOverlay(layerBitmap, layer, videoWidth, videoHeight)

                bitmapOverlay = if (hasAnimations) {
                    Log.d(
                        RENDER_TAG,
                        "Layer: using AnimatedBitmapOverlay with " +
                                "${layer.animations.size} animation(s)"
                    )
                    AnimatedBitmapOverlay(
                        bitmap = prepared.bitmap,
                        baseNormX = prepared.baseNormX,
                        baseNormY = prepared.baseNormY,
                        imageWidth = prepared.bitmap.width,
                        imageHeight = prepared.bitmap.height,
                        videoWidth = videoWidth,
                        videoHeight = videoHeight,
                        layerStartUs = startTimeUs,
                        layerEndUs = endTimeUs,
                        animations = layer.animations
                    )
                } else {
                    BitmapOverlay.createStaticBitmapOverlay(
                        prepared.bitmap, prepared.overlaySettings
                    )
                }
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

/** A fully prepared overlay bitmap together with its placement settings. */
private data class PreparedOverlay(
    val bitmap: Bitmap,
    val baseNormX: Float,
    val baseNormY: Float,
    val overlaySettings: StaticOverlaySettings,
)

/**
 * Scales, positions, unpremultiplies and rotates a single overlay [rawBitmap]
 * according to [layer], returning the final bitmap plus its anchor/settings.
 *
 * Intermediate bitmaps are recycled; the returned bitmap takes ownership of
 * [rawBitmap]'s pixels. Used for both static images and each GIF frame, so all
 * frames of one layer come out with identical dimensions and anchor.
 */
@UnstableApi
private fun prepareOverlay(
    rawBitmap: Bitmap,
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
): PreparedOverlay {
    // Scale to target size if provided
    val sizedBitmap = if (layer.width != null && layer.height != null) {
        val scaled = rawBitmap.scale(layer.width.toInt(), layer.height.toInt())
        // scale() may return the same object when dimensions already match
        if (scaled !== rawBitmap) rawBitmap.recycle()
        scaled
    } else {
        rawBitmap
    }

    // Determine if this layer should stretch or be positioned
    val isStretched = layer.x == null && layer.y == null

    val finalOverlay: Bitmap
    val overlaySettings: StaticOverlaySettings
    var baseNormX = 0f
    var baseNormY = 0f

    if (isStretched) {
        // Stretch image to fill the entire video frame
        val scaledOverlay = sizedBitmap.scale(videoWidth, videoHeight)
        if (scaledOverlay !== sizedBitmap) sizedBitmap.recycle()

        val unpremultiplied = unpremultiplyAlpha(scaledOverlay)
        if (unpremultiplied !== scaledOverlay) scaledOverlay.recycle()
        finalOverlay = unpremultiplied

        overlaySettings = StaticOverlaySettings.Builder()
            .setOverlayFrameAnchor(0f, 0f)
            .setBackgroundFrameAnchor(0f, 0f)
            .build()
    } else {
        // Position image at specified x/y offset
        val imageWidth = sizedBitmap.width
        val imageHeight = sizedBitmap.height

        val unpremultiplied = unpremultiplyAlpha(sizedBitmap)
        if (unpremultiplied !== sizedBitmap) sizedBitmap.recycle()
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
    }

    // Rotate the overlay around its center. baseNormX/baseNormY describe the
    // (unrotated) layout center; rotating about the bitmap center keeps that
    // point fixed, so the anchor stays correct while the bounding box grows
    // symmetrically.
    val rotatedOverlay = rotateBitmap(
        finalOverlay, Math.toDegrees(layer.rotation).toFloat()
    )

    return PreparedOverlay(rotatedOverlay, baseNormX, baseNormY, overlaySettings)
}

/**
 * Rotates [bitmap] clockwise by [degrees] around its center.
 *
 * Returns a new bitmap sized to the rotated bounding box; the source center
 * maps to the new center, so a center-anchored overlay keeps its position.
 * The source bitmap is recycled when a new one is produced. A rotation that is
 * a multiple of 360° (including `0`) returns the input unchanged.
 *
 * The input is expected to carry straight (un-premultiplied) alpha so the
 * bilinear edge pixels introduced by the rotation interpolate correctly.
 */
private fun rotateBitmap(bitmap: Bitmap, degrees: Float): Bitmap {
    if (degrees % 360f == 0f) return bitmap
    val matrix = Matrix().apply { postRotate(degrees) }
    val rotated = Bitmap.createBitmap(
        bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
    )
    if (rotated !== bitmap) bitmap.recycle()
    return rotated
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