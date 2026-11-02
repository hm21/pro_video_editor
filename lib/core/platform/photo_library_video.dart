import 'package:flutter/services.dart';

/// The plugin's method channel, the same one [MethodChannelProVideoEditor]
/// uses.
const _channel = MethodChannel('pro_video_editor');

/// Whether [url] names a video in the Apple photo library, like the
/// `ph:///<localIdentifier>` URIs `file_picker` returns.
bool isPhotoLibraryUrl(String url) => url.startsWith('ph://');

/// Resolves a photo library `ph://` URL on the native side to the path of a
/// file AVFoundation can open, and returns the path.
///
/// That is the file the photo library keeps the video in, read in place. Only
/// a video Photos plays from a composition, such as a slow-motion video, is
/// exported once into the cache. iOS and macOS only.
Future<String> resolvePhotoLibraryVideo(String url) async {
  final path = await _channel.invokeMethod<String>('resolvePhotoLibraryVideo', {
    'inputPath': url,
  });
  if (path == null) {
    throw StateError('Resolving $url returned no file path.');
  }
  return path;
}
