import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '/core/models/thumbnail/key_frames_configs_model.dart';
import '/core/models/thumbnail/thumbnail_configs_model.dart';
import '/core/utils/web_blob_utils.dart';
import '/core/utils/web_canvas_utils.dart';

/// A utility class for extracting thumbnails and key frames from video data
/// in Flutter Web using HTML video and canvas APIs.
class WebThumbnailGenerator {
  /// Generates thumbnails from specific timestamps of a video.
  ///
  /// Uses the provided [ThumbnailConfigs] to load the video, seek to
  /// each timestamp, draw the frame to a canvas, and export it as an
  /// image in the specified format.
  ///
  /// Returns a list of [Uint8List] images corresponding to the given
  /// timestamps.
  Future<List<Uint8List>> getThumbnails(
    ThumbnailConfigs value, {
    void Function(double progress)? onProgress,
  }) async {
    final setup = await _prepareVideoRendering(
      videoBytes: await value.video.safeByteArray(),
      outputWidth: value.outputSize.width.toInt(),
    );
    if (setup == null) return [];

    final (video, canvas, ctx, width, height, objectUrl) = setup;
    List<Uint8List> thumbnails = [];

    await video.onLoadedData.first;

    final total = value.timestamps.length;
    for (int i = 0; i < total; i++) {
      final t = value.timestamps[i];
      video.currentTime = t.inSeconds;
      await video.onSeeked.first;
      await Future.delayed(const Duration(milliseconds: 1));

      ctx.drawImage(video, 0, 0, width.toDouble(), height.toDouble());
      final blob = await canvas.toBlobAsync('image/${value.outputFormat}');
      thumbnails.add(await _blobToUint8List(blob));

      onProgress?.call((i + 1) / total);
    }

    video.remove();
    web.URL.revokeObjectURL(objectUrl);

    return thumbnails;
  }

  /// Extracts evenly spaced key frames from a video.
  ///
  /// Uses [KeyFramesConfigs] to define how many frames to extract,
  /// and what size and format to use. The frames are taken at evenly
  /// spaced time intervals throughout the video's duration.
  ///
  /// Returns a list of [Uint8List] images.
  Future<List<Uint8List>> getKeyFrames(
    KeyFramesConfigs value, {
    void Function(double progress)? onProgress,
  }) async {
    final setup = await _prepareVideoRendering(
      videoBytes: await value.video.safeByteArray(),
      outputWidth: value.outputSize.width.toInt(),
    );
    if (setup == null) return [];

    final (video, canvas, ctx, width, height, objectUrl) = setup;
    List<Uint8List> frames = [];

    final duration = video.duration;
    final step = duration / value.maxOutputFrames;

    await video.onLoadedData.first;

    for (int i = 0; i < value.maxOutputFrames; i++) {
      final time = i * step;
      if (time >= duration) break;

      video.currentTime = time;
      await video.onSeeked.first;
      await Future.delayed(const Duration(milliseconds: 1));

      ctx.drawImage(video, 0, 0, width.toDouble(), height.toDouble());
      final blob = await canvas.toBlobAsync('image/${value.outputFormat}');
      frames.add(await _blobToUint8List(blob));

      onProgress?.call((i + 1) / value.maxOutputFrames);
    }

    video.remove();
    web.URL.revokeObjectURL(objectUrl);

    return frames;
  }

  Future<
      (
        web.HTMLVideoElement,
        web.HTMLCanvasElement,
        web.CanvasRenderingContext2D,
        int,
        int,
        String,
      )?> _prepareVideoRendering({
    required Uint8List videoBytes,
    required int outputWidth,
  }) async {
    if (outputWidth == 0) return null;

    final blob = Blob.fromUint8List(videoBytes);
    final objectUrl = web.URL.createObjectURL(blob);

    final video = web.HTMLVideoElement()
      ..src = objectUrl
      ..crossOrigin = 'anonymous'
      ..preload = 'auto'
      ..style.display = 'none';

    web.document.body!.append(video);
    await video.onLoadedMetadata.first;

    final scale = outputWidth / video.videoWidth;
    final outputHeight = (video.videoHeight * scale).round();

    final canvas = web.HTMLCanvasElement()
      ..width = outputWidth
      ..height = outputHeight;
    final ctx = canvas.context2D;

    return (video, canvas, ctx, outputWidth, outputHeight, objectUrl);
  }

  Future<Uint8List> _blobToUint8List(web.Blob blob) {
    final reader = web.FileReader();
    final completer = Completer<Uint8List>();

    reader.readAsArrayBuffer(blob as dynamic);
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result != null) {
        var nativeBuffer = reader.result as JSArrayBuffer;
        var dartBuffer = nativeBuffer.toDart;
        completer.complete(dartBuffer.asUint8List());
      } else {
        completer.completeError(Exception('Failed to read blob data'));
      }
    });

    return completer.future;
  }
}
