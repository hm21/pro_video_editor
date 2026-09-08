package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.graphics.Bitmap
import android.graphics.Matrix
import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.roundToInt
import androidx.core.graphics.scale
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TimestampWrapper
import ch.waio.pro_video_editor.src.features.render.models.ImageLayer
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.ImageOrientation

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
 * Rewrites layers that run "until the end" ([ImageLayerConfig.endUs] == -1)
 * **and** carry an `animateOut`/`animateInOut` animation so their end resolves
 * to [totalDurationUs], giving the out-phase a concrete point to animate toward.
 *
 * Without this, an open-ended layer's [AnimatedBitmapOverlay] treats its end as
 * `Long.MAX_VALUE`, so the out-phase never triggers and the layer pops off at
 * the last frame instead of animating out.
 *
 * Layers without an out-phase animation — and the whole list when
 * [totalDurationUs] is not positive — are returned unchanged, so every untouched
 * layer keeps its exact prior effect pipeline.
 */
internal fun resolveOpenEndedOutAnimations(
    layers: List<VideoSequenceBuilder.ImageLayerConfig>,
    totalDurationUs: Long,
): List<VideoSequenceBuilder.ImageLayerConfig> {
    if (totalDurationUs <= 0L) return layers
    return layers.map { layer ->
        val hasOutPhase = layer.endUs == -1L && layer.animations.any {
            it.phase == "animateOut" || it.phase == "animateInOut"
        }
        if (hasOutPhase) layer.copy(endUs = totalDurationUs) else layer
    }
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
    videoHeight: Int,
    outputWidth: Int? = null,
    outputHeight: Int? = null
) {
    if (imageLayers.isEmpty()) return

    val rasterScale = overlayRasterScale(
        videoWidth, videoHeight, outputWidth, outputHeight
    )

    Log.d(
        RENDER_TAG,
        "Applying ${imageLayers.size} time-based image layer(s) to ${videoWidth}x$videoHeight video"
    )
    for (layer in imageLayers) {
        try {
            val image = layer.image ?: continue
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
            //
            // Only the GIF path needs the whole encoded image in memory, so the
            // magic is sniffed off the first few bytes first — a file-backed
            // photo would otherwise be read in full just to learn it is a JPEG,
            // which is exactly the copy a path is meant to avoid.
            val gifFrames = image.readHeader(GifDecoder.MAGIC_LENGTH)
                ?.takeIf { GifDecoder.isGif(it) }
                ?.let { image.readBytes() }
                ?.let { GifDecoder.decode(it) }

            val bitmapOverlay: BitmapOverlay
            if (gifFrames != null) {
                // Prepare every frame identically so they share dimensions and
                // anchor; the overlay swaps frames over time.
                val prepared = gifFrames.map {
                    prepareOverlay(it.bitmap, layer, videoWidth, videoHeight, rasterScale)
                }
                val first = prepared.first()
                bitmapOverlay = AnimatedBitmapOverlay(
                    frames = prepared.map { it.bitmap },
                    frameDurationsUs = gifFrames.map { it.durationUs },
                    baseNormX = first.baseNormX,
                    baseNormY = first.baseNormY,
                    imageWidth = first.displayWidth,
                    imageHeight = first.displayHeight,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    layerStartUs = startTimeUs,
                    layerEndUs = endTimeUs,
                    loop = layer.loop,
                    animations = layer.animations,
                    rasterScale = first.rasterScale
                )
                Log.d(
                    RENDER_TAG,
                    "Layer: animated GIF with ${gifFrames.size} frame(s), loop=${layer.loop}"
                )
            } else {
                // Decoded through ImageOrientation so a gallery photo carrying an
                // EXIF orientation is laid in the way the user sees it, not as the
                // sideways pixels it is stored as.
                //
                // `prepareOverlay` scales the result down straight away, so it is
                // decoded no larger than it will end up: a full-resolution decode
                // of a phone photo costs a second full-resolution copy when the
                // orientation has to be turned, which is where an overlay OOMs.
                val (reqWidth, reqHeight) =
                    overlayDecodeSize(layer, videoWidth, videoHeight, rasterScale)
                val layerBitmap = ImageOrientation.decode(
                    image,
                    reqWidth = reqWidth,
                    reqHeight = reqHeight,
                    config = Bitmap.Config.ARGB_8888,
                )
                if (layerBitmap == null) {
                    Log.e(
                        RENDER_TAG,
                        "Layer: image did not decode (${image.describe()}); skipping layer"
                    )
                    continue
                }
                val prepared =
                    prepareOverlay(layerBitmap, layer, videoWidth, videoHeight, rasterScale)

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
                        imageWidth = prepared.displayWidth,
                        imageHeight = prepared.displayHeight,
                        videoWidth = videoWidth,
                        videoHeight = videoHeight,
                        layerStartUs = startTimeUs,
                        layerEndUs = endTimeUs,
                        animations = layer.animations,
                        rasterScale = prepared.rasterScale
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
    /**
     * Size the overlay occupies in the composition, in composition pixels.
     *
     * Equal to [bitmap]'s dimensions unless the raster was capped by
     * [overlayRasterScale], in which case the bitmap is smaller and
     * [overlaySettings] carries the compensating scale. Placement math must use
     * these rather than the bitmap's own size.
     */
    val displayWidth: Int,
    val displayHeight: Int,
    /** Reciprocal of the applied raster cap; `1f` when the raster was not capped. */
    val rasterScale: Float,
)

/**
 * How much of an overlay's requested resolution survives to the encoded frame.
 *
 * An overlay is laid out in the *composition's* pixel space, which is the source
 * clip's own resolution. When a custom output resolution is set, every clip is
 * scaled into it by a `Presentation` effect applied **after** the overlay — so
 * an overlay rastered above that ratio has its extra pixels thrown away by that
 * downscale before anything is encoded.
 *
 * Rastering it at the surviving size instead is therefore free of visible
 * detail, and it is the difference between a bitmap the heap can hold and one it
 * cannot: [unpremultiplyAlpha] needs a full-frame Java-heap buffer per layer
 * (`ByteBuffer.allocateDirect`, which reaches the Dalvik heap through
 * `newNonMovableArray`) counted against Android's 256 MiB per-app growth limit,
 * and every prepared overlay stays resident for the whole render — Media3 reads
 * it back out of `BitmapOverlay.getBitmap` on every frame, so none of them can
 * be released early. A 4K source exported at 1080p asked for four times the
 * pixels it could show, per layer.
 *
 * Returns `1f` — no capping — when no output resolution was requested, when the
 * output is not smaller than the composition, or when either is degenerate.
 */
internal fun overlayRasterScale(
    videoWidth: Int,
    videoHeight: Int,
    outputWidth: Int?,
    outputHeight: Int?,
): Float {
    if (outputWidth == null || outputHeight == null) return 1f
    if (videoWidth <= 0 || videoHeight <= 0) return 1f
    if (outputWidth <= 0 || outputHeight <= 0) return 1f

    // SCALE_TO_FIT preserves aspect ratio, so the frame shrinks by whichever
    // axis binds first.
    val scale = minOf(
        outputWidth.toFloat() / videoWidth,
        outputHeight.toFloat() / videoHeight,
    )
    return if (scale >= 1f) 1f else scale
}

/**
 * The size [prepareOverlay] will first scale a decoded layer down to, in
 * displayed pixels, or `0 × 0` when it keeps the image at its natural size.
 *
 * Mirrors [prepareOverlay]'s own branching, so decoding to this size cannot cost
 * resolution the overlay would otherwise have kept. A layer with an explicit
 * size is scaled to it; a layer with neither an explicit size nor a position is
 * stretched over the whole frame; a positioned layer without an explicit size is
 * laid out from its own pixel dimensions and so must not be sampled down.
 */
internal fun overlayDecodeSize(
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float = 1f,
): Pair<Int, Int> {
    val width = layer.width
    val height = layer.height
    if (width != null && height != null) {
        return capRaster(width.toInt(), height.toInt(), rasterScale)
    }
    if (layer.x == null && layer.y == null) {
        return capRaster(videoWidth, videoHeight, rasterScale)
    }
    return Pair(0, 0)
}

/**
 * [width] × [height] reduced by [rasterScale], never below one pixel per axis.
 *
 * A zero or negative input is passed through untouched — [overlayDecodeSize]
 * uses `0 × 0` to mean "keep the natural size".
 */
private fun capRaster(width: Int, height: Int, rasterScale: Float): Pair<Int, Int> {
    if (rasterScale >= 1f || width <= 0 || height <= 0) return Pair(width, height)
    return Pair(
        (width * rasterScale).roundToInt().coerceAtLeast(1),
        (height * rasterScale).roundToInt().coerceAtLeast(1),
    )
}

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
    rasterScale: Float = 1f,
): PreparedOverlay {
    // Determine if this layer should stretch or be positioned
    val isStretched = layer.x == null && layer.y == null
    val hasExplicitSize = layer.width != null && layer.height != null

    // Size the overlay occupies in the composition. The raster below may be
    // smaller (see [overlayRasterScale]); placement is laid out from these and
    // the shortfall is handed back to Media3 as an overlay scale.
    //
    // A positioned layer with no explicit size is laid out from its own pixel
    // dimensions, so [overlayDecodeSize] does not sample it down and the raster
    // is not capped here either — capping it would shrink the overlay.
    val displayWidth: Int
    val displayHeight: Int
    val cappable: Boolean
    when {
        isStretched -> {
            displayWidth = videoWidth
            displayHeight = videoHeight
            cappable = true
        }
        hasExplicitSize -> {
            displayWidth = layer.width!!.toInt()
            displayHeight = layer.height!!.toInt()
            cappable = true
        }
        else -> {
            displayWidth = rawBitmap.width
            displayHeight = rawBitmap.height
            cappable = false
        }
    }

    val (rasterWidth, rasterHeight) = if (cappable) {
        capRaster(displayWidth, displayHeight, rasterScale)
    } else {
        Pair(displayWidth, displayHeight)
    }
    // Media3 multiplies the overlay by this, so it must undo the cap exactly.
    val overlayScale = if (rasterWidth == displayWidth || rasterWidth <= 0) {
        1f
    } else {
        displayWidth.toFloat() / rasterWidth
    }

    // Scale straight to the raster size. A stretched layer goes to the frame
    // (capped) in one step rather than through its declared size first.
    val sizedBitmap = if (isStretched || hasExplicitSize) {
        val scaled = rawBitmap.scale(rasterWidth, rasterHeight)
        // scale() may return the same object when dimensions already match
        if (scaled !== rawBitmap) rawBitmap.recycle()
        scaled
    } else {
        rawBitmap
    }

    val unpremultiplied = unpremultiplyAlpha(sizedBitmap)
    if (unpremultiplied !== sizedBitmap) sizedBitmap.recycle()
    val finalOverlay: Bitmap = unpremultiplied

    val overlaySettings: StaticOverlaySettings
    var baseNormX = 0f
    var baseNormY = 0f

    if (isStretched) {
        overlaySettings = StaticOverlaySettings.Builder()
            .setOverlayFrameAnchor(0f, 0f)
            .setBackgroundFrameAnchor(0f, 0f)
            .setScale(overlayScale, overlayScale)
            .build()
    } else {
        val x = layer.x ?: 0
        val y = layer.y ?: 0

        // Use OverlaySettings for positioning
        // Media3 uses OpenGL coordinates: x[-1,1] left→right, y[-1,1] bottom→top.
        // Input uses top-left origin, so y must be flipped.
        //
        // Laid out from the display size: a capped raster is scaled back up by
        // [overlayScale] about its own centre, so that centre is what gets
        // anchored and it must not move with the cap.
        val centerX = x.toFloat() + displayWidth / 2f
        val centerY = y.toFloat() + displayHeight / 2f
        baseNormX = (centerX / videoWidth) * 2f - 1f
        baseNormY = 1f - (centerY / videoHeight) * 2f

        overlaySettings = StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(baseNormX, baseNormY)
            .setOverlayFrameAnchor(0f, 0f)
            .setScale(overlayScale, overlayScale)
            .build()
    }

    // Rotate the overlay around its center. baseNormX/baseNormY describe the
    // (unrotated) layout center; rotating about the bitmap center keeps that
    // point fixed, so the anchor stays correct while the bounding box grows
    // symmetrically.
    val rotatedOverlay = rotateBitmap(
        finalOverlay, Math.toDegrees(layer.rotation).toFloat()
    )

    // Rotation grows the bounding box. The display size grows with it, per
    // axis, so a caller laying out from [PreparedOverlay.displayWidth] sees the
    // rotated extent rather than the unrotated one.
    val grownWidth = (rotatedOverlay.width * overlayScale).roundToInt()
    val grownHeight = (rotatedOverlay.height * overlayScale).roundToInt()

    return PreparedOverlay(
        bitmap = rotatedOverlay,
        baseNormX = baseNormX,
        baseNormY = baseNormY,
        overlaySettings = overlaySettings,
        displayWidth = grownWidth,
        displayHeight = grownHeight,
        rasterScale = overlayScale,
    )
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

    unpremultiplyInPlace(buf, n)

    buf.rewind()
    out.copyPixelsFromBuffer(buf)
    return out
}

/**
 * Divides the first [byteCount] bytes of [buf] out by their own alpha, in place.
 *
 * Mutating the buffer through absolute get/put, rather than reading it out into
 * a `ByteArray` first, is what keeps the peak at one full-frame buffer instead
 * of two. Both are Java-heap allocations counted against Android's per-app
 * growth limit — `ByteBuffer.allocateDirect` reaches it through
 * `newNonMovableArray` — and a full-frame overlay makes each of them tens of
 * megabytes, once per layer.
 *
 * Pixels are ARGB_8888 in raw byte order: R, G, B, A. A fully transparent or
 * fully opaque pixel is left alone: there is nothing to divide out of an opaque
 * one, and `a == 0` carries no colour to recover and would divide by zero.
 */
internal fun unpremultiplyInPlace(buf: ByteBuffer, byteCount: Int) {
    var o = 0
    while (o + 3 < byteCount) {
        val a = buf.get(o + 3).toInt() and 0xFF
        if (a in 1..254) {
            buf.put(o, (((buf.get(o).toInt() and 0xFF) * 255) / a).toByte())
            buf.put(o + 1, (((buf.get(o + 1).toInt() and 0xFF) * 255) / a).toByte())
            buf.put(o + 2, (((buf.get(o + 2).toInt() and 0xFF) * 255) / a).toByte())
        }
        o += 4
    }
}
