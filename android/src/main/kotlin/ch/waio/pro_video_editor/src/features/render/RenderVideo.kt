package ch.waio.pro_video_editor.src.features.render

import RENDER_TAG
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import applyBitrate
import mapFormatToMimeType
import ch.waio.pro_video_editor.src.features.render.helpers.applyComposition
import ch.waio.pro_video_editor.src.features.render.helpers.CompositionBuilder
import ch.waio.pro_video_editor.src.features.render.helpers.VolumeControlAudioMixerFactory
import ch.waio.pro_video_editor.src.features.render.helpers.ConfigurableInAppMp4Muxer
import ch.waio.pro_video_editor.src.features.render.helpers.MediaInfoExtractor
import ch.waio.pro_video_editor.src.features.render.helpers.VideoTranscoder
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderJobHandle
import ch.waio.pro_video_editor.src.features.render.models.VideoClip

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
     * 1. GPU effects are used with HEVC 10-bit HDR videos.
     * 2. Multiple videos are being merged and at least one is HEVC 10-bit
     *    (mixing different codecs in a composition can cause frame processing errors).
     * 3. Multi-channel audio (5.1/7.1) is detected AND more than one unmuted audio source
     *    is present (mixing multi-channel with stereo or silence causes mixer reconfiguration errors).
     */
    private fun needsPreTranscoding(config: RenderConfig): Boolean {
        // 1. Check for HEVC 10-bit / HDR compatibility with GPU effects
        if (hasGpuEffects(config)) {
            val hasAnyHevc10bit = config.videoClips.any { clip ->
                val info = MediaInfoExtractor.getVideoFormatInfo(clip.inputPath)
                info.isHevc && info.bitDepth == 10
            }
            if (hasAnyHevc10bit) {
                Log.d(RENDER_TAG, "HEVC 10-bit detected with GPU effects, pre-transcoding needed")
                return true
            }
        }

        // 2. Check for multi-channel audio mixing complexity
        val unmutedVideoClips = config.videoClips.filter { (it.volume ?: 1.0f) > 0.0f }
        val audibleCustomTracks = config.audioTracks.filter { it.volume > 0.0f }
        val totalAudibleSources = unmutedVideoClips.size + audibleCustomTracks.size

        val hasMultiChannel = config.videoClips.any { clip ->
            (MediaInfoExtractor.getAudioChannelCount(clip.inputPath) ?: 2) > 2
        }

        if (hasMultiChannel) {
            // We only MUST transcode multi-channel audio if it needs to be mixed with something else.
            // If it's the only source, Media3 can handle downmixing via AudioProcessors during render.
            if (totalAudibleSources > 1) {
                Log.d(RENDER_TAG, "Multi-channel audio detected with multiple sources, pre-transcoding for mixing safety")
                return true
            }
            
            // TODO having multiple video clips (even if muted), mixing/overlapping transitions
            //      can trigger audio reconfiguration errors if formats don't match perfectly
            if (config.videoClips.size > 1) {
                Log.d(RENDER_TAG, "Multi-channel audio detected in multi-clip merge, pre-transcoding for transition stability")
                return true
            }
        }

        // 3. Codec mixing check (H.264 + HEVC)
        // Mixing different codecs (HEVC + H.264) in a single sequence can cause frame processing errors
        if (config.videoClips.size > 1) {
            val hasAnyHevc10bit = config.videoClips.any { clip ->
                val info = MediaInfoExtractor.getVideoFormatInfo(clip.inputPath)
                info.isHevc && info.bitDepth == 10
            }
            if (hasAnyHevc10bit) {
                Log.d(RENDER_TAG, "HEVC 10-bit detected in merge, pre-transcoding to ensure consistency")
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
        val transformerRef = AtomicReference<Transformer?>(null)
        val outputFileRef = AtomicReference<File?>(null)

        // Check if we need to pre-transcode HEVC 10-bit videos
        val needsPreTranscode = needsPreTranscoding(config)

        if (needsPreTranscode) {
            Log.d(RENDER_TAG, "Pre-transcoding needed, checking for HEVC 10-bit videos...")

            // Pre-transcode in background thread
            Thread {
                try {
                    val inputPaths = config.videoClips.map { it.inputPath }
                    val transcodeMap = VideoTranscoder.transcodeClipsIfNeeded(context, inputPaths)

                    // Track transcoded files for cleanup
                    transcodedFiles = transcodeMap.values.filter {
                        it.contains("transcoded_")
                    }

                    if (transcodedFiles.isNotEmpty()) {
                        Log.i(
                            RENDER_TAG,
                            "Pre-transcoded ${transcodedFiles.size} HEVC 10-bit videos to H.264"
                        )
                    }

                    // Create new config with transcoded paths
                    val updatedClips = config.videoClips.map { clip ->
                        val newPath = transcodeMap[clip.inputPath] ?: clip.inputPath
                        if (newPath != clip.inputPath) {
                            // If transcoded, use the new path but preserve all other parameters
                            clip.copy(inputPath = newPath)
                        } else {
                            clip
                        }
                    }

                    val updatedConfig = config.copy(videoClips = updatedClips)

                    mainHandler.post {
                        if (!shouldStopPolling.get()) {
                            renderInternal(
                                config = updatedConfig,
                                onProgress = onProgress,
                                onComplete = { result ->
                                    // Cleanup transcoded files after render
                                    VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
                                    onComplete(result)
                                },
                                onError = { error ->
                                    // Cleanup transcoded files on error too
                                    VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
                                    onError(error)
                                },
                                shouldStopPolling = shouldStopPolling,
                                mainHandler = mainHandler,
                                transformerRef = transformerRef,
                                outputFileRef = outputFileRef
                            )
                        }
                    }
                } catch (e: Exception) {
                    mainHandler.post {
                        VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
                        onError(e)
                    }
                }
            }.start()
        } else {
            // No GPU effects, render directly
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
        }

        // Return cancellation handle
        return RenderJobHandle {
            shouldStopPolling.set(true)
            mainHandler.removeCallbacksAndMessages(null)
            transformerRef.get()?.cancel()
            VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
            if (config.outputPath == null) {
                outputFileRef.get()?.delete()
            }
        }
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
                    "video_output_${System.currentTimeMillis()}.${config.outputFormat}"
                )
            }
        outputFileRef.set(outputFile)

        // Process effects from configuration
        val (videoEffects, audioEffects) = effectsProcessor.process(config)

        val outputMimeType = mapFormatToMimeType(config.outputFormat)
        val encoderFactoryBuilder = DefaultEncoderFactory.Builder(context)

        applyBitrate(encoderFactoryBuilder, outputMimeType, config.bitrate)

        // Declare transformer before listener to make it accessible
        lateinit var transformer: Transformer

        // Check if we need custom audio mixing with volume control
        val hasCustomAudio = config.audioTracks.isNotEmpty()

        // Determine how many video sequences will contribute to the audio mix
        // A video sequence has audio if audio is enabled AND at least one clip has volume > 0
        val videoAudioSourceCount: Int
        val videoSequenceVolumes: List<Float>
        
        if (config.enableAudio) {
            val needsMultipleSequences = config.videoClips.any {
                it.x != null || it.y != null || it.width != null || it.height != null || 
                it.segmentTimeUs != null || it.opacity != null || (it.zIndex ?: 0) != 0
            }
            if (needsMultipleSequences) {
                // In Pip mode, each clip is a separate sequence. 
                // IMPORTANT: Match the exact layering logic from CompositionBuilder.
                // 1. Higher zIndex on top.
                // 2. Default zIndex is 0.
                // 3. If zIndex is same, latter segment in input list is on top.
                //
                // In Media3, the first sequence in the list is the bottom-most layer.
                // By using a stable ascending sort, we satisfy the rules.
                val sortedClips = config.videoClips.sortedByDescending { it.zIndex ?: 0 }
                val activeClips = sortedClips.filter { (it.volume ?: 1.0f) > 0.0f }
                videoAudioSourceCount = activeClips.size
                videoSequenceVolumes = activeClips.map { it.volume ?: 1.0f }
            } else {
                // Single sequence. Has audio if any clip is unmuted.
                val isUnmuted = config.videoClips.any { (it.volume ?: 1.0f) > 0.0f }
                videoAudioSourceCount = if (isUnmuted) 1 else 0
                videoSequenceVolumes = if (isUnmuted) listOf(1.0f) else emptyList()
            }
        } else {
            videoAudioSourceCount = 0
            videoSequenceVolumes = emptyList()
        }

        // Build transformer with callbacks
        val transformerBuilder = Transformer.Builder(context)
            .setEncoderFactory(encoderFactoryBuilder.build())
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
                    videoAudioSourceCount = videoAudioSourceCount,
                    videoSequenceVolumes = videoSequenceVolumes
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
                    onError(exception)
                    if (config.outputPath == null) outputFile.delete()
                }
            })
            .build()
        transformerRef.set(transformer)

        // Create composition (now fast - no manual audio mixing needed, Media3 handles it natively)
        Thread {
            try {
                val compositionBuilder = CompositionBuilder(config, context)
                val composition = compositionBuilder
                    .setVideoEffects(videoEffects)
                    .setAudioEffects(audioEffects)
                    .build()

                mainHandler.post {
                    if (composition != null) {
                        transformer.start(composition, outputFile.absolutePath)
                        
                        // Register release on transformer end
                        transformer.addListener(object : Transformer.Listener {
                            override fun onCompleted(c: Composition, r: ExportResult) {
                                compositionBuilder.release()
                            }
                            override fun onError(c: Composition, r: ExportResult, e: ExportException) {
                                compositionBuilder.release()
                            }
                        })

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
                        compositionBuilder.release()
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
}
