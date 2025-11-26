// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:pro_video_editor/core/models/video/progress_model.dart';
import 'package:web/web.dart' as web;

import '/core/services/web/web_manager.dart';
import 'core/models/thumbnail/key_frames_configs.model.dart';
import 'core/models/thumbnail/thumbnail_configs.model.dart';
import 'core/models/video/editor_video_model.dart';
import 'core/models/video/render_video_model.dart';
import 'core/models/video/video_metadata_model.dart';
import 'pro_video_editor_platform_interface.dart';

/// A web implementation of the ProVideoEditorPlatform of the ProVideoEditor
/// plugin.
class ProVideoEditorWeb extends ProVideoEditor {
  /// Constructs a ProVideoEditorWeb
  ProVideoEditorWeb();

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
  Future<VideoMetadata> getMetadata(EditorVideo value) async {
    return _manager.getMetadata(value);
  }

  @override
  Future<List<Uint8List>> getThumbnails(ThumbnailConfigs value) {
    return _manager.getThumbnails(
      value,
      onProgress: (progress) => _updateProgress(value.id, progress),
    );
  }

  @override
  Future<List<Uint8List>> getKeyFrames(KeyFramesConfigs value) {
    return _manager.getKeyFrames(
      value,
      onProgress: (progress) => _updateProgress(value.id, progress),
    );
  }

  @override
  Future<Uint8List> renderVideo(RenderVideoModel value) {
    throw UnimplementedError('renderVideo() has not been implemented.');
  }

  @override
  Future<String> renderVideoToFile(
    String filePath,
    RenderVideoModel value,
  ) {
    throw UnimplementedError('renderVideoToFile() has not been implemented.');
  }

  @override
  Future<void> cancel(String taskId) {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  @override
  void initializeStream() {}

  void _updateProgress(String taskId, double progress) {
    progressCtrl.add(ProgressModel(id: taskId, progress: progress));
  }
}
