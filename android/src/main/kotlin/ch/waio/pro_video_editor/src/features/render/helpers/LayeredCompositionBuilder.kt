package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.AlphaScale
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.features.render.models.AudioTrackConfig
import ch.waio.pro_video_editor.src.features.render.models.CompositionConfig
import ch.waio.pro_video_editor.src.features.render.models.SegmentTransformConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import kotlin.math.max
import kotlin.math.min

/**
 * Builds a layered Media3 [Composition] from a [CompositionConfig].
 *
 * Each layer becomes its own [EditedMediaItemSequence]. Placement is done by a
 * per-clip [VideoCompositionTransformation] GlEffect that draws the clip into
 * its target rectangle on a transparent, canvas-sized frame and scissors it to
 * that rectangle (so `cover` overflow can't bleed onto other layers); the
 * default Media3 compositor then alpha-blends the sequences. The sequences are
 * submitted top-most first, because the compositor draws the first sequence on
 * top of the rest (see [build]). Delayed entry (`timelineStart`) and inter-clip
 * gaps are filled with a transparent image item rather than `addGap`, which
 * avoids a crash in Media3's gap handling.
 *
 * Global color/blur effects and image overlays are applied at the composition
 * level (on top of the composed frame).
 */
@UnstableApi
class LayeredCompositionBuilder(
    private val context: Context,
    private val config: CompositionConfig,
    private val enableAudio: Boolean,
    /** Global color/blur effects, applied to the whole composed frame. */
    private val globalVideoEffects: List<Effect> = emptyList(),
    /** Image overlays, applied on top of the composed frame. */
    private val imageLayers: List<VideoSequenceBuilder.ImageLayerConfig> = emptyList(),
    /** Custom audio tracks mixed natively alongside the layers' audio. */
    private val audioTracks: List<AudioTrackConfig> = emptyList(),
    /** Global trim start across the whole composition, in microseconds. */
    private val globalStartUs: Long? = null,
    /** Global trim end across the whole composition, in microseconds. */
    private val globalEndUs: Long? = null
) {
    /** Temp files (source duplicates) to delete after export. */
    val temporaryFiles: MutableList<File> = mutableListOf()

    private companion object {
        /**
         * Media3's Transformer drops the final partial GOP of the last item in a
         * sequence when that item is clipped to end before its source end. A
         * short transparent tail after such a clip flushes it. Kept small so the
         * trimmed end is barely extended.
         */
        const val FLUSH_TAIL_US = 120_000L

        /** Slack for treating a clip end as "the source end" (no real tail). */
        const val SOURCE_END_EPSILON_US = 100_000L
    }

    /** A built layer sequence plus the metadata needed to finalize it. */
    private data class PendingLayer(
        val builder: EditedMediaItemSequence.Builder,
        val durationUs: Long,
        /** Whether the layer's last clip ends before its source end. */
        val endsBeforeSource: Boolean
    )

    private data class DrawRect(val x: Double, val y: Double, val w: Double, val h: Double)

    /**
     * Where a clip is drawn on the canvas. [draw] is the (possibly oversized for
     * `cover`) destination rectangle; [clip] is the target box the draw is
     * scissored to so overflow can't bleed onto other layers. [clip] is `null`
     * when the clip fills the whole canvas (no clipping needed).
     */
    private data class Placement(val draw: DrawRect, val clip: DrawRect?)

    fun build(): Composition {
        // Resolve the canvas size up front so transparent gaps can be sized.
        var canvasW = config.canvasWidth?.toInt() ?: 0
        var canvasH = config.canvasHeight?.toInt() ?: 0
        if (canvasW <= 0 || canvasH <= 0) {
            val first = config.layers.firstOrNull()?.clips?.firstOrNull()
            if (first != null) {
                val (w, h) = readDisplaySize(first.inputPath)
                canvasW = w
                canvasH = h
            }
        }
        if (canvasW <= 0 || canvasH <= 0) {
            canvasW = 1920
            canvasH = 1080
        }

        // Declare only the video track type. Declaring AUDIO makes Media3 try to
        // force a silent audio track on a muted/video-only layer, which crashes
        // in SequenceAssetLoader during compositing. Real audio still flows.
        val trackTypes = setOf(C.TRACK_TYPE_VIDEO)

        // Media3 can fail to produce frames for a second sequence streaming from
        // the same file URI, so a reused source gets a distinct URI per layer.
        val pathsUsedByPriorLayers = mutableSetOf<String>()

        // Global trim across the whole composition timeline. Media3 has no
        // output trim, so it is baked into each layer's clips: the untrimmed
        // composition time is intersected with [globalStart, globalEnd] and the
        // result is shifted so globalStart maps to 0 in the output.
        val globalStart = globalStartUs ?: 0L
        val globalEnd = globalEndUs ?: Long.MAX_VALUE

        // Build each layer's sequence, tracking its filled duration so all
        // layers can later be padded to the full composition length.
        val pending = mutableListOf<PendingLayer>()
        var globalDurationUs = 0L

        for ((layerIndex, layer) in config.layers.withIndex()) {
            val seqBuilder = EditedMediaItemSequence.Builder(trackTypes)
                .setIsLooping(false)
            val pathsInThisLayer = mutableSetOf<String>()
            val layerSourceCopies = mutableMapOf<String, String>()
            var untrimmedCursorUs = 0L
            var outputCursorUs = 0L
            var itemCount = 0
            var lastClipEndsBeforeSource = false

            for (clip in layer.clips) {
                val (displayW, displayH) = readDisplaySize(clip.inputPath)
                val srcMediaDurationUs = MediaInfoExtractor.getVideoDuration(clip.inputPath)
                val fullDurationUs =
                    ((clip.endUs ?: srcMediaDurationUs) - (clip.startUs ?: 0L))
                        .coerceAtLeast(0L)
                if (fullDurationUs <= 0) continue

                // Untrimmed composition span of this clip.
                val clipCompStart = maxOf(untrimmedCursorUs, clip.timelineStartUs ?: untrimmedCursorUs)
                val clipCompEnd = clipCompStart + fullDurationUs
                untrimmedCursorUs = clipCompEnd

                // Intersect with the global trim window.
                val visibleStart = maxOf(clipCompStart, globalStart)
                val visibleEnd = minOf(clipCompEnd, globalEnd)
                if (visibleEnd <= visibleStart) continue

                val outputDurationUs = visibleEnd - visibleStart
                val outputStartUs = visibleStart - globalStart
                val trimmed = visibleStart > clipCompStart || visibleEnd < clipCompEnd

                // Source range to play: keep the clip's own trim when the global
                // trim doesn't cut this clip, else shift it accordingly.
                val srcStartUs: Long?
                val srcEndUs: Long?
                if (trimmed) {
                    val s = (clip.startUs ?: 0L) + (visibleStart - clipCompStart)
                    srcStartUs = s
                    srcEndUs = s + outputDurationUs
                } else {
                    srcStartUs = clip.startUs
                    srcEndUs = clip.endUs
                }

                // Leading gap in the output timeline.
                val gapUs = (outputStartUs - outputCursorUs).coerceAtLeast(0L)
                if (gapUs > 0) {
                    seqBuilder.addItem(transparentGapItem(gapUs, canvasW, canvasH))
                    outputCursorUs += gapUs
                }

                val effectivePath = if (clip.inputPath in pathsUsedByPriorLayers) {
                    layerSourceCopies.getOrPut(clip.inputPath) {
                        distinctSourceFor(clip.inputPath)
                    }
                } else {
                    clip.inputPath
                }
                pathsInThisLayer.add(clip.inputPath)

                val placement = resolvePlacement(
                    clip.transform ?: layer.transform, displayW, displayH, canvasW, canvasH
                )
                seqBuilder.addItem(
                    buildClipItem(
                        clip, srcStartUs, srcEndUs, effectivePath, placement,
                        displayW, displayH, layer.opacity, canvasW, canvasH
                    )
                )
                outputCursorUs += outputDurationUs
                itemCount++
                // Track whether this (so far last) clip ends before its source
                // end, so we can flush Media3's dropped tail GOP if it stays last.
                lastClipEndsBeforeSource =
                    srcEndUs != null && srcEndUs < srcMediaDurationUs - SOURCE_END_EPSILON_US
            }

            if (itemCount == 0) continue
            pending.add(PendingLayer(seqBuilder, outputCursorUs, lastClipEndsBeforeSource))
            globalDurationUs = max(globalDurationUs, outputCursorUs)
            pathsUsedByPriorLayers.addAll(pathsInThisLayer)
            Log.d(
                RENDER_TAG,
                "  Layer $layerIndex: items=$itemCount duration=${outputCursorUs / 1000}ms " +
                    "opacity=${layer.opacity}"
            )
        }

        require(pending.isNotEmpty()) { "Composition produced no usable layers" }

        // Pad every layer to the full composition duration so shorter layers
        // don't freeze their last frame, then order them top-most first: the
        // Media3 compositor draws the first sequence on top, and layer 0 is the
        // bottom layer.
        val layerSequences = pending.map { layer ->
            when {
                layer.durationUs < globalDurationUs ->
                    // Shorter layer: pad to full length. The pad also acts as the
                    // following item that flushes this layer's last clip.
                    layer.builder.addItem(
                        transparentGapItem(globalDurationUs - layer.durationUs, canvasW, canvasH)
                    )
                layer.endsBeforeSource ->
                    // Longest layer whose last clip is cut before its source end:
                    // append a short tail so Media3 doesn't drop its final GOP.
                    layer.builder.addItem(transparentGapItem(FLUSH_TAIL_US, canvasW, canvasH))
            }
            layer.builder.build()
        }.reversed()

        // Solid background as the bottom-most sequence so areas not covered by
        // any clip show the configured color (the default Media3 compositor
        // would otherwise leave them black). Appended last = drawn at the bottom.
        val videoSequences = layerSequences +
            backgroundColorSequence(globalDurationUs, canvasW, canvasH)

        // Custom audio tracks as separate sequences, mixed natively by Media3.
        // Per-track volume is applied by the VolumeControlAudioMixerFactory set
        // on the Transformer.
        val audioSequences = audioTracks.mapNotNull { track ->
            AudioSequenceBuilder(context, track.path, globalDurationUs)
                .setLoop(track.loop)
                .setStartTime(track.audioStartUs)
                .setAudioEndTime(track.audioEndUs)
                .setCompositionStartTime(track.startUs)
                .setCompositionEndTime(track.endUs)
                .build()
                ?.also { temporaryFiles.add(it.temporaryFile) }
                ?.sequence
        }

        val sequences = videoSequences + audioSequences
        Log.d(
            RENDER_TAG,
            "Layered composition: ${videoSequences.size} layers, " +
                "${audioSequences.size} audio tracks, canvas ${canvasW}x$canvasH, " +
                "duration=${globalDurationUs / 1000}ms"
        )

        // Composition-level video effects: global color/blur first, then image
        // overlays on top, then the canvas presentation last.
        val compositionEffects = globalVideoEffects.toMutableList()
        // Resolve "until end" layers with an out-phase animation to the full
        // composition length so their animateOut can play (the composition has a
        // single global timeline, so this is unambiguous here).
        applyTimedImageLayers(
            compositionEffects,
            resolveOpenEndedOutAnimations(imageLayers, globalDurationUs),
            canvasW, canvasH
        )
        compositionEffects += Presentation.createForWidthAndHeight(
            canvasW, canvasH, Presentation.LAYOUT_SCALE_TO_FIT
        )

        return Composition.Builder(sequences)
            .setEffects(Effects(emptyList(), compositionEffects))
            .build()
    }

    private fun buildClipItem(
        clip: VideoClip,
        srcStartUs: Long?,
        srcEndUs: Long?,
        inputPath: String,
        placement: Placement,
        displayW: Int,
        displayH: Int,
        opacity: Float,
        canvasW: Int,
        canvasH: Int
    ): EditedMediaItem {
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(File(inputPath)))
        if (srcStartUs != null || srcEndUs != null) {
            val clipping = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionUs(srcStartUs ?: 0L)
            if (srcEndUs != null) clipping.setEndPositionUs(srcEndUs)
            mediaItemBuilder.setClippingConfiguration(clipping.build())
        }

        val effects = mutableListOf<Effect>()
        val draw = placement.draw
        val clipBox = placement.clip
        effects += VideoCompositionTransformation(
            x = draw.x,
            y = draw.y,
            width = draw.w,
            height = draw.h,
            videoWidth = displayW,
            videoHeight = displayH,
            renderWidth = canvasW,
            renderHeight = canvasH,
            clipX = clipBox?.x,
            clipY = clipBox?.y,
            clipWidth = clipBox?.w,
            clipHeight = clipBox?.h
        )
        applyOpacity(effects, opacity)

        // Note: no setDurationUs here. For video, Media3's duration is the input
        // media length (pre-clip); the playable span is defined by the clipping
        // above. Setting it to the clipped output makes Media3 treat the source
        // as that short and clamps a mid-source end, dropping frames.
        val removeAudio = !enableAudio || (clip.volume ?: 1.0f) <= 0f
        return EditedMediaItem.Builder(mediaItemBuilder.build())
            .setRemoveAudio(removeAudio)
            .setEffects(Effects(emptyList(), effects))
            .build()
    }

    /**
     * Resolves the destination rectangle (canvas pixels, top-left origin) for a
     * clip given its transform and source display size, together with the box it
     * is clipped to. `null` transform fills the canvas (no clipping).
     */
    private fun resolvePlacement(
        cfg: SegmentTransformConfig?,
        displayW: Int,
        displayH: Int,
        canvasW: Int,
        canvasH: Int
    ): Placement {
        if (cfg == null) {
            return Placement(
                DrawRect(0.0, 0.0, canvasW.toDouble(), canvasH.toDouble()),
                clip = null
            )
        }
        val dW = displayW.toDouble().coerceAtLeast(1.0)
        val dH = displayH.toDouble().coerceAtLeast(1.0)
        val boxX = cfg.offsetX ?: 0.0
        val boxY = cfg.offsetY ?: 0.0
        val boxW = cfg.width ?: dW
        val boxH = cfg.height ?: dH
        val box = DrawRect(boxX, boxY, boxW, boxH)
        val draw = when (cfg.fit) {
            "contain" -> {
                val s = min(boxW / dW, boxH / dH)
                val w = dW * s
                val h = dH * s
                DrawRect(boxX + (boxW - w) / 2, boxY + (boxH - h) / 2, w, h)
            }
            "cover" -> {
                val s = max(boxW / dW, boxH / dH)
                val w = dW * s
                val h = dH * s
                DrawRect(boxX + (boxW - w) / 2, boxY + (boxH - h) / 2, w, h)
            }
            else -> box // "fill"
        }
        return Placement(draw, box)
    }

    /**
     * A fully transparent, canvas-sized item of [durationUs], used to delay a
     * layer's entry or bridge a gap between clips without `addGap`.
     */
    private fun transparentGapItem(durationUs: Long, canvasW: Int, canvasH: Int): EditedMediaItem {
        val gapFile = File(context.cacheDir, "pve_transparent_gap.png")
        if (!gapFile.exists()) {
            try {
                val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.TRANSPARENT)
                gapFile.outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Failed to create transparent gap PNG: ${e.message}")
            }
        }
        // Fail loudly rather than building a MediaItem on a missing file, which
        // would surface later as an opaque Media3 export error.
        if (!gapFile.exists() || gapFile.length() == 0L) {
            throw IllegalStateException(
                "Could not create transparent gap frame at ${gapFile.path}"
            )
        }
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(gapFile))
            .setImageDurationMs(maxOf(1, (durationUs + 999) / 1000))
            .build()
        val effects = mutableListOf<Effect>()
        effects += AlphaScale(0f)
        // Keep it off-screen too, in case alpha is ignored anywhere.
        effects += VideoCompositionTransformation(
            x = -100.0, y = -100.0, width = 1.0, height = 1.0,
            videoWidth = 1, videoHeight = 1, renderWidth = canvasW, renderHeight = canvasH
        )
        return EditedMediaItem.Builder(mediaItem)
            .setFrameRate(30)
            .setEffects(Effects(emptyList(), effects))
            .build()
    }

    /**
     * A full-canvas, solid [CompositionConfig.backgroundColor] sequence used as
     * the bottom layer so areas not covered by any clip show the configured
     * color. Without it the default Media3 compositor leaves them black.
     */
    private fun backgroundColorSequence(
        durationUs: Long,
        canvasW: Int,
        canvasH: Int
    ): EditedMediaItemSequence {
        val argb = config.backgroundColor.toInt()
        val bgFile = File(context.cacheDir, "pve_bg_$argb.png")
        if (!bgFile.exists() || bgFile.length() == 0L) {
            try {
                val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(argb)
                bgFile.outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Failed to create background PNG: ${e.message}")
            }
        }
        if (!bgFile.exists() || bgFile.length() == 0L) {
            throw IllegalStateException(
                "Could not create background frame at ${bgFile.path}"
            )
        }
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(bgFile))
            .setImageDurationMs(maxOf(1, (durationUs + 999) / 1000))
            .build()
        // Scale the 1x1 color to fill the whole canvas.
        val item = EditedMediaItem.Builder(mediaItem)
            .setFrameRate(30)
            .setEffects(
                Effects(
                    emptyList(),
                    listOf(
                        VideoCompositionTransformation(
                            x = 0.0, y = 0.0,
                            width = canvasW.toDouble(), height = canvasH.toDouble(),
                            videoWidth = 1, videoHeight = 1,
                            renderWidth = canvasW, renderHeight = canvasH
                        )
                    )
                )
            )
            .build()
        return EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
            .setIsLooping(false)
            .addItem(item)
            .build()
    }

    /**
     * Returns a distinct file path with the same content as [path], so Media3
     * sees a unique URI per layer. Prefers a symlink, falls back to a copy. The
     * result is registered in [temporaryFiles] for cleanup after export.
     */
    private fun distinctSourceFor(path: String): String {
        val src = File(path)
        val ext = src.extension.ifEmpty { "mp4" }
        val dst = File(context.cacheDir, "layer_src_${System.nanoTime()}.$ext")
        try {
            android.system.Os.symlink(src.absolutePath, dst.absolutePath)
        } catch (e: Exception) {
            try {
                src.copyTo(dst, overwrite = true)
            } catch (e2: Exception) {
                Log.w(RENDER_TAG, "Could not duplicate source $path: ${e2.message}")
                return path
            }
        }
        temporaryFiles.add(dst)
        return dst.path
    }

    /** Reads a clip's display size (rotation applied), or (0,0) on failure. */
    private fun readDisplaySize(path: String): Pair<Int, Int> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val w = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val h = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            if (rotation == 90 || rotation == 270) Pair(h, w) else Pair(w, h)
        } catch (e: Exception) {
            Log.w(RENDER_TAG, "Failed to read size for $path: ${e.message}")
            Pair(0, 0)
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }
}
