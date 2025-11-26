import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '/core/models/video/editor_video_model.dart';
import 'core/models/thumbnail/key_frames_configs.model.dart';
import 'core/models/thumbnail/thumbnail_configs.model.dart';
import 'core/models/video/progress_model.dart';
import 'core/models/video/render_video_model.dart';
import 'core/models/video/video_metadata_model.dart';
import 'pro_video_editor_method_channel.dart';

/// An abstract class that defines the platform interface for the
/// Pro Video Editor plugin.
abstract class ProVideoEditor extends PlatformInterface {
  /// Constructs a ProVideoEditorPlatform.
  ProVideoEditor() : super(token: _token) {
    initializeStream();
  }

  static final Object _token = Object();

  static ProVideoEditor _instance = MethodChannelProVideoEditor();

  /// The default instance of [ProVideoEditor] to use.
  ///
  /// Defaults to [MethodChannelProVideoEditor].
  static ProVideoEditor get instance => _instance;

  /// The singleton instance of [ProVideoEditor].
  static set instance(ProVideoEditor instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Sets up the native progress stream connection.
  ///
  /// Must be implemented to receive progress updates from native code.
  @protected
  void initializeStream() {
    throw UnimplementedError('[initializeStream()] has not been implemented.');
  }

  /// Emits progress updates for running tasks.
  @protected
  final progressCtrl = StreamController<ProgressModel>.broadcast();

  /// Retrieves the platform version.
  ///
  /// Throws an [UnimplementedError] if not implemented.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Retrieves detailed information about the given video.
  ///
  /// [value] is an [EditorVideo] instance that can point to a file, memory,
  /// network URL, or asset.
  ///
  /// Returns a [Future] containing [VideoMetadata] about the video.
  Future<VideoMetadata> getMetadata(EditorVideo value) {
    throw UnimplementedError('getMetadata() has not been implemented.');
  }

  /// Generates a list of thumbnails from the given [ThumbnailConfigs].
  Future<List<Uint8List>> getThumbnails(ThumbnailConfigs value) {
    throw UnimplementedError('getThumbnails() has not been implemented.');
  }

  /// Extracts key frames from a video using the given [KeyFramesConfigs].
  Future<List<Uint8List>> getKeyFrames(KeyFramesConfigs value) {
    throw UnimplementedError('getKeyFrames() has not been implemented.');
  }

  /// Renders a video using the provided [RenderVideoModel] configuration.
  Future<Uint8List> renderVideo(RenderVideoModel value) {
    throw UnimplementedError('renderVideo() has not been implemented.');
  }

  /// Renders a video to a file based on the provided [RenderVideoModel].
  Future<String> renderVideoToFile(
    String filePath,
    RenderVideoModel value,
  ) {
    throw UnimplementedError('renderVideoToFile() has not been implemented.');
  }

  /// Cancels an active rendering task identified by [taskId].
  ///
  /// Implementations should gracefully handle unknown task IDs by surfacing
  /// a controlled error instead of crashing the app.
  Future<void> cancel(String taskId) {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  /// Stream of progress updates from native video tasks.
  ///
  /// Emits [ProgressModel] updates for all running or completed tasks. Each
  /// emitted event contains a task ID, which can be used to filter specific
  /// tasks.
  Stream<ProgressModel> get progressStream => progressCtrl.stream;

  /// Stream of progress updates for a specific task ID.
  ///
  /// Listens to [progressStream] and emits only the [ProgressModel] updates
  /// matching the given [taskId]. Useful when tracking the progress of an
  /// individual video task independently.
  Stream<ProgressModel> progressStreamById(String taskId) =>
      progressStream.where((item) => item.id == taskId);
}
