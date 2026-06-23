// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:pro_video_editor/core/models/audio/audio_extract_configs_model.dart';
import 'package:pro_video_editor/core/models/video/progress_model.dart';
import 'package:web/web.dart' as web;

import '/core/models/platform/native_log_level.dart';
import '/core/models/thumbnail/key_frames_configs_model.dart';
import '/core/models/thumbnail/single_thumbnail_configs_model.dart';
import '/core/models/thumbnail/thumbnail_configs_model.dart';
import '/core/models/video/editor_video_model.dart';
import '/core/models/video/video_metadata_model.dart';
import '/core/services/web/web_manager.dart';
import '../models/video/stop_motion_render_data_model.dart';
import '../models/video/video_render_data_model.dart';
import 'platform_interface.dart';

/// Web platform implementation using JavaScript APIs.
///
/// This implementation uses browser-native capabilities:
/// - **Video Metadata**: HTML5 Video Element
/// - **Thumbnails**: Canvas API for frame extraction
/// - **Key Frames**: Canvas-based scene change detection
///
/// **Limitations:**
/// - No video rendering support (browser codec restrictions)
/// - No task cancellation (not implemented for web)
/// - Limited codec support compared to native platforms
///
/// All operations run in the browser's main thread with Web Workers
/// for heavy computations when possible.
class ProVideoEditorWeb extends ProVideoEditor {
  /// Constructs a ProVideoEditorWeb instance.
  ProVideoEditorWeb();

  /// Manager for all web-based video operations.
  ///
  /// Handles video loading, canvas manipulation, and frame extraction
  /// using browser APIs.
  final WebManager _manager = WebManager();

  /// Registers the web implementation of the ProVideoEditor platform interface.
  static void registerWith(Registrar registrar) {
    ProVideoEditor.instance = ProVideoEditorWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = web.window.navigator.userAgent;
    return version;
  }

  @override
  Future<VideoMetadata> getMetadata(
    EditorVideo value, {
    bool checkStreamingOptimization = false,
    NativeLogLevel? nativeLogLevel,
  }) {
    // Web doesn't support streaming optimization check
    return _manager.getMetadata(value);
  }

  @override
  Future<bool> hasAudioTrack(
    EditorVideo value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError(
      'hasAudioTrack() has not been implemented on web.',
    );
  }

  @override
  Future<List<Uint8List>> getThumbnails(
    ThumbnailConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    return _manager.getThumbnails(
      value,
      onProgress: (progress) => _updateProgress(value.id, progress),
    );
  }

  @override
  Future<List<Uint8List>> getKeyFrames(
    KeyFramesConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    return _manager.getKeyFrames(
      value,
      onProgress: (progress) => _updateProgress(value.id, progress),
    );
  }

  @override
  Future<Uint8List?> getSingleThumbnail(
    SingleThumbnailConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    Duration timestamp;
    if (value.position == ThumbnailPosition.last) {
      final duration = value.videoDuration ??
          (await _manager.getMetadata(value.video)).duration;
      timestamp = duration;
    } else {
      timestamp = Duration.zero;
    }

    final configs = ThumbnailConfigs(
      video: value.video,
      outputSize: value.outputSize,
      outputFormat: value.outputFormat,
      boxFit: value.boxFit,
      id: value.id,
      jpegQuality: value.jpegQuality,
      timestamps: [timestamp],
    );

    final results = await _manager.getThumbnails(
      configs,
      onProgress: (progress) => _updateProgress(value.id, progress),
    );
    return results.isNotEmpty ? results.first : null;
  }

  @override
  Future<Uint8List> extractAudio(
    AudioExtractConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError('extractAudio() has not been implemented on web.');
  }

  @override
  Future<String> extractAudioToFile(
    String filePath,
    AudioExtractConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError(
      'extractAudioToFile() has not been implemented on web.',
    );
  }

  @override
  Future<Uint8List> renderVideo(
    VideoRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError('renderVideo() has not been implemented.');
  }

  @override
  Future<String> renderVideoToFile(
    String filePath,
    VideoRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError('renderVideoToFile() has not been implemented.');
  }

  @override
  Future<Uint8List> renderStopMotion(
    StopMotionRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError('renderStopMotion() is not supported on web.');
  }

  @override
  Future<String> renderStopMotionToFile(
    String filePath,
    StopMotionRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) {
    throw UnimplementedError(
      'renderStopMotionToFile() is not supported on web.',
    );
  }

  @override
  Future<void> cancel(String taskId) {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  @override
  void initializeStream() {
    // No-op for web - progress is managed directly by WebManager callbacks
  }

  /// Updates progress for a specific task.
  ///
  /// Called by [WebManager] callbacks during thumbnail/keyframe generation.
  /// Adds progress events to [progressCtrl] for stream consumers.
  ///
  /// [taskId] The unique identifier of the task.
  /// [progress] Progress value between 0.0 and 1.0.
  void _updateProgress(String taskId, double progress) {
    progressCtrl.add(ProgressModel(id: taskId, progress: progress));
  }
}
