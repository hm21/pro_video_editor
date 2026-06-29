import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import FlutterMacOS
#endif

/// ProVideoEditorPlugin - Main Flutter plugin for advanced video editing capabilities.
///
/// This plugin provides a comprehensive set of video processing features including:
/// - Video rendering with effects (rotation, flip, scale, color adjustments, blur)
/// - Video metadata extraction (dimensions, duration, bitrate, tags)
/// - Thumbnail generation (timestamp-based or keyframe extraction)
/// - Progress tracking via event channels
/// - Cancellable operations for all long-running tasks
///
/// The plugin uses a feature-based architecture where each capability is handled
/// by a dedicated service class (RenderVideo, VideoMetadata, ThumbnailGenerator).
/// All operations are asynchronous with callback-based APIs to prevent blocking
/// the Flutter UI thread.
///
/// Communication protocol:
/// - Method channel: "pro_video_editor" for commands and responses
/// - Event channel: "pro_video_editor_progress" for progress updates
/// - Event channel: "pro_video_editor_waveform_stream" for streaming waveform chunks
public class ProVideoEditorPlugin: NSObject, FlutterPlugin {
  var eventSink: FlutterEventSink?
  var waveformStreamSink: FlutterEventSink?
  var logSink: FlutterEventSink?
  private var activeRenderTasks: [String: RenderTask] = [:]
  private var activeAudioTasks: [String: AudioExtractTask] = [:]
  private var activeWaveformTasks: [String: WaveformTask] = [:]

  /// Guards `engineDetached`. Metadata/thumbnail callbacks may complete off the
  /// main thread, so the detach flag is read/written under a lock.
  private let engineLock = NSLock()
  private var engineDetached = false

  /// Whether `tearDownForEngineDetach()` has run. Once true, every captured
  /// `FlutterResult` would message a no-longer-running engine, so asynchronous
  /// deliveries must become terminal no-ops.
  private var isEngineDetached: Bool {
    engineLock.lock()
    defer { engineLock.unlock() }
    return engineDetached
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif

    let methodChannel = FlutterMethodChannel(
      name: "pro_video_editor", binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(
      name: "pro_video_editor_progress", binaryMessenger: messenger)
    let waveformStreamChannel = FlutterEventChannel(
      name: "pro_video_editor_waveform_stream", binaryMessenger: messenger)
    let logChannel = FlutterEventChannel(
      name: "pro_video_editor_logs", binaryMessenger: messenger)

    let instance = ProVideoEditorPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    waveformStreamChannel.setStreamHandler(WaveformStreamHandler(plugin: instance))
    logChannel.setStreamHandler(LogStreamHandler(plugin: instance))

    // Publishing the instance keeps it alive for the registrar and ensures
    // `detachFromEngine(for:)` is invoked when the FlutterEngine is torn down.
    registrar.publish(instance)
  }

  /// Tears down all in-flight work when the FlutterEngine is detached.
  ///
  /// Invoked by the registrar on the platform/main thread during engine
  /// teardown (e.g. app termination or surface recreation). Cancels every
  /// active task and clears every event sink so already-dispatched callbacks
  /// no-op instead of messaging a messenger whose engine is no longer running,
  /// which would otherwise raise an
  /// `NSInternalInconsistencyException: Sending a message before the
  /// FlutterEngine has been run`.
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    tearDownForEngineDetach()
  }

  /// Performs the engine-detach teardown.
  ///
  /// Extracted from `detachFromEngine(for:)` so it can be exercised without a
  /// `FlutterPluginRegistrar`. Sets `engineDetached` first so any callback that
  /// races the teardown sees the flag and routes its delivery through
  /// `deliverResult(_:_:)` as a no-op, then cancels every active task and
  /// clears every event sink.
  func tearDownForEngineDetach() {
    engineLock.lock()
    engineDetached = true
    engineLock.unlock()

    activeRenderTasks.values.forEach { $0.cancel() }
    activeAudioTasks.values.forEach { $0.cancel() }
    activeWaveformTasks.values.forEach { $0.cancel() }
    activeRenderTasks.removeAll()
    activeAudioTasks.removeAll()
    activeWaveformTasks.removeAll()

    eventSink = nil
    waveformStreamSink = nil
    logSink = nil
    PluginLog.sink = nil
  }

  /// Delivers an asynchronous method-channel result.
  ///
  /// After engine detach the captured `FlutterResult` would message a
  /// not-running engine, raising `NSInternalInconsistencyException: Sending a
  /// message before the FlutterEngine has been run`. Delivery is a terminal
  /// no-op once detached.
  func deliverResult(_ result: FlutterResult, _ value: Any?) {
    guard !isEngineDetached else { return }
    result(value)
  }

  /// Routes incoming method calls to appropriate handlers.
  ///
  /// Available methods:
  /// - getPlatformVersion: Returns iOS version
  /// - getMetadata: Extracts video metadata
  /// - getThumbnails: Generates thumbnails
  /// - renderVideo: Renders video with effects
  /// - extractAudio: Extracts audio from video
  /// - cancelTask: Cancels active render or audio extraction task
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    applyInlineNativeLogLevel(call: call)

    switch call.method {
    case "getPlatformVersion":
      handleGetPlatformVersion(result: result)

    case "getMetadata":
      handleGetMetadata(call: call, result: result)

    case "hasAudioTrack":
      handleHasAudioTrack(call: call, result: result)

    case "getThumbnails":
      handleGetThumbnails(call: call, result: result)

    case "renderVideo":
      handleRenderVideo(call: call, result: result)

    case "renderStopMotion":
      handleRenderStopMotion(call: call, result: result)

    case "extractAudio":
      handleExtractAudio(call: call, result: result)

    case "getWaveform":
      handleGetWaveform(call: call, result: result)

    case "startWaveformStream":
      handleStartWaveformStream(call: call, result: result)

    case "cancelTask":
      handleCancelTask(call: call, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func applyInlineNativeLogLevel(call: FlutterMethodCall) {
    guard let args = call.arguments as? [String: Any],
      let level = args["nativeLogLevel"] as? String,
      !level.isEmpty
    else {
      return
    }

    do {
      try PluginLog.setMinimumLevel(level)
    } catch {
      PluginLog.print("⚠️ Ignoring invalid nativeLogLevel '\(level)': \(error.localizedDescription)")
    }
  }

  // MARK: - Handler Methods

  /// Returns the iOS platform version string.
  private func handleGetPlatformVersion(result: FlutterResult) {
    #if os(iOS)
      result("iOS " + UIDevice.current.systemVersion)
    #elseif os(macOS)
      result("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    #endif
  }

  /// Extracts metadata from a video file asynchronously.
  ///
  /// Retrieves technical properties (duration, dimensions, bitrate)
  /// and descriptive tags (title, artist, album, etc.).
  private func handleGetMetadata(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let config = MetadataConfig.fromArguments(call.arguments as? [String: Any]) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Expected arguments missing", details: nil))
      return
    }

    Task {
      do {
        let meta = try await VideoMetadata.processVideo(
          inputPath: config.inputPath,
          ext: config.fileExtension,
          checkStreamingOptimization: config.checkStreamingOptimization)
        self.deliverResult(result, meta)
      } catch {
        self.deliverResult(
          result,
          FlutterError(code: "METADATA_ERROR", message: error.localizedDescription, details: nil))
      }
    }
  }

  /// Checks if a video file has an audio track.
  ///
  /// Quickly inspects the video to determine if it contains at least one audio track.
  /// This is useful to check before attempting audio extraction operations.
  private func handleHasAudioTrack(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let config = MetadataConfig.fromArguments(call.arguments as? [String: Any]) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Expected arguments missing", details: nil))
      return
    }

    Task {
      do {
        let hasAudio = try await VideoMetadata.checkAudioTrack(inputPath: config.inputPath)
        self.deliverResult(result, hasAudio)
      } catch {
        self.deliverResult(
          result,
          FlutterError(code: "AUDIO_CHECK_ERROR", message: error.localizedDescription, details: nil)
        )
      }
    }
  }

  /// Generates thumbnail images from a video asynchronously.
  ///
  /// Supports timestamp-based or keyframe-based extraction.
  /// Thumbnails are generated in parallel for optimal performance.
  private func handleGetThumbnails(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let config = ThumbnailConfig.fromArguments(call.arguments as? [String: Any]) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Expected arguments missing or invalid",
          details: nil))
      return
    }

    postProgress(id: config.id, progress: 0.0)

    ThumbnailGenerator.getThumbnails(
      config: config,
      onProgress: { progress in
        self.postProgress(id: config.id, progress: progress)
      },
      onComplete: { thumbnails in
        self.postProgress(id: config.id, progress: 1.0)
        self.deliverResult(result, thumbnails)
      },
      onError: { error in
        self.deliverResult(
          result,
          FlutterError(
            code: "THUMBNAIL_ERROR", message: error.localizedDescription, details: nil))
      }
    )
  }

  /// Starts an asynchronous video render job with effects.
  ///
  /// Handles video concatenation, visual effects (rotation, flip,
  /// scale, color, blur), audio processing, and output configuration.
  /// Each job is tracked by unique ID and can be canceled.
  private func handleRenderVideo(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing task id", details: nil))
      return
    }

    if activeRenderTasks[id] != nil {
      result(
        FlutterError(
          code: "TASK_ALREADY_RUNNING", message: "Task with id \(id) is already running",
          details: nil))
      return
    }

    guard let config = RenderConfig.fromArguments(args) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Invalid render configuration", details: nil))
      return
    }

    postProgress(id: id, progress: 0.0)

    let task = RenderTask(result: result)
    activeRenderTasks[id] = task

    let handle = RenderVideo.render(
      config: config,
      onProgress: { progress in
        self.postProgress(id: id, progress: progress)
      },
      onComplete: { outputData in
        DispatchQueue.main.async {
          self.postProgress(id: id, progress: 1.0)
          if let task = self.activeRenderTasks.removeValue(forKey: id) {
            task.sendSuccess(outputData)
          } else {
            self.deliverResult(result, outputData)
          }
        }
      },
      onError: { error in
        PluginLog.print("❌ Render failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
          let task = self.activeRenderTasks.removeValue(forKey: id)
          let code = (task?.isCanceled == true) ? "CANCELED" : "RENDER_ERROR"
          let flutterError = FlutterError(
            code: code,
            message: error.localizedDescription,
            details: nil
          )
          if let task = task {
            task.sendError(flutterError)
          } else {
            self.deliverResult(result, flutterError)
          }
        }
      }
    )

    task.attachHandle(handle)
  }

  /// Starts an asynchronous stop-motion render job.
  ///
  /// Encodes a sequence of still images into a single (silent) video.
  /// Each job is tracked by unique ID and can be canceled. Reuses the same
  /// task tracking as `handleRenderVideo` so `cancelTask` works unchanged.
  private func handleRenderStopMotion(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing task id", details: nil))
      return
    }

    if activeRenderTasks[id] != nil {
      result(
        FlutterError(
          code: "TASK_ALREADY_RUNNING", message: "Task with id \(id) is already running",
          details: nil))
      return
    }

    guard let config = StopMotionConfig.fromArguments(args) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Invalid stop-motion configuration", details: nil))
      return
    }

    postProgress(id: id, progress: 0.0)

    let task = RenderTask(result: result)
    activeRenderTasks[id] = task

    let handle = StopMotionGenerator.generate(
      config: config,
      onProgress: { progress in
        self.postProgress(id: id, progress: progress)
      },
      onComplete: { outputData in
        DispatchQueue.main.async {
          self.postProgress(id: id, progress: 1.0)
          if let task = self.activeRenderTasks.removeValue(forKey: id) {
            task.sendSuccess(outputData)
          } else {
            self.deliverResult(result, outputData)
          }
        }
      },
      onError: { error in
        PluginLog.print("❌ Stop-motion render failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
          let task = self.activeRenderTasks.removeValue(forKey: id)
          let code = (task?.isCanceled == true) ? "CANCELED" : "RENDER_ERROR"
          let flutterError = FlutterError(
            code: code,
            message: error.localizedDescription,
            details: nil
          )
          if let task = task {
            task.sendError(flutterError)
          } else {
            self.deliverResult(result, flutterError)
          }
        }
      }
    )

    task.attachHandle(handle)
  }

  /// Extracts audio from a video file asynchronously.
  ///
  /// Extracts the audio track and optionally trims it to
  /// the specified time range. Each job is tracked by unique ID
  /// and can be canceled.
  private func handleExtractAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing task id", details: nil))
      return
    }

    if activeAudioTasks[id] != nil {
      result(
        FlutterError(
          code: "TASK_ALREADY_RUNNING",
          message: "Audio extraction task with id \(id) is already running",
          details: nil))
      return
    }

    guard let config = AudioExtractConfig.fromArguments(args) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Invalid audio extraction configuration", details: nil
        ))
      return
    }

    postProgress(id: id, progress: 0.0)

    let task = AudioExtractTask(result: result)
    activeAudioTasks[id] = task

    let handle = ExtractAudio.extract(
      config: config,
      onProgress: { progress in
        self.postProgress(id: id, progress: progress)
      },
      onComplete: { outputData in
        DispatchQueue.main.async {
          self.postProgress(id: id, progress: 1.0)
          if let task = self.activeAudioTasks.removeValue(forKey: id) {
            task.sendSuccess(outputData)
          } else {
            self.deliverResult(result, outputData)
          }
        }
      },
      onError: { error in
        PluginLog.print("❌ Audio extraction failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
          let task = self.activeAudioTasks.removeValue(forKey: id)
          let code: String
          if task?.isCanceled == true {
            code = "CANCELED"
          } else if error is NoAudioTrackException {
            code = "NO_AUDIO"
          } else {
            code = "EXTRACT_ERROR"
          }
          let flutterError = FlutterError(
            code: code,
            message: error.localizedDescription,
            details: nil
          )
          if let task = task {
            task.sendError(flutterError)
          } else {
            self.deliverResult(result, flutterError)
          }
        }
      }
    )

    task.attachHandle(handle)
  }

  /// Generates waveform data from a video's audio track asynchronously.
  ///
  /// Decodes audio to PCM and computes peak amplitudes at the specified
  /// resolution. Returns normalized float arrays for Flutter rendering.
  private func handleGetWaveform(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing task id", details: nil))
      return
    }

    if activeWaveformTasks[id] != nil {
      result(
        FlutterError(
          code: "TASK_ALREADY_RUNNING", message: "Waveform task with id \(id) is already running",
          details: nil))
      return
    }

    guard let config = WaveformConfig.fromArguments(args) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Invalid waveform configuration", details: nil))
      return
    }

    postProgress(id: id, progress: 0.0)

    let task = WaveformTask(result: result)
    activeWaveformTasks[id] = task

    let handle = WaveformGenerator.generate(
      config: config,
      onProgress: { progress in
        self.postProgress(id: id, progress: progress)
      },
      onComplete: { waveformData in
        DispatchQueue.main.async {
          self.postProgress(id: id, progress: 1.0)
          if let task = self.activeWaveformTasks.removeValue(forKey: id) {
            task.sendSuccess(waveformData)
          } else {
            self.deliverResult(result, waveformData)
          }
        }
      },
      onError: { error in
        DispatchQueue.main.async {
          let task = self.activeWaveformTasks.removeValue(forKey: id)
          let code: String
          if task?.isCanceled == true {
            code = "CANCELED"
          } else if error is NoAudioTrackException {
            code = "NO_AUDIO"
          } else {
            code = "WAVEFORM_ERROR"
          }
          let flutterError = FlutterError(
            code: code,
            message: error.localizedDescription,
            details: nil
          )
          if let task = task {
            task.sendError(flutterError)
          } else {
            self.deliverResult(result, flutterError)
          }
        }
      }
    )

    task.attachHandle(handle)
  }

  /// Starts streaming waveform generation.
  ///
  /// Unlike handleGetWaveform which waits for complete generation,
  /// this method emits waveform chunks progressively via the waveformStreamChannel.
  private func handleStartWaveformStream(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing task id", details: nil))
      return
    }

    if activeWaveformTasks[id] != nil {
      result(
        FlutterError(
          code: "TASK_ALREADY_RUNNING", message: "Waveform task with id \(id) is already running",
          details: nil))
      return
    }

    guard let config = WaveformConfig.fromArguments(args) else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS", message: "Invalid waveform configuration", details: nil))
      return
    }

    let task = WaveformTask(result: result)
    activeWaveformTasks[id] = task

    let handle = WaveformGenerator.generateStreaming(
      config: config,
      onChunk: { chunkData in
        DispatchQueue.main.async {
          self.waveformStreamSink?(chunkData)
        }
      },
      onComplete: {
        DispatchQueue.main.async {
          self.activeWaveformTasks.removeValue(forKey: id)
          // Don't call result.success for streaming - chunks are sent via event channel
        }
      },
      onError: { error in
        DispatchQueue.main.async {
          let task = self.activeWaveformTasks.removeValue(forKey: id)
          let code: String
          if task?.isCanceled == true {
            code = "CANCELED"
          } else if error is NoAudioTrackException {
            code = "NO_AUDIO"
          } else {
            code = "WAVEFORM_ERROR"
          }
          // Send error via event channel
          let errorData: [String: Any] = [
            "id": id,
            "error": error.localizedDescription,
            "errorCode": code,
          ]
          self.waveformStreamSink?(errorData)
        }
      }
    )

    task.attachHandle(handle)

    // Return immediately - chunks will be sent via event channel
    result(nil)
  }

  /// Cancels an active render or audio extraction task by ID.
  ///
  /// Marks task as canceled, triggers cancellation handler
  /// (stops export session, cleans up files), and removes from tracking.
  private func handleCancelTask(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing parameters", details: nil))
      return
    }

    guard !id.isEmpty else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "Expected non-empty task id",
          details: nil
        )
      )
      return
    }

    // Try to find task in render tasks
    if let task = activeRenderTasks[id] {
      task.cancel()
      result(nil)
      return
    }

    // Try to find task in audio tasks
    if let task = activeAudioTasks[id] {
      task.cancel()
      result(nil)
      return
    }

    // Try to find task in waveform tasks
    if let task = activeWaveformTasks[id] {
      task.cancel()
      result(nil)
      return
    }

    result(
      FlutterError(code: "TASK_NOT_FOUND", message: "No task found for id \(id)", details: nil))
  }

  // MARK: - Helper Methods

  /// Sends progress updates to Flutter via event channel.
  ///
  /// Progress events are sent on main thread with task ID
  /// and progress value (0.0 to 1.0).
  private func postProgress(id: String, progress: Double) {
    DispatchQueue.main.async {
      self.eventSink?([
        "id": id,
        "progress": progress,
      ])
    }
  }

  /// Forwards a native log entry to Flutter via the log event channel.
  ///
  /// Log events are sent on the main thread with level, tag, message, and
  /// timestamp (epoch milliseconds).
  func postLog(level: PluginLogLevel, message: String) {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    DispatchQueue.main.async {
      self.logSink?([
        "level": level.methodValue,
        "tag": Tags.package,
        "message": message,
        "timestamp": timestamp,
      ])
    }
  }
}
