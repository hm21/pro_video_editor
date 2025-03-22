import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:pro_video_editor/core/models/thumbnail/create_video_thumbnail_model.dart';
import 'package:pro_video_editor/core/utils/web_canvas_utils.dart';
import 'package:web/web.dart' as web;

import '../../utils/web_blob_utils.dart';

/// A utility class to generate video thumbnails in web environments.
///
/// Uses browser APIs to capture frames from a video file and return them
/// as image thumbnails.
class WebThumbnailGenerator {
  /// Generates thumbnails from a video using the given [value] parameters.
  ///
  /// The [value] should contain the video data and any configuration
  /// needed for extracting thumbnails, such as timestamps or frame count.
  ///
  /// Returns a [Future] that completes with a list of [Uint8List]
  /// objects, each representing an image thumbnail in bytes.
  Future<List<Uint8List>> generateThumbnails(CreateVideoThumbnail value) async {
    var videoBytes = await value.video.safeByteArray();
    var width = value.imageWidth.toInt();
    if (width == 0) return [];

    final blob = Blob.fromUint8List(videoBytes);
    final objectUrl = web.URL.createObjectURL(blob);

    final video = web.HTMLVideoElement()
      ..src = objectUrl
      ..crossOrigin = 'anonymous'
      ..preload = 'auto'
      ..style.display = 'none';

    web.document.body!.append(video);
    await video.onLoadedMetadata.first;

    final scale = width / video.videoWidth;
    final height = (video.videoHeight * scale).round();

    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final ctx = canvas.context2D;

    List<Uint8List> thumbnails = [];

    await video.onLoadedData.first;

    for (final t in value.timestamps) {
      video.currentTime = t.inSeconds;

      await video.onSeeked.first;

      ctx.drawImage(video, 0, 0, width.toDouble(), height.toDouble());

      final blob = await canvas.toBlobAsync('image/${value.format}');
      final data = await _blobToUint8List(blob);
      thumbnails.add(data);
    }

    video.remove();
    web.URL.revokeObjectURL(objectUrl);

    return thumbnails;
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
