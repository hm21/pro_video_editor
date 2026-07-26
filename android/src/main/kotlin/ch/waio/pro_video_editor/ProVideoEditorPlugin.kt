package ch.waio.pro_video_editor

import android.os.Handler
import android.os.Looper
import ch.waio.pro_video_editor.src.features.audio.ExtractAudio
import ch.waio.pro_video_editor.src.features.audio.MergeAudio
import ch.waio.pro_video_editor.src.features.audio.NoAudioTrackException
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractConfig
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractTask
import ch.waio.pro_video_editor.src.features.audio.models.AudioMergeConfig
import ch.waio.pro_video_editor.src.features.metadata.Metadata
import ch.waio.pro_video_editor.src.features.metadata.models.MetadataConfig
import ch.waio.pro_video_editor.src.features.render.RenderVideo
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderTask
import ch.waio.pro_video_editor.src.features.render.models.VideoEncoderConfigurationException
import ch.waio.pro_video_editor.src.features.split.SplitVideo
import ch.waio.pro_video_editor.src.features.stopmotion.StopMotionGenerator
import ch.waio.pro_video_editor.src.features.stopmotion.models.StopMotionConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.features.thumbnail.ThumbnailGenerator
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailConfig
import ch.waio.pro_video_editor.src.features.waveform.WaveformGenerator
import ch.waio.pro_video_editor.src.features.waveform.models.WaveformConfig
import ch.waio.pro_video_editor.src.features.waveform.models.WaveformTask
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.util.concurrent.ConcurrentHashMap

/**
 * ProVideoEditorPlugin - Main Flutter plugin for advanced video editing capabilities.
 *
 * This plugin provides a comprehensive set of video processing features including:
 * - Video rendering with effects (rotation, flip, scale, color adjustments, blur)
 * - Video metadata extraction (dimensions, duration, bitrate, tags)
 * - Thumbnail generation (timestamp-based or keyframe extraction)
 * - Progress tracking via event channels
 * - Cancellable operations for all long-running tasks
 *
 * The plugin uses a feature-based architecture where each capability is handled
 * by a dedicated service class (RenderVideo, Metadata, ThumbnailGenerator).
 * All operations are asynchronous with callback-based APIs to prevent blocking
 * the Flutter UI thread.
 *
 * Communication protocol:
 * - Method channel: "pro_video_editor" for commands and responses
 * - Event channel: "pro_video_editor_progress" for progress updates
 */
class ProVideoEditorPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    /// Event channel for streaming native log entries back to Dart
    private lateinit var logChannel: EventChannel
    private var logSink: EventChannel.EventSink? = null

    private lateinit var renderVideo: RenderVideo
    private lateinit var splitVideo: SplitVideo
    private lateinit var stopMotionGenerator: StopMotionGenerator
    private lateinit var metadata: Metadata
    private lateinit var thumbnailGenerator: ThumbnailGenerator
    private lateinit var extractAudio: ExtractAudio
    private lateinit var mergeAudio: MergeAudio
    private lateinit var waveformGenerator: WaveformGenerator

    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeRenderTasks = ConcurrentHashMap<String, RenderTask>()
    private val activeAudioTasks = ConcurrentHashMap<String, AudioExtractTask>()
    private val activeWaveformTasks = ConcurrentHashMap<String, WaveformTask>()

    /// Event channel for streaming waveform chunks
    private lateinit var waveformStreamChannel: EventChannel
    private var waveformStreamSink: EventChannel.EventSink? = null

    /**
     * Called when the plugin is attached to a Flutter engine.
     *
     * Initializes all communication channels and service instances.
     * This is the entry point for plugin lifecycle management.
     *
     * @param flutterPluginBinding Binding providing access to application context and messenger
     */
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "pro_video_editor")
        eventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "pro_video_editor_progress")
        waveformStreamChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "pro_video_editor_waveform_stream")
        logChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "pro_video_editor_logs")

        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        waveformStreamChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                waveformStreamSink = events
            }

            override fun onCancel(arguments: Any?) {
                waveformStreamSink = null
            }
        })

        logChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                logSink = events
                Log.sink = { level, tag, message, throwable ->
                    postLog(level, tag, message, throwable)
                }
            }

            override fun onCancel(arguments: Any?) {
                Log.sink = null
                logSink = null
            }
        })

        renderVideo = RenderVideo(flutterPluginBinding.applicationContext)
        splitVideo = SplitVideo(flutterPluginBinding.applicationContext)
        stopMotionGenerator = StopMotionGenerator(flutterPluginBinding.applicationContext)
        metadata = Metadata(flutterPluginBinding.applicationContext)
        thumbnailGenerator = ThumbnailGenerator(flutterPluginBinding.applicationContext)
        extractAudio = ExtractAudio(flutterPluginBinding.applicationContext)
        mergeAudio = MergeAudio(flutterPluginBinding.applicationContext)
        waveformGenerator = WaveformGenerator(flutterPluginBinding.applicationContext)
    }

    /**
     * Called when the plugin is detached from the Flutter engine.
     *
     * Cleans up all communication channels to prevent memory leaks.
     * Active render tasks are not automatically canceled.
     *
     * @param binding Binding information for cleanup
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        waveformStreamChannel.setStreamHandler(null)
        logChannel.setStreamHandler(null)
        Log.sink = null
        logSink = null
    }

    /**
     * Routes incoming method calls to appropriate handlers.
     *
     * Available methods:
     * - getPlatformVersion: Returns Android version
     * - getMetadata: Extracts video metadata
     * - getThumbnails: Generates thumbnails
     * - renderVideo: Renders video with effects
     * - extractAudio: Extracts audio from video
     * - getWaveform: Generates complete waveform data
     * - startWaveformStream: Starts streaming waveform generation
     * - cancelTask: Cancels active render or audio extraction task
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        applyInlineNativeLogLevel(call)

        when (call.method) {
            "getPlatformVersion" -> handleGetPlatformVersion(result)
            "getMetadata" -> handleGetMetadata(call, result)
            "hasAudioTrack" -> handleHasAudioTrack(call, result)
            "getThumbnails" -> handleGetThumbnails(call, result)
            "renderVideo" -> handleRenderVideo(call, result)
            "renderStopMotion" -> handleRenderStopMotion(call, result)
            "splitVideo" -> handleSplitVideo(call, result)
            "extractAudio" -> handleExtractAudio(call, result)
            "mergeAudio" -> handleMergeAudio(call, result)
            "getWaveform" -> handleGetWaveform(call, result)
            "startWaveformStream" -> handleStartWaveformStream(call, result)
            "cancelTask" -> handleCancelTask(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Applies an optional inline native log level from method call arguments.
     */
    private fun applyInlineNativeLogLevel(call: MethodCall) {
        val level = call.argument<String>("nativeLogLevel")
        if (level.isNullOrBlank()) {
            return
        }

        try {
            Log.setMinimumLevel(level)
        } catch (e: IllegalArgumentException) {
            Log.w(
                "ProVideoEditorPlugin",
                "Ignoring invalid nativeLogLevel '$level': ${e.message}"
            )
        }
    }

    /**
     * Returns the Android platform version string.
     */
    private fun handleGetPlatformVersion(result: MethodChannel.Result) {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
    }

    /**
     * Extracts metadata from a video file asynchronously.
     *
     * Retrieves technical properties (duration, dimensions, bitrate)
     * and descriptive tags (title, artist, album, etc.).
     */
    private fun handleGetMetadata(call: MethodCall, result: MethodChannel.Result) {
        try {
            val config = MetadataConfig.fromMethodCall(call)
            metadata.getMetadata(
                config = config,
                onComplete = { meta ->
                    mainHandler.post {
                        result.success(meta)
                    }
                },
                onError = { error ->
                    mainHandler.post {
                        result.error("METADATA_ERROR", error.message, null)
                    }
                }
            )
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_ARGUMENTS", e.message, null)
        }
    }

    /**
     * Checks if a video file has an audio track.
     *
     * Quickly inspects the video to determine if it contains at least one audio track.
     * This is useful to check before attempting audio extraction operations.
     */
    private fun handleHasAudioTrack(call: MethodCall, result: MethodChannel.Result) {
        try {
            val config = MetadataConfig.fromMethodCall(call)
            metadata.hasAudioTrack(
                config = config,
                onComplete = { hasAudio ->
                    mainHandler.post {
                        result.success(hasAudio)
                    }
                },
                onError = { error ->
                    mainHandler.post {
                        result.error("AUDIO_CHECK_ERROR", error.message, null)
                    }
                }
            )
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_ARGUMENTS", e.message, null)
        }
    }

    /**
     * Generates thumbnail images from a video asynchronously.
     *
     * Supports timestamp-based or keyframe-based extraction.
     * Thumbnails are generated in parallel for optimal performance.
     */
    private fun handleGetThumbnails(call: MethodCall, result: MethodChannel.Result) {
        try {
            val config = ThumbnailConfig.fromMethodCall(call)
            postProgress(config.id, 0.0)

            thumbnailGenerator.getThumbnails(
                config = config,
                onProgress = { progress -> postProgress(config.id, progress) },
                onComplete = { thumbnails ->
                    mainHandler.post {
                        postProgress(config.id, 1.0)
                        result.success(thumbnails)
                    }
                },
                onError = { error ->
                    mainHandler.post {
                        result.error("THUMBNAIL_ERROR", error.message, null)
                    }
                }
            )
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_ARGUMENTS", e.message, null)
        }
    }

    /**
     * Starts an asynchronous video render job with effects.
     *
     * Handles video concatenation, visual effects (rotation, flip,
     * scale, color, blur), audio processing, and output configuration.
     * Each job is tracked by unique ID and can be canceled.
     */
    private fun handleRenderVideo(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeRenderTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_EXISTS",
                "A render task with id '$id' is already active",
                null
            )
            return
        }

        postProgress(id, 0.0)

        val task = RenderTask(job = null, result = result)
        activeRenderTasks[id] = task

        try {
            val renderConfig = RenderConfig.fromMethodCall(call)

            val jobHandle = renderVideo.render(
                config = renderConfig,
                onProgress = { progress -> postProgress(id, progress) },
                onComplete = { resultBytes ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        val removedTask = activeRenderTasks.remove(id)
                        removedTask?.sendSuccess(resultBytes)
                    }
                },
                onError = { error ->
                    Log.e(
                        "RenderVideo",
                        "Error rendering video: ${error::class.java.name}: " +
                            "${error.message}",
                        error
                    )
                    mainHandler.post {
                        val removedTask = activeRenderTasks.remove(id)
                        val code = when {
                            removedTask?.canceled?.get() == true -> "CANCELED"
                            // Transient codec-resource pressure gets its own
                            // code: unlike ENCODER_NOT_SUPPORTED it is worth
                            // retrying once codec sessions free up.
                            error is VideoEncoderConfigurationException ->
                                if (error.isTransient) {
                                    "ENCODER_RESOURCE_EXHAUSTED"
                                } else {
                                    "ENCODER_NOT_SUPPORTED"
                                }

                            else -> "RENDER_ERROR"
                        }
                        val message = error.message
                            ?: "${error::class.java.simpleName} (no message)"
                        removedTask?.sendError(code, message)
                    }
                }
            )

            task.job = jobHandle
            if (task.canceled.get()) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeRenderTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeRenderTasks.remove(id)
            result.error("RENDER_ERROR", "Failed to start render: ${e.message}", null)
        }
    }

    /**
     * Starts an asynchronous stop-motion render job.
     *
     * Encodes a sequence of still images into a single (silent) video.
     * Reuses the same task tracking as [handleRenderVideo] so [handleCancelTask]
     * works unchanged.
     */
    private fun handleRenderStopMotion(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeRenderTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_EXISTS",
                "A render task with id '$id' is already active",
                null
            )
            return
        }

        postProgress(id, 0.0)

        val task = RenderTask(job = null, result = result)
        activeRenderTasks[id] = task

        try {
            val config = StopMotionConfig.fromMethodCall(call)

            val jobHandle = stopMotionGenerator.render(
                config = config,
                onProgress = { progress -> postProgress(id, progress) },
                onComplete = { resultBytes ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        val removedTask = activeRenderTasks.remove(id)
                        removedTask?.sendSuccess(resultBytes)
                    }
                },
                onError = { error ->
                    Log.e("StopMotion", "Error rendering stop-motion: ${error.message}")
                    mainHandler.post {
                        val removedTask = activeRenderTasks.remove(id)
                        val code = if (removedTask?.canceled?.get() == true) {
                            "CANCELED"
                        } else {
                            "RENDER_ERROR"
                        }
                        removedTask?.sendError(code, error.message)
                    }
                }
            )

            task.job = jobHandle
            if (task.canceled.get()) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeRenderTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeRenderTasks.remove(id)
            result.error("RENDER_ERROR", "Failed to start stop-motion render: ${e.message}", null)
        }
    }

    /**
     * Splits a single video into two files at a frame-accurate position.
     *
     * Re-encodes each half from the exact split frame (no compositor/effects).
     * Tracked by unique ID via the same render-task map so [handleCancelTask]
     * works unchanged. Returns the two output paths on success.
     */
    private fun handleSplitVideo(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeRenderTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_EXISTS",
                "A render task with id '$id' is already active",
                null
            )
            return
        }

        val inputPath = call.argument<String>("inputPath")
        val startOutputPath = call.argument<String>("startOutputPath")
        val endOutputPath = call.argument<String>("endOutputPath")
        val splitUs = (call.argument<Number>("splitUs"))?.toLong()
        if (inputPath == null || startOutputPath == null ||
            endOutputPath == null || splitUs == null
        ) {
            result.error("INVALID_ARGUMENTS", "Missing parameters", null)
            return
        }

        val outputFormat = call.argument<String>("outputFormat") ?: "mp4"
        val bitrate = call.argument<Number>("bitrate")?.toInt()
        val enableAudio = call.argument<Boolean>("enableAudio") ?: true
        val exportTimeoutMs = call.argument<Number>("exportTimeoutMs")?.toLong()
            ?: SplitVideo.DEFAULT_EXPORT_TIMEOUT_MS
        val stallTimeoutMs = call.argument<Number>("stallTimeoutMs")?.toLong()
            ?: SplitVideo.DEFAULT_STALL_TIMEOUT_MS

        postProgress(id, 0.0)

        val task = RenderTask(job = null, result = result)
        activeRenderTasks[id] = task

        try {
            val jobHandle = splitVideo.split(
                inputPath = inputPath,
                splitUs = splitUs,
                startOutputPath = startOutputPath,
                endOutputPath = endOutputPath,
                outputFormat = outputFormat,
                bitrate = bitrate,
                enableAudio = enableAudio,
                mainHandler = mainHandler,
                exportTimeoutMs = exportTimeoutMs,
                stallTimeoutMs = stallTimeoutMs,
                onProgress = { progress -> postProgress(id, progress) },
                onComplete = { outputPaths ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        val removedTask = activeRenderTasks.remove(id)
                        removedTask?.sendSuccess(outputPaths)
                    }
                },
                onError = { error ->
                    Log.e(
                        "SplitVideo",
                        "Error splitting video: ${error::class.java.name}: ${error.message}",
                        error
                    )
                    mainHandler.post {
                        val removedTask = activeRenderTasks.remove(id)
                        val code = when {
                            removedTask?.canceled?.get() == true -> "CANCELED"
                            error is java.util.concurrent.CancellationException -> "CANCELED"
                            else -> "SPLIT_ERROR"
                        }
                        val message = error.message
                            ?: "${error::class.java.simpleName} (no message)"
                        removedTask?.sendError(code, message)
                    }
                }
            )

            task.job = jobHandle
            if (task.canceled.get()) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeRenderTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeRenderTasks.remove(id)
            result.error("SPLIT_ERROR", "Failed to start split: ${e.message}", null)
        }
    }

    /**
     * Extracts audio from a video file asynchronously.
     *
     * Extracts the audio track and optionally trims it to
     * the specified time range. Each job is tracked by unique ID
     * and can be canceled.
     */
    private fun handleExtractAudio(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeAudioTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_EXISTS",
                "An audio extraction task with id '$id' is already active",
                null
            )
            return
        }

        postProgress(id, 0.0)

        val task = AudioExtractTask(job = null, result = result)
        activeAudioTasks[id] = task

        try {
            val config = AudioExtractConfig.fromMethodCall(call)

            val jobHandle = extractAudio.extract(
                config = config,
                onProgress = { progress -> postProgress(id, progress) },
                onComplete = { resultBytes ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        val removedTask = activeAudioTasks.remove(id)
                        removedTask?.sendSuccess(resultBytes)
                    }
                },
                onError = { error ->
                    Log.e("ExtractAudio", "Error extracting audio: ${error.message}")
                    mainHandler.post {
                        val removedTask = activeAudioTasks.remove(id)
                        val code = when {
                            removedTask?.canceled?.get() == true -> "CANCELED"
                            error is NoAudioTrackException -> "NO_AUDIO"
                            else -> "EXTRACT_ERROR"
                        }
                        removedTask?.sendError(code, error.message)
                    }
                }
            )

            task.job = jobHandle
            if (task.canceled.get()) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeAudioTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeAudioTasks.remove(id)
            result.error("EXTRACT_ERROR", "Failed to start audio extraction: ${e.message}", null)
        }
    }

    /**
     * Merges the audio of several trimmed clip windows into one file.
     *
     * Concatenates each segment's `[startTime, endTime)` window (after applying
     * its speed) into a single uniform-format audio file and returns an offset
     * map. Unlike [handleExtractAudio], a segment without an audio track
     * contributes silence instead of failing. Tracked by id and cancellable.
     */
    private fun handleMergeAudio(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeAudioTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_EXISTS",
                "An audio task with id '$id' is already active",
                null
            )
            return
        }

        postProgress(id, 0.0)

        val task = AudioExtractTask(job = null, result = result)
        activeAudioTasks[id] = task

        try {
            val config = AudioMergeConfig.fromMethodCall(call)

            val jobHandle = mergeAudio.merge(
                config = config,
                onProgress = { progress -> postProgress(id, progress) },
                onComplete = { resultMap ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        val removedTask = activeAudioTasks.remove(id)
                        removedTask?.sendValue(resultMap)
                    }
                },
                onError = { error ->
                    Log.e("MergeAudio", "Error merging audio: ${error.message}")
                    mainHandler.post {
                        val removedTask = activeAudioTasks.remove(id)
                        val code = if (removedTask?.canceled?.get() == true) "CANCELED" else "MERGE_ERROR"
                        removedTask?.sendError(code, error.message)
                    }
                }
            )

            task.job = jobHandle
            if (task.canceled.get()) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeAudioTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeAudioTasks.remove(id)
            result.error("MERGE_ERROR", "Failed to start audio merge: ${e.message}", null)
        }
    }

    /**
     * Generates waveform data from a video's audio track asynchronously.
     *
     * Decodes audio to PCM and computes peak amplitudes at the specified
     * resolution. Returns normalized float arrays for Flutter rendering.
     */
    private fun handleGetWaveform(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeWaveformTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_RUNNING",
                "A waveform generation task with id '$id' is already running",
                null
            )
            return
        }

        postProgress(id, 0.0)

        val task = WaveformTask(job = null, result = result)
        activeWaveformTasks[id] = task

        try {
            val config = WaveformConfig.fromMethodCall(call)

            val jobHandle = waveformGenerator.generate(
                config = config,
                onProgress = { progress ->
                    postProgress(id, progress)
                },
                onComplete = { waveformData ->
                    mainHandler.post {
                        postProgress(id, 1.0)
                        activeWaveformTasks.remove(id)
                        // Use the captured task: handleCancelTask may have already
                        // removed it from the map, so the map lookup can be null.
                        if (task.isCanceled) {
                            result.error("CANCELED", "Waveform generation was cancelled", null)
                        } else {
                            result.success(waveformData)
                        }
                    }
                },
                onError = { error ->
                    mainHandler.post {
                        activeWaveformTasks.remove(id)
                        val code = when {
                            task.isCanceled -> "CANCELED"
                            error is NoAudioTrackException -> "NO_AUDIO"
                            else -> "WAVEFORM_ERROR"
                        }
                        result.error(code, error.message, null)
                    }
                }
            )

            task.job = jobHandle
            if (task.isCanceled) {
                jobHandle.cancel()
            }
        } catch (e: IllegalArgumentException) {
            activeWaveformTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeWaveformTasks.remove(id)
            result.error(
                "WAVEFORM_ERROR",
                "Failed to start waveform generation: ${e.message}",
                null
            )
        }
    }

    /**
     * Starts streaming waveform generation.
     *
     * Unlike handleGetWaveform which waits for complete generation,
     * this method emits waveform chunks progressively via the waveformStreamChannel.
     */
    private fun handleStartWaveformStream(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        if (activeWaveformTasks.containsKey(id)) {
            result.error(
                "TASK_ALREADY_RUNNING",
                "A waveform generation task with id '$id' is already running",
                null
            )
            return
        }

        val task = WaveformTask(job = null, result = result)
        activeWaveformTasks[id] = task

        try {
            val config = WaveformConfig.fromMethodCall(call)

            val jobHandle = waveformGenerator.generate(
                config = config,
                onProgress = { _ ->
                    // Progress is included in chunks for streaming mode
                },
                onChunk = { chunkData ->
                    mainHandler.post {
                        waveformStreamSink?.success(chunkData)
                    }
                },
                onComplete = { _ ->
                    mainHandler.post {
                        activeWaveformTasks.remove(id)
                        // Don't call result.success for streaming - chunks are sent via event channel
                    }
                },
                onError = { error ->
                    mainHandler.post {
                        activeWaveformTasks.remove(id)
                        // Use the captured task: handleCancelTask may have already
                        // removed it from the map, so the map lookup can be null.
                        val code = when {
                            task.isCanceled -> "CANCELED"
                            error is NoAudioTrackException -> "NO_AUDIO"
                            else -> "WAVEFORM_ERROR"
                        }
                        // Send error via event channel
                        val errorData = mapOf(
                            "id" to id,
                            "error" to error.message,
                            "errorCode" to code
                        )
                        waveformStreamSink?.success(errorData)
                    }
                },
                streaming = true
            )

            task.job = jobHandle
            if (task.isCanceled) {
                jobHandle.cancel()
            }

            // Return immediately - chunks will be sent via event channel
            result.success(null)
        } catch (e: IllegalArgumentException) {
            activeWaveformTasks.remove(id)
            result.error("INVALID_ARGUMENTS", e.message, null)
        } catch (e: Exception) {
            activeWaveformTasks.remove(id)
            result.error(
                "WAVEFORM_ERROR",
                "Failed to start streaming waveform generation: ${e.message}",
                null
            )
        }
    }

    /**
     * Cancels an active render or audio extraction task by ID.
     *
     * Marks task as canceled, triggers cancellation handler
     * (stops transformer/extractor, cleans up files), and removes from tracking.
     */
    private fun handleCancelTask(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        if (id.isBlank()) {
            result.error("INVALID_ARGUMENTS", "Task id is required and cannot be empty", null)
            return
        }

        // Try to find task in render tasks
        val renderTask = activeRenderTasks[id]
        if (renderTask != null) {
            renderTask.canceled.set(true)
            renderTask.job?.cancel()
            activeRenderTasks.remove(id)
            // Send CANCELED error to complete the Dart render future
            renderTask.sendError("CANCELED", "Task was canceled")
            result.success(true)
            return
        }

        // Try to find task in audio tasks
        val audioTask = activeAudioTasks[id]
        if (audioTask != null) {
            audioTask.canceled.set(true)
            audioTask.job?.cancel()
            activeAudioTasks.remove(id)
            // Send CANCELED error to complete the Dart audio future
            audioTask.sendError("CANCELED", "Task was canceled")
            result.success(true)
            return
        }

        // Try to find task in waveform tasks
        val waveformTask = activeWaveformTasks[id]
        if (waveformTask != null) {
            waveformTask.cancel()
            activeWaveformTasks.remove(id)
            result.success(true)
            return
        }

        result.error("TASK_NOT_FOUND", "No active task found with id '$id'", null)
    }

    /**
     * Sends progress updates to Flutter via event channel.
     *
     * Progress events are sent on main thread with task ID
     * and progress value (0.0 to 1.0).
     */
    private fun postProgress(id: String, progress: Double) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "id" to id,
                    "progress" to progress
                )
            )
        }
    }

    /**
     * Forwards a native log entry to Flutter via the log event channel.
     *
     * Log events are sent on the main thread with level, tag, message,
     * timestamp, and an optional stack trace.
     */
    private fun postLog(level: String, tag: String, message: String, throwable: Throwable?) {
        val timestamp = System.currentTimeMillis()
        val stackTrace = throwable?.stackTraceToString()
        mainHandler.post {
            logSink?.success(
                mapOf(
                    "level" to level,
                    "tag" to tag,
                    "message" to message,
                    "timestamp" to timestamp,
                    "stackTrace" to stackTrace
                )
            )
        }
    }
}
