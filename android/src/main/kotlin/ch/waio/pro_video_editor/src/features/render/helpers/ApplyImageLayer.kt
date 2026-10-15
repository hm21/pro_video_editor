package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import androidx.media3.common.Effect
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.GlEffect
import androidx.media3.effect.OverlayEffect
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import androidx.core.graphics.scale
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextureOverlay
import androidx.media3.effect.TimestampWrapper
import ch.waio.pro_video_editor.src.features.render.models.ImageLayer
import ch.waio.pro_video_editor.src.features.render.models.LayerAudioVisualizerConfig
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
 * Memory does not grow with every layer: static layers in a row that share a
 * time range are drawn into one image (see [flattenStaticLayers]), and the
 * overlays in a row that share a time range are drawn by one effect (see
 * [OverlayBatch]).
 *
 * @param videoEffects List to add overlay effects to
 * @param imageLayers List of image layers with timing information
 * @param videoWidth Width of the video frame for positioning
 * @param videoHeight Height of the video frame for positioning
 * @param frameWidth Width of the frame that actually reaches the output, when a
 *   crop applied after these overlays shrinks it below [videoWidth]. Only the
 *   raster ceiling reads it; positioning stays in [videoWidth] x [videoHeight].
 * @param frameHeight Height counterpart of [frameWidth]
 */
@UnstableApi
fun applyTimedImageLayers(
    videoEffects: MutableList<Effect>,
    imageLayers: List<VideoSequenceBuilder.ImageLayerConfig>,
    videoWidth: Int,
    videoHeight: Int,
    outputWidth: Int? = null,
    outputHeight: Int? = null,
    frameWidth: Int = videoWidth,
    frameHeight: Int = videoHeight
) {
    if (imageLayers.isEmpty()) return

    val rasterScale = overlayRasterScale(
        frameWidth, frameHeight, outputWidth, outputHeight
    )
    // Budgeted against the composition the layers are laid out in, not the
    // [frameWidth] x [frameHeight] slice a crop keeps of it: a stretched
    // drawing stroke covers the whole composition, and holding it to four
    // crop rectangles would raster it below what the crop still shows.
    val rasterBudget = overlayRasterBudget(videoWidth, videoHeight, rasterScale)

    Log.d(
        RENDER_TAG,
        "Applying ${imageLayers.size} time-based image layer(s) to ${videoWidth}x$videoHeight video" +
                " (raster scale $rasterScale, raster budget $rasterBudget px)"
    )
    val overlays = OverlayBatch(videoEffects)
    var index = 0
    while (index < imageLayers.size) {
        val run = staticLayerRunLength(imageLayers, index)
        if (run > 1) {
            val layers = imageLayers.subList(index, index + run)
            Log.d(
                RENDER_TAG,
                "Layers ${index + 1}-${index + run}: drawing $run static layers as one image"
            )
            flattenStaticLayers(layers, videoWidth, videoHeight, rasterScale, rasterBudget)
                ?.let { overlays.add(it, layers.first().startUs, layers.first().endUs) }
            index += run
        } else {
            addImageLayer(
                imageLayers[index], overlays, videoEffects,
                videoWidth, videoHeight, rasterScale, rasterBudget
            )
            index++
        }
    }
    overlays.flush()
}

/**
 * Adds the overlay of [layer] to [overlays], or the effect of a censor layer to
 * [videoEffects] after the overlays below it.
 */
@UnstableApi
private fun addImageLayer(
    layer: VideoSequenceBuilder.ImageLayerConfig,
    overlays: OverlayBatch,
    videoEffects: MutableList<Effect>,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float,
    rasterBudget: Long,
) {
    try {
        val startTimeUs = layer.startUs
        val endTimeUs = layer.endUs
        // Keyframes move the layer as animations do, frame by frame.
        val isAnimated = layer.animations.isNotEmpty() || layer.keyframes.isNotEmpty()

        Log.d(
            RENDER_TAG,
            "Layer timing: ${if (startTimeUs == -1L) "from start" else "start=${startTimeUs}us"}," +
                    " ${if (endTimeUs == -1L) "until end" else "end=${endTimeUs}us"}"
        )

        // An audio visualizer draws itself into the layer's box on every
        // frame and never reads the layer's image.
        val visualizer = layer.audioVisualizer
        if (visualizer != null) {
            val overlay = prepareAudioVisualizerOverlay(
                layer, visualizer, videoWidth, videoHeight, rasterScale, rasterBudget
            )
            if (overlay == null) {
                Log.e(
                    RENDER_TAG,
                    "Layer: audio visualizer without a size to fill; skipping layer"
                )
                return
            }
            Log.d(
                RENDER_TAG,
                "Layer: audio visualizer (${visualizer.style}, " +
                        "${visualizer.bandCount} bands, ${visualizer.frameCount} rows)"
            )
            overlays.add(overlay, startTimeUs, endTimeUs)
            return
        }
        val image = layer.image ?: return

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
                prepareOverlay(
                    it.bitmap, layer, videoWidth, videoHeight, rasterScale, rasterBudget
                )
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
                layerX = (layer.x ?: 0).toFloat(),
                layerY = (layer.y ?: 0).toFloat(),
                layerStartUs = startTimeUs,
                layerEndUs = endTimeUs,
                loop = layer.loop,
                animationOffsetUs = layer.animationOffsetUs,
                animationStartUs = layer.animationStartUs,
                animationEndUs = layer.animationEndUs,
                animations = layer.animations,
                rasterScaleX = first.rasterScaleX,
                rasterScaleY = first.rasterScaleY,
                keyframes = layer.keyframes,
                keyframeClock = layer.keyframeClock
            )
            Log.d(
                RENDER_TAG,
                "Layer: animated GIF with ${gifFrames.size} frame(s), loop=${layer.loop}, " +
                        "animationOffset=${layer.animationOffsetUs}us"
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
            val (reqWidth, reqHeight) = overlayDecodeSize(
                layer, videoWidth, videoHeight, rasterScale, rasterBudget
            )
            val layerBitmap = ImageOrientation.decode(
                image,
                reqWidth = reqWidth,
                reqHeight = reqHeight,
                config = Bitmap.Config.ARGB_8888,
            )
            if (layerBitmap == null) {
                if (layer.censor != null) {
                    throw CensorLayerException(
                        "the mask image did not decode (${image.describe()})"
                    )
                }
                Log.e(
                    RENDER_TAG,
                    "Layer: image did not decode (${image.describe()}); skipping layer"
                )
                return
            }
            val prepared = prepareOverlay(
                layerBitmap, layer, videoWidth, videoHeight, rasterScale, rasterBudget
            )

            bitmapOverlay = if (isAnimated) {
                Log.d(
                    RENDER_TAG,
                    "Layer: using AnimatedBitmapOverlay with " +
                            "${layer.animations.size} animation(s) and " +
                            "${layer.keyframes.size} keyframe(s)"
                )
                AnimatedBitmapOverlay(
                    bitmap = prepared.bitmap,
                    baseNormX = prepared.baseNormX,
                    baseNormY = prepared.baseNormY,
                    imageWidth = prepared.displayWidth,
                    imageHeight = prepared.displayHeight,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    layerX = (layer.x ?: 0).toFloat(),
                    layerY = (layer.y ?: 0).toFloat(),
                    layerStartUs = startTimeUs,
                    layerEndUs = endTimeUs,
                    animations = layer.animations,
                    rasterScaleX = prepared.rasterScaleX,
                    rasterScaleY = prepared.rasterScaleY,
                    animationStartUs = layer.animationStartUs,
                    animationEndUs = layer.animationEndUs,
                    keyframes = layer.keyframes,
                    keyframeClock = layer.keyframeClock
                )
            } else {
                BitmapOverlay.createStaticBitmapOverlay(
                    prepared.bitmap, prepared.overlaySettings
                )
            }
        }

        // A censor layer hides the frame composed so far where the overlay
        // would have been drawn, instead of drawing it.
        val censor = layer.censor
        if (censor == null) {
            overlays.add(bitmapOverlay, startTimeUs, endTimeUs)
            return
        }
        Log.d(RENDER_TAG, "Layer: censor (${censor.type}, strength ${censor.strength})")
        if (isEmptyTimeRange(startTimeUs, endTimeUs)) {
            // An empty window hides nothing; TimestampWrapper would
            // reject it, which a censor layer turns into a failure.
            Log.d(RENDER_TAG, "Layer: censor with an empty time range; skipping layer")
            return
        }
        // It hides what the layers below it drew, so those are added first.
        overlays.flush()
        addTimedOverlayEffect(
            videoEffects, LayerCensorEffect(bitmapOverlay, censor), startTimeUs, endTimeUs
        )

    } catch (e: OutOfMemoryError) {
        // An Error, so no catch above sees it: it would unwind the
        // composition thread and take the whole process down. Fail the
        // render instead — the caller reports it and the user can retry.
        // Not skipped like a decode failure below: a video quietly missing
        // its sticker is worse than one that did not export.
        throw OverlayOutOfMemoryException(layer, videoWidth, videoHeight, e)
    } catch (e: Exception) {
        // A censor layer hides what the creator does not want shown, such
        // as a face or a license plate. Exporting without it would publish
        // exactly that, so its failure fails the render instead.
        if (layer.censor != null) {
            throw e as? CensorLayerException ?: CensorLayerException(
                e.message ?: e.javaClass.simpleName, e
            )
        }
        Log.e(RENDER_TAG, "Failed to decode image layer: ${e.message}")
    }
}

/**
 * Adds [effect] to [videoEffects], shown from [startTimeUs] to [endTimeUs]
 * (`-1` = from the start, until the end).
 */
@UnstableApi
private fun addTimedOverlayEffect(
    videoEffects: MutableList<Effect>,
    effect: GlEffect,
    startTimeUs: Long,
    endTimeUs: Long,
) {
    if (startTimeUs == -1L && endTimeUs == -1L) {
        // No time range set — show for the entire video
        videoEffects += effect
        return
    }
    val effectiveStart = if (startTimeUs == -1L) 0L else startTimeUs
    val effectiveEnd = if (endTimeUs == -1L) Long.MAX_VALUE else endTimeUs
    videoEffects += TimestampWrapper(effect, effectiveStart, effectiveEnd)
}

/**
 * Whether a layer shown from [startTimeUs] to [endTimeUs] (`-1` = from the
 * start, until the end) is never shown, which `TimestampWrapper` rejects.
 */
internal fun isEmptyTimeRange(startTimeUs: Long, endTimeUs: Long): Boolean {
    if (startTimeUs < -1L) return true
    if (endTimeUs == -1L) return false
    return endTimeUs <= (if (startTimeUs == -1L) 0L else startTimeUs)
}

/**
 * Most overlays one [OverlayEffect] can draw: Media3's `OverlayShaderProgram`
 * samples every overlay in one pass and takes at most 15 of them.
 */
internal const val MAX_OVERLAYS_PER_EFFECT = 15

/**
 * Collects consecutive overlays shown over the same time range and adds them to
 * [videoEffects] as one [OverlayEffect], up to [MAX_OVERLAYS_PER_EFFECT] each.
 *
 * Media3 gives every effect its own shader program and an output texture of the
 * whole frame, and a [TimestampWrapper] adds a second one for the frames outside
 * its range. One effect per layer therefore held up to two frames of graphics
 * memory per layer for the whole render. An [OverlayEffect] draws its overlays
 * in order, the last one on top, as separate effects would.
 */
@UnstableApi
internal class OverlayBatch(private val videoEffects: MutableList<Effect>) {
    private val overlays = mutableListOf<TextureOverlay>()
    private var startTimeUs = -1L
    private var endTimeUs = -1L

    /** Adds [overlay], shown from [startTimeUs] to [endTimeUs]. */
    fun add(overlay: TextureOverlay, startTimeUs: Long, endTimeUs: Long) {
        if (isEmptyTimeRange(startTimeUs, endTimeUs)) {
            Log.d(RENDER_TAG, "Layer: empty time range; skipping layer")
            return
        }
        if (overlays.isNotEmpty() &&
            (startTimeUs != this.startTimeUs || endTimeUs != this.endTimeUs ||
                    overlays.size == MAX_OVERLAYS_PER_EFFECT)
        ) {
            flush()
        }
        this.startTimeUs = startTimeUs
        this.endTimeUs = endTimeUs
        overlays += overlay
    }

    /** Adds the overlays collected so far as one effect. */
    fun flush() {
        if (overlays.isEmpty()) return
        addTimedOverlayEffect(
            videoEffects, OverlayEffect(overlays.toList()), startTimeUs, endTimeUs
        )
        overlays.clear()
    }
}

/**
 * Whether [layer] is a still image that looks the same on every frame it shows:
 * no animation, keyframe, censor or audio visualizer, and not a GIF, which may
 * animate.
 */
internal fun isStaticImageLayer(layer: VideoSequenceBuilder.ImageLayerConfig): Boolean {
    val image = layer.image ?: return false
    if (layer.audioVisualizer != null || layer.censor != null) return false
    if (layer.animations.isNotEmpty() || layer.keyframes.isNotEmpty()) return false
    val header = image.readHeader(GifDecoder.MAGIC_LENGTH) ?: return false
    return !GifDecoder.isGif(header)
}

/**
 * How many layers from [start] on [flattenStaticLayers] draws as one image: the
 * static layers (see [isStaticImageLayer]) in a row that share the time range of
 * the one at [start]. `0` when that one is not static.
 */
internal fun staticLayerRunLength(
    layers: List<VideoSequenceBuilder.ImageLayerConfig>,
    start: Int,
): Int {
    val first = layers[start]
    if (!isStaticImageLayer(first)) return 0
    var end = start + 1
    while (end < layers.size) {
        val next = layers[end]
        if (next.startUs != first.startUs || next.endUs != first.endUs) break
        if (!isStaticImageLayer(next)) break
        end++
    }
    return end - start
}

/**
 * Draws [layers], static layers sharing one time range, into one bitmap of the
 * frame and returns it as one overlay, or `null` when none of them decoded.
 *
 * Every overlay keeps its bitmap for the whole render, so 200 stickers kept 200
 * rasters of up to the frame's size each; drawn into one, they keep one. Each
 * layer is drawn where its own overlay would have been, over the ones before
 * it, which blends them as Media3 would have in turn. One layer is decoded at a
 * time and released once it is drawn.
 */
@UnstableApi
private fun flattenStaticLayers(
    layers: List<VideoSequenceBuilder.ImageLayerConfig>,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float,
    rasterBudget: Long,
): BitmapOverlay? {
    // The image is one layer stretched over the frame, rastered, capped and
    // placed like any other.
    val frame = layers.first().copy(
        x = null, y = null, width = null, height = null,
        rotation = 0.0, naturalSizeScale = 1.0
    )
    val (rasterWidth, rasterHeight) = overlayDecodeSize(
        frame, videoWidth, videoHeight, rasterScale, rasterBudget
    )
    try {
        val target = Bitmap.createBitmap(rasterWidth, rasterHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(target)
        canvas.scale(
            rasterWidth.toFloat() / videoWidth, rasterHeight.toFloat() / videoHeight
        )
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        var drawn = 0
        for (layer in layers) {
            try {
                if (drawStaticLayer(
                        canvas, paint, layer, videoWidth, videoHeight, rasterScale, rasterBudget
                    )
                ) {
                    drawn++
                }
            } catch (e: OutOfMemoryError) {
                throw OverlayOutOfMemoryException(layer, videoWidth, videoHeight, e)
            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Failed to decode image layer: ${e.message}")
            }
        }
        if (drawn == 0) {
            target.recycle()
            return null
        }
        unpremultiplyAlpha(target)
        val raster = planOverlayRaster(
            rasterWidth, rasterHeight, frame, videoWidth, videoHeight, rasterScale, rasterBudget
        )
        val prepared = placeOverlay(target, raster, frame, videoWidth, videoHeight)
        return BitmapOverlay.createStaticBitmapOverlay(prepared.bitmap, prepared.overlaySettings)
    } catch (e: OutOfMemoryError) {
        throw OverlayOutOfMemoryException(frame, videoWidth, videoHeight, e)
    } catch (e: OverlayOutOfMemoryException) {
        throw e
    } catch (e: Exception) {
        // Skipped as a layer that fails on its own is.
        Log.e(RENDER_TAG, "Failed to draw ${layers.size} static layers: ${e.message}")
        return null
    }
}

/**
 * Draws [layer] onto [canvas], which is laid out in frame pixels, where its own
 * overlay would have been: in its box, turned about the box's centre. Returns
 * whether its image decoded.
 */
private fun drawStaticLayer(
    canvas: Canvas,
    paint: Paint,
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float,
    rasterBudget: Long,
): Boolean {
    val image = layer.image ?: return false
    val (reqWidth, reqHeight) = overlayDecodeSize(
        layer, videoWidth, videoHeight, rasterScale, rasterBudget
    )
    val bitmap = ImageOrientation.decode(
        image,
        reqWidth = reqWidth,
        reqHeight = reqHeight,
        config = Bitmap.Config.ARGB_8888,
    )?.let(::withSrgbValues)
    if (bitmap == null) {
        Log.e(RENDER_TAG, "Layer: image did not decode (${image.describe()}); skipping layer")
        return false
    }
    try {
        val raster = planOverlayRaster(
            bitmap.width, bitmap.height, layer, videoWidth, videoHeight,
            rasterScale, rasterBudget
        )
        val width = raster.displayWidth.toFloat()
        val height = raster.displayHeight.toFloat()
        val left = if (raster.isStretched) 0f else (layer.x ?: 0).toFloat()
        val top = if (raster.isStretched) 0f else (layer.y ?: 0).toFloat()
        val matrix = Matrix().apply {
            setScale(width / bitmap.width, height / bitmap.height)
            postTranslate(-width / 2f, -height / 2f)
            postRotate(Math.toDegrees(layer.rotation).toFloat())
            postTranslate(left + width / 2f, top + height / 2f)
        }
        canvas.drawBitmap(bitmap, matrix, paint)
    } finally {
        bitmap.recycle()
    }
    return true
}

/**
 * [bitmap] with the values it holds read as sRGB, as Media3 reads an overlay of
 * its own: it uploads the pixels as they are, whatever colour space they were
 * decoded in. A [Canvas] converts them into its target's instead, so a photo
 * decoded as Display P3 would come out in other colours drawn with other layers
 * than drawn on its own. Recycles [bitmap] when it returns a copy.
 */
private fun withSrgbValues(bitmap: Bitmap): Bitmap {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return bitmap
    val srgb = ColorSpace.get(ColorSpace.Named.SRGB)
    val colorSpace = bitmap.colorSpace
    if (colorSpace == null || colorSpace == srgb) return bitmap
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        try {
            bitmap.setColorSpace(srgb)
            return bitmap
        } catch (e: IllegalArgumentException) {
            // A colour space of a wider range than sRGB's; copied below.
        }
    }
    if (bitmap.config != Bitmap.Config.ARGB_8888) return bitmap
    val copy = Bitmap.createBitmap(
        bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888, bitmap.hasAlpha(), srgb
    )
    val pixels = ByteBuffer.allocateDirect(bitmap.byteCount)
    bitmap.copyPixelsToBuffer(pixels)
    pixels.rewind()
    copy.copyPixelsFromBuffer(pixels)
    bitmap.recycle()
    return copy
}

/**
 * A censor layer could not be set up. The render fails rather than export the
 * area the layer was meant to hide.
 */
internal class CensorLayerException(
    message: String,
    cause: Throwable? = null,
) : RuntimeException("Censor layer: $message", cause)

/**
 * An overlay could not be rastered because the Java heap could not hold it.
 *
 * Raised in place of the `OutOfMemoryError` so the render fails through the
 * ordinary error path rather than killing the process. [overlayRasterBudget]
 * keeps a sized layer well inside the heap, so reaching this means an
 * unbounded raster — a naturally sized layer decoded at its own resolution, or
 * a heap already full of something else.
 */
internal class OverlayOutOfMemoryException(
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
    cause: OutOfMemoryError,
) : RuntimeException(
    "Out of memory rastering an overlay laid out at " +
        "${layoutSize(layer, videoWidth, videoHeight)}: ${cause.message ?: "no message"}",
    cause,
) {
    private companion object {
        /**
         * The size the layer occupies, as [prepareOverlay] lays it out: its
         * explicit size, else the frame for a stretched layer, else its own
         * pixels, which are not known until it is decoded.
         */
        fun layoutSize(
            layer: VideoSequenceBuilder.ImageLayerConfig,
            videoWidth: Int,
            videoHeight: Int,
        ): String {
            val width = layer.width
            val height = layer.height
            return when {
                width != null && height != null -> "${width.toInt()} x ${height.toInt()} px"
                layer.x == null && layer.y == null -> "$videoWidth x $videoHeight px (frame)"
                else -> "its natural size"
            }
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
     * [overlayRasterScale] or held under [overlayRasterBudget], in which case
     * the bitmap is smaller and [overlaySettings] carries the compensating
     * scale. Placement math must use these rather than the bitmap's own size.
     */
    val displayWidth: Int,
    val displayHeight: Int,
    /**
     * Reciprocal of the applied raster cap, per axis; `1f` when uncapped.
     *
     * Per axis rather than shared, because [capRaster] rounds each axis to a
     * whole pixel independently — a thin layer rounds far more coarsely on its
     * short axis, and one shared factor would then render it out of shape.
     */
    val rasterScaleX: Float,
    val rasterScaleY: Float,
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
    rasterBudget: Long = Long.MAX_VALUE,
): Pair<Int, Int> {
    val width = layer.width
    val height = layer.height
    if (width != null && height != null) {
        val growth = keyframeRasterGrowth(layer)
        return capRaster(
            (width * growth).roundToInt(), (height * growth).roundToInt(),
            rasterScale, rasterBudget
        )
    }
    if (layer.x == null && layer.y == null) {
        return capRaster(videoWidth, videoHeight, rasterScale, rasterBudget)
    }
    return Pair(0, 0)
}

/**
 * Pixels one overlay raster may hold at most, on a frame of the given size.
 *
 * [overlayRasterScale] bounds an overlay by the *ratio* the frame is scaled by.
 * That is exact for a layer no larger than the frame — it removes only pixels
 * the downscale would discard — and says nothing about a layer larger than the
 * frame itself. A sticker or a title scaled far past the canvas is laid out at
 * that size, five or ten times the frame on each axis is a pinch away, and only
 * the slice inside the frame is ever visible; the whole of it was rastered
 * regardless. An 11 000 x 13 000 layer asks for 570 MB against a heap that
 * grows to 256 MiB. Every fatal `unpremultiplyAlpha` OOM in the downstream
 * crash data was one such layer, at 32 to 147 million pixels.
 *
 * So a raster is also held to [OVERLAY_RASTER_BUDGET_FRAMES] frames' worth of
 * pixels — the frame as it is rastered, after [rasterScale] — and to
 * [OVERLAY_RASTER_MAX_PIXELS] whatever the frame. The frame is the composition
 * the layers are laid out in; when a crop is applied after them it is the whole
 * source, not the crop rectangle, or a stretched stroke would be held to four
 * crop rectangles and lose density inside the crop. [capRaster] shrinks a raster
 * over budget on both axes alike and [rasterCompensation] hands the shortfall to
 * Media3 as an overlay scale, exactly as for the ratio cap, so placement and
 * extent do not move. Only a layer more than [OVERLAY_RASTER_BUDGET_FRAMES]
 * times the frame's area loses density, in proportion to how much of it lies
 * outside the frame.
 *
 * A degenerate frame leaves only the absolute ceiling.
 */
internal fun overlayRasterBudget(
    frameWidth: Int,
    frameHeight: Int,
    rasterScale: Float,
): Long {
    if (frameWidth <= 0 || frameHeight <= 0) return OVERLAY_RASTER_MAX_PIXELS
    val (rasteredWidth, rasteredHeight) = capRaster(frameWidth, frameHeight, rasterScale)
    val framePixels = rasteredWidth.toLong() * rasteredHeight
    return minOf(framePixels * OVERLAY_RASTER_BUDGET_FRAMES, OVERLAY_RASTER_MAX_PIXELS)
}

/**
 * Frames' worth of pixels one overlay raster may hold; see [overlayRasterBudget].
 *
 * Four keeps every layer up to twice the frame on each axis at full density — a
 * title pushed past the edges, a sticker used as a backdrop — while the largest
 * raster a 1080p export can produce is four of its 8.3 MB frames.
 */
internal const val OVERLAY_RASTER_BUDGET_FRAMES = 4L

/**
 * Absolute ceiling on one overlay raster, in pixels, whatever the frame.
 *
 * 4096 x 4096 is 64 MiB of RGBA_8888. [unpremultiplyAlpha] holds one direct
 * buffer of the raster's size on the Java heap, and a quarter of the 256 MiB
 * growth limit leaves the rest of the process room to stay alive; a 4K export's
 * four-frame budget would otherwise reach 133 MB.
 */
internal const val OVERLAY_RASTER_MAX_PIXELS = 4096L * 4096L

/**
 * [width] × [height] reduced by [rasterScale], then held under [budget] pixels,
 * never below one pixel per axis.
 *
 * The budget shrinks both axes by one factor so the raster keeps its shape;
 * rounding each axis to a whole pixel can leave the product a row over, which
 * is fine for a memory bound.
 *
 * A zero or negative input is passed through untouched — [overlayDecodeSize]
 * uses `0 × 0` to mean "keep the natural size".
 */
private fun capRaster(
    width: Int,
    height: Int,
    rasterScale: Float,
    budget: Long = Long.MAX_VALUE,
): Pair<Int, Int> {
    if (width <= 0 || height <= 0) return Pair(width, height)
    var scale = rasterScale.coerceAtMost(1f)
    val pixels = width.toDouble() * height * scale * scale
    if (pixels > budget) scale *= sqrt(budget / pixels).toFloat()
    if (scale >= 1f) return Pair(width, height)
    return Pair(
        (width * scale).roundToInt().coerceAtLeast(1),
        (height * scale).roundToInt().coerceAtLeast(1),
    )
}

/**
 * The factor Media3 has to multiply a [rasterSize]-pixel axis by to land back on
 * the [displaySize] the layer was laid out at.
 *
 * It is the exact ratio rather than the raster scale that produced it, because
 * [capRaster] rounds and floors each axis on its own: a 3 px axis capped to
 * `0.1` lands on the one-pixel floor, 3.3x its requested size, while the other
 * axis lands where it asked to. Reading each axis back off its own raster is
 * what keeps such a layer in shape.
 */
internal fun rasterCompensation(displaySize: Int, rasterSize: Int): Float =
    if (rasterSize <= 0 || rasterSize == displaySize) 1f
    else displaySize.toFloat() / rasterSize

/**
 * How much larger than its laid-out size a layer is drawn at most: the largest
 * scale its keyframes give it, and never below 1. [prepareOverlay] rasters a
 * sized layer at that size, which [overlayRasterBudget] still bounds.
 */
internal fun keyframeRasterGrowth(layer: VideoSequenceBuilder.ImageLayerConfig): Double =
    layer.keyframes.maxOfOrNull { it.scale }?.coerceAtLeast(1.0) ?: 1.0

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
    rasterBudget: Long = Long.MAX_VALUE,
): PreparedOverlay {
    val raster = planOverlayRaster(
        rawBitmap.width, rawBitmap.height, layer, videoWidth, videoHeight,
        rasterScale, rasterBudget
    )
    val isStretched = raster.isStretched
    val hasExplicitSize = layer.width != null && layer.height != null
    val rasterWidth = raster.rasterWidth
    val rasterHeight = raster.rasterHeight

    // Scale straight to the raster size. A stretched layer goes to the frame
    // (capped) in one step rather than through its declared size first.
    val sizedBitmap = if (
        isStretched || hasExplicitSize ||
        rasterWidth != rawBitmap.width || rasterHeight != rawBitmap.height
    ) {
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

    // Rotate the overlay around its center. baseNormX/baseNormY describe the
    // (unrotated) layout center; rotating about the bitmap center keeps that
    // point fixed, so the anchor stays correct while the bounding box grows
    // symmetrically. A keyframed layer is turned by its keyframes instead,
    // frame by frame (see [AnimatedBitmapOverlay]), so its box stays upright.
    val rotatedOverlay = if (layer.keyframes.isNotEmpty()) {
        finalOverlay
    } else {
        rotateBitmap(finalOverlay, Math.toDegrees(layer.rotation).toFloat())
    }

    return placeOverlay(rotatedOverlay, raster, layer, videoWidth, videoHeight)
}

/**
 * The overlay of an audio visualizer layer, or `null` when the layer has no
 * box to fill: a positioned layer without a size.
 *
 * The visualizer is rastered as an image of the layer's box would be — at the
 * layer's largest keyframe scale, held to the raster budget, turned by the
 * layer's rotation — and placed and animated through the same overlay, so it
 * sits exactly where an image layer of that box would.
 */
@UnstableApi
private fun prepareAudioVisualizerOverlay(
    layer: VideoSequenceBuilder.ImageLayerConfig,
    visualizer: LayerAudioVisualizerConfig,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float,
    rasterBudget: Long,
): BitmapOverlay? {
    val isStretched = layer.x == null && layer.y == null
    val width = layer.width
    val height = layer.height
    val (boxWidth, boxHeight) = when {
        isStretched -> Pair(videoWidth, videoHeight)
        width != null && height != null -> Pair(width.toInt(), height.toInt())
        else -> return null
    }
    if (boxWidth <= 0 || boxHeight <= 0) return null

    // As large as the box at its largest keyframe scale, the raster a sized
    // image of that resolution would get.
    val growth = if (isStretched) 1.0 else keyframeRasterGrowth(layer)
    val raster = planOverlayRaster(
        (boxWidth * growth).roundToInt(), (boxHeight * growth).roundToInt(),
        layer, videoWidth, videoHeight, rasterScale, rasterBudget
    )
    // A keyframed layer is turned by its keyframes, frame by frame.
    val degrees = if (layer.keyframes.isNotEmpty()) 0f
        else Math.toDegrees(layer.rotation).toFloat()
    val (targetWidth, targetHeight) = rotatedBoxSize(
        raster.rasterWidth, raster.rasterHeight, degrees
    )
    val target = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
    val prepared = placeOverlay(target, raster, layer, videoWidth, videoHeight)

    val placement = if (layer.animations.isNotEmpty() || layer.keyframes.isNotEmpty()) {
        AnimatedBitmapOverlay(
            bitmap = target,
            baseNormX = prepared.baseNormX,
            baseNormY = prepared.baseNormY,
            imageWidth = prepared.displayWidth,
            imageHeight = prepared.displayHeight,
            videoWidth = videoWidth,
            videoHeight = videoHeight,
            layerX = (layer.x ?: 0).toFloat(),
            layerY = (layer.y ?: 0).toFloat(),
            layerStartUs = layer.startUs,
            layerEndUs = layer.endUs,
            animations = layer.animations,
            rasterScaleX = prepared.rasterScaleX,
            rasterScaleY = prepared.rasterScaleY,
            animationStartUs = layer.animationStartUs,
            animationEndUs = layer.animationEndUs,
            keyframes = layer.keyframes,
            keyframeClock = layer.keyframeClock
        )
    } else {
        BitmapOverlay.createStaticBitmapOverlay(target, prepared.overlaySettings)
    }
    return AudioVisualizerOverlay(
        placement = placement,
        target = target,
        visualizer = visualizer,
        boxWidth = raster.displayWidth.toFloat(),
        boxHeight = raster.displayHeight.toFloat(),
        rotationDegrees = degrees,
        rasterScaleX = raster.scaleX,
        rasterScaleY = raster.scaleY,
    )
}

/**
 * The bounding box of a [width] x [height] raster turned by [degrees] about its
 * center, in whole pixels and at least one per axis.
 */
internal fun rotatedBoxSize(width: Int, height: Int, degrees: Float): Pair<Int, Int> {
    if (degrees % 360f == 0f) return Pair(width, height)
    val radians = Math.toRadians(degrees.toDouble())
    val cos = abs(cos(radians))
    val sin = abs(sin(radians))
    return Pair(
        (width * cos + height * sin).roundToInt().coerceAtLeast(1),
        (width * sin + height * cos).roundToInt().coerceAtLeast(1),
    )
}

/**
 * The size an overlay is laid out at and the size it is rastered at; see
 * [planOverlayRaster].
 *
 * @property displayWidth The unrotated width the layer occupies in the
 *   composition, in composition pixels.
 * @property rasterWidth The width it is rastered at, before any rotation.
 * @property scaleX What Media3 multiplies the raster by to land back on
 *   [displayWidth]; `1f` when uncapped.
 */
private data class OverlayRaster(
    val isStretched: Boolean,
    val displayWidth: Int,
    val displayHeight: Int,
    val rasterWidth: Int,
    val rasterHeight: Int,
    val scaleX: Float,
    val scaleY: Float,
)

/**
 * Plans how [layer] is rastered from an image of [rawWidth] x [rawHeight]:
 * the size it is laid out at and the size its raster is held to.
 */
private fun planOverlayRaster(
    rawWidth: Int,
    rawHeight: Int,
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
    rasterScale: Float,
    rasterBudget: Long,
): OverlayRaster {
    // Determine if this layer should stretch or be positioned
    val isStretched = layer.x == null && layer.y == null
    val hasExplicitSize = layer.width != null && layer.height != null

    // Size the overlay occupies in the composition. The raster below may be
    // smaller (see [overlayRasterScale] and [overlayRasterBudget]); placement
    // is laid out from these and the shortfall is handed back to Media3 as an
    // overlay scale.
    //
    // A positioned layer with no explicit size is laid out from its own pixel
    // dimensions, so [overlayDecodeSize] does not sample it down and the raster
    // is not capped here either — capping it would shrink the overlay. Only
    // one converted into a clip of another size is capped (see below).
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
            // Its own pixels, converted into a clip of another size than the
            // composition frame (see [scaledToClipFrame]). Converted, it is
            // resampled anyway, so it is held to the raster budget like a sized
            // layer: a clip larger than the frame on one axis scales it up.
            displayWidth = (rawWidth * layer.naturalSizeScale)
                .roundToInt().coerceAtLeast(1)
            displayHeight = (rawHeight * layer.naturalSizeScale)
                .roundToInt().coerceAtLeast(1)
            cappable = layer.naturalSizeScale != 1.0
        }
    }

    val (rasterWidth, rasterHeight) = if (cappable) {
        // A layer that keyframes grow is rastered at its largest size, so it
        // stays sharp rather than stretching the pixels of its smaller self —
        // but never above what the decoded image holds, which would only
        // stretch them here instead.
        val growth = min(
            keyframeRasterGrowth(layer),
            max(
                1.0,
                min(
                    rawWidth.toDouble() / displayWidth,
                    rawHeight.toDouble() / displayHeight
                )
            )
        )
        capRaster(
            (displayWidth * growth).roundToInt(), (displayHeight * growth).roundToInt(),
            rasterScale, rasterBudget
        )
    } else {
        Pair(displayWidth, displayHeight)
    }
    // Media3 multiplies the overlay by these, so they must undo the cap exactly.
    val overlayScaleX = rasterCompensation(displayWidth, rasterWidth)
    val overlayScaleY = rasterCompensation(displayHeight, rasterHeight)

    return OverlayRaster(
        isStretched = isStretched,
        displayWidth = displayWidth,
        displayHeight = displayHeight,
        rasterWidth = rasterWidth,
        rasterHeight = rasterHeight,
        scaleX = overlayScaleX,
        scaleY = overlayScaleY,
    )
}

/**
 * Anchors [rotatedOverlay], the raster [raster] planned turned by the layer's
 * rotation, where [layer] places it.
 */
@UnstableApi
private fun placeOverlay(
    rotatedOverlay: Bitmap,
    raster: OverlayRaster,
    layer: VideoSequenceBuilder.ImageLayerConfig,
    videoWidth: Int,
    videoHeight: Int,
): PreparedOverlay {
    val isStretched = raster.isStretched
    val displayWidth = raster.displayWidth
    val displayHeight = raster.displayHeight
    val overlayScaleX = raster.scaleX
    val overlayScaleY = raster.scaleY

    var baseNormX = 0f
    var baseNormY = 0f

    if (!isStretched) {
        val x = layer.x ?: 0
        val y = layer.y ?: 0

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
    }

    // Rotation grows the bounding box. The display size grows with it, per
    // axis, so a caller laying out from [PreparedOverlay.displayWidth] sees the
    // rotated extent rather than the unrotated one.
    val grownWidth = (rotatedOverlay.width * overlayScaleX).roundToInt()
    val grownHeight = (rotatedOverlay.height * overlayScaleY).roundToInt()

    val overlaySettings = if (isStretched) {
        StaticOverlaySettings.Builder()
            .setOverlayFrameAnchor(0f, 0f)
            .setBackgroundFrameAnchor(0f, 0f)
            .setScale(overlayScaleX, overlayScaleY)
            .build()
    } else {
        // Media3 rejects an anchor outside [-1, 1], which dropped a layer
        // centred off the frame; its position is split across both anchors
        // instead (see [resolveAnchor]). One wholly off the frame is hidden.
        val anchorX = resolveAnchor(baseNormX, grownWidth.toFloat() / videoWidth)
        val anchorY = resolveAnchor(baseNormY, grownHeight.toFloat() / videoHeight)
        val offFrame = liesOffFrame(
            baseNormX, baseNormY, grownWidth / 2f, grownHeight / 2f, 0f,
            videoWidth, videoHeight
        )
        StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(anchorX.backgroundAnchor, anchorY.backgroundAnchor)
            .setOverlayFrameAnchor(anchorX.overlayAnchor, anchorY.overlayAnchor)
            .setScale(overlayScaleX, overlayScaleY)
            .setAlphaScale(if (offFrame) 0f else 1f)
            .build()
    }

    return PreparedOverlay(
        bitmap = rotatedOverlay,
        baseNormX = baseNormX,
        baseNormY = baseNormY,
        overlaySettings = overlaySettings,
        displayWidth = grownWidth,
        displayHeight = grownHeight,
        rasterScaleX = overlayScaleX,
        rasterScaleY = overlayScaleY,
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
 * Works through a small reusable scratch band rather than reading the whole
 * buffer out into a `ByteArray` of its own size. That second full-frame array
 * was the point: both it and [buf] are Java-heap allocations counted against
 * Android's per-app growth limit — `ByteBuffer.allocateDirect` reaches it
 * through `newNonMovableArray` — and a full-frame overlay made each of them tens
 * of megabytes, once per layer, on the path that was already running out.
 *
 * The band keeps the arithmetic on a plain `ByteArray`, which is materially
 * faster than absolute get/put against a direct buffer, so the memory is bought
 * back without paying for it in render time. [bandBytes] is rounded down to a
 * whole number of pixels so no band ever splits one; it is a parameter only so
 * tests can force several bands over a small buffer.
 *
 * Pixels are ARGB_8888 in raw byte order: R, G, B, A. A fully transparent or
 * fully opaque pixel is left alone: there is nothing to divide out of an opaque
 * one, and `a == 0` carries no colour to recover and would divide by zero. A
 * channel above its own alpha — which premultiplied data should not contain —
 * saturates instead of wrapping around the byte.
 */
internal fun unpremultiplyInPlace(
    buf: ByteBuffer,
    byteCount: Int,
    bandBytes: Int = DEFAULT_UNPREMULTIPLY_BAND_BYTES,
) {
    if (byteCount < 4) return

    // Whole pixels only; a trailing partial pixel is not ours to touch.
    val pixelBytes = byteCount - (byteCount % 4)
    // Likewise for the band: one that ended mid-pixel would read past its own
    // end on the last pixel it started.
    val band = minOf(bandBytes, pixelBytes).let { it - (it % 4) }.coerceAtLeast(4)
    val scratch = ByteArray(band)

    var offset = 0
    while (offset < pixelBytes) {
        val len = minOf(band, pixelBytes - offset)

        buf.position(offset)
        buf.get(scratch, 0, len)

        var o = 0
        while (o < len) {
            val a = scratch[o + 3].toInt() and 0xFF
            if (a in 1..254) {
                scratch[o] = unpremultiplyChannel(scratch[o], a)
                scratch[o + 1] = unpremultiplyChannel(scratch[o + 1], a)
                scratch[o + 2] = unpremultiplyChannel(scratch[o + 2], a)
            }
            o += 4
        }

        buf.position(offset)
        buf.put(scratch, 0, len)

        offset += len
    }
}

/**
 * [channel] divided back out by its own [alpha], saturating at `255`.
 *
 * Premultiplied data should never hold a channel above its own alpha, but a
 * quotient that does not fit a byte used to be truncated to its low 8 bits —
 * turning a channel that overshot white into a near-black one. Saturating keeps
 * such a pixel at the end of the range it overshot.
 */
private fun unpremultiplyChannel(channel: Byte, alpha: Int): Byte =
    ((((channel.toInt() and 0xFF) * 255) / alpha).coerceAtMost(255)).toByte()

/**
 * Scratch band [unpremultiplyInPlace] converts through, in bytes.
 *
 * 64 KiB is large enough that the per-band bulk copies disappear next to the
 * per-pixel work, and small enough to be irrelevant beside the frame buffer it
 * replaced — the whole point of the band.
 */
private const val DEFAULT_UNPREMULTIPLY_BAND_BYTES = 64 * 1024
