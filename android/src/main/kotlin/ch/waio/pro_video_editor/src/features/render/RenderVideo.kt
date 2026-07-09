package ch.waio.pro_video_editor.src.features.render

import RENDER_TAG
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import mapFormatToMimeType
import ch.waio.pro_video_editor.src.features.render.helpers.BitrateCapPolicy
import ch.waio.pro_video_editor.src.features.render.helpers.ResilientVideoEncoderFactory
import ch.waio.pro_video_editor.src.features.render.helpers.applyComposition
import ch.waio.pro_video_editor.src.features.render.helpers.VolumeControlAudioMixerFactory
import ch.waio.pro_video_editor.src.features.render.helpers.ConfigurableInAppMp4Muxer
import ch.waio.pro_video_editor.src.features.render.helpers.VideoTranscoder
import ch.waio.pro_video_editor.src.features.render.helpers.VideoReverser
import ch.waio.pro_video_editor.src.features.render.helpers.ClipTransitionGeometry
import ch.waio.pro_video_editor.src.features.render.helpers.ClipTransitionRenderer
import ch.waio.pro_video_editor.src.features.render.helpers.MediaInfoExtractor
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderJobHandle
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.features.render.models.VideoEncoderConfigurationException

/**
 * Service for rendering video with applied effects and transformations.
 *
 * This class handles the complete video rendering pipeline using AndroidX Media3 Transformer:
 * - Applies visual and audio effects based on configuration
 * - Manages output file handling (both temporary and permanent)
 * - Provides progress tracking during rendering
 * - Supports cancellation of active render jobs
 * - Pre-transcodes HEVC 10-bit HDR videos when GPU effects are needed
 */
@UnstableApi
class RenderVideo(private val context: Context) {

    private val effectsProcessor = EffectsProcessor()

    /**
     * Checks if the render configuration includes GPU-intensive effects
     * that are incompatible with HEVC 10-bit HDR videos.
     */
    private fun hasGpuEffects(config: RenderConfig): Boolean {
        // These effects use GPU surfaces and fail with HEVC 10-bit HDR
        val hasImageLayers = config.imageLayers.isNotEmpty()
        val hasBlur = config.blur != null && config.blur > 0.0
        val hasColorFilters = config.colorFilters.isNotEmpty()

        return hasImageLayers || hasBlur || hasColorFilters
    }

    /**
     * Checks if transcoding is needed for video compatibility.
     * 
     * Transcoding is needed when:
     * 1. GPU effects are used with HEVC 10-bit HDR videos
     * 2. Multiple videos are being merged and at least one is HEVC 10-bit
     *    (mixing different codecs in a composition can cause frame processing errors)
     */
    private fun needsPreTranscoding(config: RenderConfig): Boolean {
        // Check for GPU effects
        if (hasGpuEffects(config)) {
            return true
        }

        // When multiple clips are being merged, check if any need transcoding
        // Mixing different codecs (HEVC + H.264) can cause frame processing errors
        if (config.videoClips.size > 1) {
            val hasAnyHevc10bit = config.videoClips.any { clip ->
                VideoTranscoder.needsTranscoding(clip.inputPath)
            }
            if (hasAnyHevc10bit) {
                Log.d(
                    RENDER_TAG, "Multiple video clips with HEVC 10-bit detected, " +
                            "pre-transcoding to ensure codec compatibility"
                )
                return true
            }
        }

        return false
    }

    /**
     * Starts an asynchronous video render job.
     *
     * This method configures and starts a Media3 Transformer to process the video
     * with the specified effects. The operation runs asynchronously and provides
     * callbacks for progress updates, completion, and errors.
     *
     * @param config Complete render configuration including input, output, and effects
     * @param onProgress Callback invoked with progress updates (0.0 to 1.0)
     * @param onComplete Callback invoked on success with output bytes (null if saved to file)
     * @param onError Callback invoked if rendering fails
     * @return RenderJobHandle that can be used to cancel the render job
     */
    fun render(
        config: RenderConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        val shouldStopPolling = AtomicBoolean(false)
        val mainHandler = Handler(Looper.getMainLooper())
        var transcodedFiles: List<String> = emptyList()
        var reversedFiles: List<String> = emptyList()
        var transitionFiles: List<String> = emptyList()
        val transformerRef = AtomicReference<Transformer?>(null)
        val outputFileRef = AtomicReference<File?>(null)

        val needsPreTranscode = needsPreTranscoding(config)
        val needsPreReverse = config.videoClips.any { it.reverseVideo }
        // An overlap transition on a non-last clip blends into the next clip; on
        // the last (or only) clip it wraps into the first for a seamless loop.
        // Both are baked by [preRenderTransitions], so either needs the stage.
        val needsPreTransitions =
                config.videoClips.any { it.transition?.isOverlap == true }

        // Progress split across the slow pre-render stages and the transformer.
        // Reverse + overlap-transition pre-renders each get a share; whatever is
        // left belongs to the transformer phase.
        val reverseShare = if (needsPreReverse) 0.4 else 0.0
        val transitionShare = if (needsPreTransitions) 0.4 else 0.0
        val transformShare = 1.0 - reverseShare - transitionShare
        val reverseProgress: (Double) -> Unit = { p ->
            onProgress((p * reverseShare).coerceIn(0.0, 1.0))
        }
        val transitionProgress: (Double) -> Unit = { p ->
            onProgress((reverseShare + p * transitionShare).coerceIn(0.0, 1.0))
        }
        val transformProgress: (Double) -> Unit = { p ->
            onProgress(
                (reverseShare + transitionShare + p * transformShare).coerceIn(0.0, 1.0)
            )
        }

        val cleanupAllPreFiles: () -> Unit = {
            VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
            VideoReverser.cleanupReversedFiles(reversedFiles)
            ClipTransitionRenderer.cleanupFiles(transitionFiles)
        }

        if (!needsPreTranscode && !needsPreReverse && !needsPreTransitions) {
            // Fast path: nothing to pre-process.
            renderInternal(
                config = config,
                onProgress = onProgress,
                onComplete = onComplete,
                onError = onError,
                shouldStopPolling = shouldStopPolling,
                mainHandler = mainHandler,
                transformerRef = transformerRef,
                outputFileRef = outputFileRef
            )
        } else {
            Thread {
                try {
                    var workingConfig = config

                    // 1) Pre-transcode HEVC 10-bit clips (if needed).
                    if (needsPreTranscode) {
                        Log.d(RENDER_TAG, "Pre-transcoding HEVC 10-bit videos...")
                        val inputPaths = workingConfig.videoClips.map { it.inputPath }
                        val transcodeMap = VideoTranscoder.transcodeClipsIfNeeded(
                            context, inputPaths
                        )
                        transcodedFiles = transcodeMap.values
                            .filter { it.contains("transcoded_") }
                        if (transcodedFiles.isNotEmpty()) {
                            Log.i(
                                RENDER_TAG,
                                "Pre-transcoded ${transcodedFiles.size} HEVC 10-bit videos to H.264"
                            )
                        }
                        val updatedClips = workingConfig.videoClips.map { clip ->
                            val newPath = transcodeMap[clip.inputPath] ?: clip.inputPath
                            if (newPath != clip.inputPath) {
                                clip.copy(inputPath = newPath)
                            } else clip
                        }
                        workingConfig = workingConfig.copy(videoClips = updatedClips)
                    }

                    // 2) Pre-render reversed clips into single forward MP4 temp files.
                    if (needsPreReverse && !shouldStopPolling.get()) {
                        Log.d(
                            RENDER_TAG,
                            "Pre-rendering reversed segments (" +
                                    "${workingConfig.videoClips.count { it.reverseVideo }} clip(s))"
                        )
                        val reversedPaths = mutableListOf<String>()
                        val reversedClips = preReverseClips(
                            workingConfig.videoClips,
                            enableAudio = workingConfig.enableAudio,
                            shouldStop = shouldStopPolling,
                            collectPath = { reversedPaths.add(it) },
                            onProgress = { f -> reverseProgress(f.toDouble()) },
                        )
                        reversedFiles = reversedPaths
                        workingConfig = workingConfig.copy(videoClips = reversedClips)
                        // Make sure the bar fully fills the reverse share before
                        // the transformer phase starts.
                        reverseProgress(1.0)
                    }

                    // 3) Pre-render overlap transitions (dissolve/slide/push/wipe)
                    //    into short blended clips spliced between the neighbours.
                    if (needsPreTransitions && !shouldStopPolling.get()) {
                        Log.d(RENDER_TAG, "Pre-rendering overlap clip transitions")
                        val paths = mutableListOf<String>()
                        val transitionedClips = preRenderTransitions(
                            workingConfig.videoClips,
                            enableAudio = workingConfig.enableAudio,
                            shouldStop = shouldStopPolling,
                            collectPath = { paths.add(it) },
                            onProgress = { f -> transitionProgress(f.toDouble()) },
                        )
                        transitionFiles = paths
                        workingConfig = workingConfig.copy(videoClips = transitionedClips)
                        transitionProgress(1.0)
                    }

                    val finalConfig = workingConfig
                    mainHandler.post {
                        if (shouldStopPolling.get()) {
                            cleanupAllPreFiles()
                            return@post
                        }
                        renderInternal(
                            config = finalConfig,
                            onProgress = transformProgress,
                            onComplete = { result ->
                                cleanupAllPreFiles()
                                onComplete(result)
                            },
                            onError = { error ->
                                cleanupAllPreFiles()
                                onError(error)
                            },
                            shouldStopPolling = shouldStopPolling,
                            mainHandler = mainHandler,
                            transformerRef = transformerRef,
                            outputFileRef = outputFileRef
                        )
                    }
                } catch (e: Exception) {
                    mainHandler.post {
                        cleanupAllPreFiles()
                        onError(e)
                    }
                }
            }.start()
        }

        // Return cancellation handle
        return RenderJobHandle {
            shouldStopPolling.set(true)
            mainHandler.removeCallbacksAndMessages(null)
            transformerRef.get()?.cancel()
            VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
            VideoReverser.cleanupReversedFiles(reversedFiles)
            ClipTransitionRenderer.cleanupFiles(transitionFiles)
            if (config.outputPath == null) {
                outputFileRef.get()?.delete()
            }
        }
    }

    /**
     * Pre-renders all clips with `reverseVideo == true` into single forward
     * MP4 temp files using [VideoReverser], and returns the rewritten clip
     * list. Forward clips pass through unchanged.
     */
    private fun preReverseClips(
        clips: List<VideoClip>,
        enableAudio: Boolean,
        shouldStop: AtomicBoolean,
        collectPath: (String) -> Unit,
        onProgress: (Float) -> Unit,
    ): List<VideoClip> {
        val reversedClipIndices = clips.withIndex()
            .filter { it.value.reverseVideo }
            .map { it.index }
        if (reversedClipIndices.isEmpty()) return clips
        val totalReversed = reversedClipIndices.size
        val result = clips.toMutableList()
        reversedClipIndices.forEachIndexed { progressIdx, clipIdx ->
            if (shouldStop.get()) return result
            val clip = clips[clipIdx]
            val startUs = clip.startUs ?: 0L
            val endUs = clip.endUs
                ?: ch.waio.pro_video_editor.src.features.render.helpers
                    .MediaInfoExtractor.getVideoDuration(clip.inputPath)
            try {
                val reversed = VideoReverser.reverseSync(
                    context = context,
                    inputPath = clip.inputPath,
                    segmentStartUs = startUs,
                    segmentEndUs = endUs,
                    includeAudio = enableAudio && (clip.volume ?: 1.0f) > 0f,
                    onProgress = { clipFraction ->
                        // Map per-clip progress into the overall reverse phase.
                        val overall = (progressIdx + clipFraction) / totalReversed
                        onProgress(overall.coerceIn(0f, 1f))
                    },
                )
                collectPath(reversed.outputPath)
                result[clipIdx] = clip.copy(
                    inputPath = reversed.outputPath,
                    startUs = 0L,
                    endUs = reversed.durationUs.takeIf { it > 0 },
                    reverseVideo = false,
                )
            } catch (e: Exception) {
                Log.e(
                    RENDER_TAG,
                    "Reverse pre-render failed for ${clip.inputPath}: ${e.message}. " +
                            "Falling back to forward playback."
                )
                result[clipIdx] = clip.copy(reverseVideo = false)
            }
        }
        return result
    }

    /**
     * Pre-renders overlap transitions (dissolve/slide/push/wipe) into short
     * blended MP4 clips and rewrites the clip list so the main pipeline sees
     * plain forward clips:
     *
     * For a transition between clip *i* and *i+1*, [ClipTransitionGeometry]
     * resolves the blend in OUTPUT (post-speed) time: clip *i* is shortened by
     * `output * speed_i` of source, the blended clip (output duration) is
     * inserted, and clip *i+1*'s head is trimmed by `output * speed_{i+1}` of
     * source. The blend itself is rendered at the requested speed for each side,
     * so footage inside the transition plays at the same speed as the rest of
     * the clip. If a transition cannot be rendered (e.g. dimension mismatch or
     * not enough content) it degrades to a hard cut.
     */
    private fun preRenderTransitions(
        clips: List<VideoClip>,
        enableAudio: Boolean,
        shouldStop: AtomicBoolean,
        collectPath: (String) -> Unit,
        onProgress: (Float) -> Unit,
    ): List<VideoClip> {
        // An overlap transition on the last/only clip loops back into the first
        // clip (seamless loop). Captured before the between-clip pass clears it.
        val wrapTransition = clips.lastOrNull()?.transition?.takeIf {
            it.isOverlap && !clips.last().reverseVideo && !clips.first().reverseVideo
        }
        val betweenCount = if (clips.size >= 2) {
            (0 until clips.size - 1).count { clips[it].transition?.isOverlap == true }
        } else 0
        val total = betweenCount + (if (wrapTransition != null) 1 else 0)
        if (total == 0) return clips

        val work = clips.toMutableList()
        val result = mutableListOf<VideoClip>()
        var doneCount = 0
        var i = 0

        while (i < work.size) {
            val current = work[i]
            val next = work.getOrNull(i + 1)
            val transition = current.transition

            val canOverlap = next != null && transition != null && transition.isOverlap &&
                    !current.reverseVideo && !next.reverseVideo

            if (shouldStop.get() || !canOverlap) {
                // Clear an overlap transition so it is not reinterpreted later.
                result.add(if (transition?.isOverlap == true) current.copy(transition = null) else current)
                i++
                continue
            }

            val curStart = current.startUs ?: 0L
            val curEnd = current.endUs ?: MediaInfoExtractor.getVideoDuration(current.inputPath)
            val nextStart = next!!.startUs ?: 0L
            val nextEnd = next.endUs ?: MediaInfoExtractor.getVideoDuration(next.inputPath)
            val curDur = curEnd - curStart
            val nextDur = nextEnd - nextStart

            // Resolve the overlap geometry in OUTPUT (post-speed) time so the
            // requested transition duration matches the non-transition timeline
            // and each side consumes `output * speed` of its own source.
            val plan = ClipTransitionGeometry.planOverlap(
                outgoingSourceDurationUs = curDur,
                incomingSourceDurationUs = nextDur,
                transitionDurationUs = transition!!.durationUs,
                outgoingSpeed = current.playbackSpeed,
                incomingSpeed = next.playbackSpeed,
            )

            if (plan == null) {
                Log.w(RENDER_TAG, "Transition: not enough content for boundary $i, hard cut")
                result.add(current.copy(transition = null))
                doneCount++
                onProgress((doneCount.toFloat() / total).coerceIn(0f, 1f))
                i++
                continue
            }

            val tailSrc = plan.outgoingTailSourceUs
            val headSrc = plan.incomingHeadSourceUs

            val rendered = ClipTransitionRenderer.renderSync(
                context = context,
                outgoingPath = current.inputPath,
                outTailStartUs = curEnd - tailSrc,
                outTailEndUs = curEnd,
                incomingPath = next.inputPath,
                inHeadStartUs = nextStart,
                inHeadEndUs = nextStart + headSrc,
                outputDurationUs = plan.outputDurationUs,
                type = transition.type,
                direction = transition.direction,
                curve = transition.curve,
                includeAudio = enableAudio &&
                        (current.volume ?: 1.0f) > 0f && (next.volume ?: 1.0f) > 0f,
                onProgress = { f ->
                    onProgress(((doneCount + f) / total).coerceIn(0f, 1f))
                },
            )

            if (rendered != null) {
                collectPath(rendered.outputPath)
                // Keep the outgoing clip's speed; it now ends `tailSrc` of source
                // earlier (those frames moved into the speed-adjusted blend).
                result.add(current.copy(endUs = curEnd - tailSrc, transition = null))
                result.add(
                    VideoClip(
                        inputPath = rendered.outputPath,
                        startUs = 0L,
                        endUs = rendered.durationUs.takeIf { it > 0 },
                    )
                )
                // Trim the incoming head in place; it keeps its own speed/transition.
                work[i + 1] = next.copy(startUs = nextStart + headSrc)
            } else {
                Log.w(RENDER_TAG, "Transition render failed for boundary $i, hard cut")
                result.add(current.copy(transition = null))
            }

            doneCount++
            onProgress((doneCount.toFloat() / total).coerceIn(0f, 1f))
            i++
        }

        // Wrap pass: render the last clip's tail dissolving into the first
        // clip's head and append it, so any looping player restarts seamlessly.
        // Overlap transitions between clips already rewrote `result`, so its
        // first/last entries are the original first/last clips (blends only ever
        // sit between them).
        if (wrapTransition != null && !shouldStop.get() && result.isNotEmpty()) {
            val lastIdx = result.size - 1
            val first = result[0]
            val last = result[lastIdx]
            val singleClip = lastIdx == 0

            val firstStart = first.startUs ?: 0L
            val firstEnd = first.endUs ?: MediaInfoExtractor.getVideoDuration(first.inputPath)
            val lastStart = last.startUs ?: 0L
            val lastEnd = last.endUs ?: MediaInfoExtractor.getVideoDuration(last.inputPath)

            // Single-clip loops carve the head and tail from the same source, so
            // they need the stricter head+tail<L guard; multi-clip loops keep two
            // independent sources and reuse the ordinary overlap geometry.
            val plan = if (singleClip) {
                ClipTransitionGeometry.planWrap(
                    sourceDurationUs = lastEnd - lastStart,
                    transitionDurationUs = wrapTransition.durationUs,
                    speed = last.playbackSpeed,
                )
            } else {
                ClipTransitionGeometry.planOverlap(
                    outgoingSourceDurationUs = lastEnd - lastStart,
                    incomingSourceDurationUs = firstEnd - firstStart,
                    transitionDurationUs = wrapTransition.durationUs,
                    outgoingSpeed = last.playbackSpeed,
                    incomingSpeed = first.playbackSpeed,
                )
            }

            if (plan == null) {
                Log.w(RENDER_TAG, "Loop wrap: not enough content, seamless loop skipped")
            } else {
                val tailSrc = plan.outgoingTailSourceUs
                val headSrc = plan.incomingHeadSourceUs
                val rendered = ClipTransitionRenderer.renderSync(
                    context = context,
                    outgoingPath = last.inputPath,
                    outTailStartUs = lastEnd - tailSrc,
                    outTailEndUs = lastEnd,
                    incomingPath = first.inputPath,
                    inHeadStartUs = firstStart,
                    inHeadEndUs = firstStart + headSrc,
                    outputDurationUs = plan.outputDurationUs,
                    type = wrapTransition.type,
                    direction = wrapTransition.direction,
                    curve = wrapTransition.curve,
                    includeAudio = enableAudio &&
                            (last.volume ?: 1.0f) > 0f && (first.volume ?: 1.0f) > 0f,
                    onProgress = { f ->
                        onProgress(((doneCount + f) / total).coerceIn(0f, 1f))
                    },
                )
                if (rendered != null) {
                    collectPath(rendered.outputPath)
                    if (singleClip) {
                        // Trim both ends of the one clip; the carved head/tail
                        // moved into the appended blend.
                        result[0] = first.copy(
                            startUs = firstStart + headSrc,
                            endUs = lastEnd - tailSrc,
                        )
                    } else {
                        result[0] = first.copy(startUs = firstStart + headSrc)
                        result[lastIdx] = last.copy(endUs = lastEnd - tailSrc)
                    }
                    result.add(
                        VideoClip(
                            inputPath = rendered.outputPath,
                            startUs = 0L,
                            endUs = rendered.durationUs.takeIf { it > 0 },
                        )
                    )
                } else {
                    Log.w(RENDER_TAG, "Loop wrap render failed, seamless loop skipped")
                }
            }
            doneCount++
            onProgress((doneCount.toFloat() / total).coerceIn(0f, 1f))
        }

        return result
    }

    /**
     * Internal render implementation after optional pre-transcoding.
     */
    private fun renderInternal(
        config: RenderConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit,
        shouldStopPolling: AtomicBoolean,
        mainHandler: Handler,
        transformerRef: AtomicReference<Transformer?>,
        outputFileRef: AtomicReference<File?>
    ) {
        // Determine output file location
        val outputFile =
            if (config.outputPath != null) {
                File(config.outputPath)
            } else {
                File(
                    context.cacheDir,
                    // A UUID keeps concurrent renders from colliding on the same
                    // millisecond timestamp.
                    "video_output_${System.currentTimeMillis()}_" +
                        "${java.util.UUID.randomUUID()}.${config.outputFormat}"
                )
            }
        outputFileRef.set(outputFile)

        // Process effects from configuration
        val (videoEffects, audioEffects) = effectsProcessor.process(config)

        val outputMimeType = mapFormatToMimeType(config.outputFormat)
        // Resilient factory tries Media3's fast default first (operating-rate =
        // MAX, so working devices keep their speed) and only retries through a
        // fallback chain (capped operating-rate → unset → Main/Baseline profile
        // → software encoder as the slow last resort) when the encoder rejects
        // it — the cause of the codec exception on many Qualcomm c2 encoders. It
        // also keeps Media3's own per-encoder fallback for bitrate/profile/level
        // adjustments.
        val encoderFactory = ResilientVideoEncoderFactory(
            context = context,
            mimeType = outputMimeType,
            bitrate = config.bitrate,
            forceVideoEncoding = shouldForceVideoEncodeForBitrateCap(config),
        )

        // Declare transformer before listener to make it accessible
        lateinit var transformer: Transformer

        // Check if we need custom audio mixing with volume control
        val hasCustomAudio = config.audioTracks.isNotEmpty()

        // Determine if video audio will be present in the mix
        // Video audio is removed when audio is disabled or all clips have volume 0
        val videoAudioPresent = config.enableAudio && (
                config.videoClips.any { (it.volume ?: 1.0f) > 0.0f } ||
                        config.composition?.layers?.any { layer ->
                            layer.clips.any { (it.volume ?: 1.0f) > 0.0f }
                        } == true
                )

        // Build transformer with callbacks
        val transformerBuilder = Transformer.Builder(context)
            .setEncoderFactory(encoderFactory)
            .setVideoMimeType(outputMimeType)

        // Configure muxer for streaming optimization (moov atom placement)
        // true = moov at start (streamable), false = moov at end (smaller file)
        val muxerFactory = ConfigurableInAppMp4Muxer.Factory(
            attemptStreamableOutput = config.shouldOptimizeForNetworkUse
        )
        transformerBuilder.setMuxerFactory(muxerFactory)

        // Use custom audio mixer ONLY when mixing video audio with custom audio tracks
        // For video-only volume adjustment, VolumeAudioProcessor is used per-clip instead
        // (AudioProcessors don't work with parallel sequences, but work fine with single sequence)
        if (hasCustomAudio) {
            val trackVolumes = config.audioTracks.map { it.volume }
            transformerBuilder.setAudioMixerFactory(
                VolumeControlAudioMixerFactory(
                    trackVolumes = trackVolumes,
                    videoAudioPresent = videoAudioPresent
                )
            )
        }

        transformer = transformerBuilder
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
                    shouldStopPolling.set(true)
                    // Ensure 100% progress is always reported before completion
                    onProgress(1.0)
                    try {
                        if (config.outputPath != null) {
                            // Output saved to file, return null
                            onComplete(null)
                        } else {
                            // Read temporary file and return bytes
                            val resultBytes = outputFile.readBytes()
                            onComplete(resultBytes)
                        }
                    } catch (e: Exception) {
                        onError(e)
                    } finally {
                        mainHandler.removeCallbacksAndMessages(null)
                        if (config.outputPath == null) outputFile.delete()
                    }
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException
                ) {
                    shouldStopPolling.set(true)
                    onError(mapExportException(exception))
                    if (config.outputPath == null) outputFile.delete()
                }
            })
            .build()
        transformerRef.set(transformer)

        // Create composition (now fast - no manual audio mixing needed, Media3 handles it natively)
        Thread {
            try {
                val compositionResult = applyComposition(
                    context = context,
                    config = config,
                    videoEffects = videoEffects,
                    audioEffects = audioEffects
                )

                mainHandler.post {
                    if (compositionResult != null) {
                        val composition = compositionResult.composition
                        val audioTempFiles = compositionResult.temporaryFiles

                        transformer.addListener(object : Transformer.Listener {
                            override fun onCompleted(
                                composition: Composition,
                                result: ExportResult
                            ) {
                                cleanupAudioTempFiles(audioTempFiles)
                            }

                            override fun onError(
                                composition: Composition,
                                result: ExportResult,
                                exception: ExportException
                            ) {
                                cleanupAudioTempFiles(audioTempFiles)
                            }
                        })

                        transformer.start(composition, outputFile.absolutePath)

                        // Start progress tracking loop
                        val progressHolder = ProgressHolder()
                        mainHandler.post(object : Runnable {
                            override fun run() {
                                if (shouldStopPolling.get()) return

                                val progressState = transformer.getProgress(progressHolder)
                                if (progressHolder.progress >= 0) {
                                    onProgress(progressHolder.progress / 100.0)
                                }

                                // Continue polling if transformation is active
                                if (!shouldStopPolling.get() && progressState != Transformer.PROGRESS_STATE_NOT_STARTED) {
                                    mainHandler.postDelayed(this, 200)
                                }
                            }
                        })
                    } else {
                        onError(IllegalStateException("Failed to create composition"))
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    onError(e)
                }
            }
        }.start()
    }

    /**
     * Decides whether the requested bitrate cap forces the video track through
     * the encoder (see [BitrateCapPolicy]).
     *
     * Called with the final (post pre-transcode/reverse/transition) config, so
     * the probed files are exactly what the transformer will read. Sources
     * already within cap × tolerance keep Media3's lossless transmux fast
     * path; anything over budget — or unprobeable — is re-encoded so
     * [ResilientVideoEncoderFactory] actually applies the bitrate.
     */
    private fun shouldForceVideoEncodeForBitrateCap(config: RenderConfig): Boolean {
        val cap = config.bitrate ?: return false
        val clipPaths = buildList {
            config.videoClips.forEach { add(it.inputPath) }
            config.composition?.layers?.forEach { layer ->
                layer.clips.forEach { add(it.inputPath) }
            }
        }.distinct()
        if (clipPaths.isEmpty()) return false

        val sourceBitrates = clipPaths.map { MediaInfoExtractor.getVideoBitrate(it) }
        val forceEncode = BitrateCapPolicy.shouldForceEncode(cap, sourceBitrates)
        Log.i(
            RENDER_TAG,
            "Bitrate cap ${cap / 1000} kbps: source bitrate(s) " +
                    sourceBitrates.joinToString { "${(it ?: -1) / 1000} kbps" } +
                    if (forceEncode) {
                        " exceed cap × ${BitrateCapPolicy.TOLERANCE} — forcing video re-encode"
                    } else {
                        " within cap × ${BitrateCapPolicy.TOLERANCE} — transmux fast path allowed"
                    }
        )
        return forceEncode
    }

    /**
     * Translates a Media3 [ExportException] into a more specific, descriptive
     * error where possible.
     *
     * Encoder configuration failures (which survive the
     * [ResilientVideoEncoderFactory] fallback chain) are wrapped in a typed
     * [VideoEncoderConfigurationException] so the Flutter layer can show a
     * proper "encoder/format not supported" error state instead of a generic
     * render failure. All other failures are passed through unchanged.
     */
    private fun mapExportException(exception: ExportException): Throwable {
        return when (exception.errorCode) {
            ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
            ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED ->
                VideoEncoderConfigurationException(
                    "The video encoder rejected the export configuration after " +
                            "exhausting all fallbacks (operating-rate cap/removal, " +
                            "software encoder, profile downgrade). " +
                            "Underlying error: ${exception.getErrorCodeName()} - " +
                            "${exception.message}",
                    exception
                )

            else -> exception
        }
    }

    /**
     * Deletes pre-rendered audio temp files (typically WAVs from
     * AudioPreRenderer) created while building the composition.
     */
    private fun cleanupAudioTempFiles(files: List<File>) {
        for (file in files) {
            try {
                if (file.exists()) {
                    val deleted = file.delete()
                    Log.d(
                        RENDER_TAG,
                        "Cleanup pre-rendered audio file: ${file.name}, deleted=$deleted"
                    )
                }
            } catch (e: Exception) {
                Log.w(
                    RENDER_TAG,
                    "Failed to delete pre-rendered audio file ${file.name}: ${e.message}"
                )
            }
        }
    }
}
