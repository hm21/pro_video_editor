import 'package:flutter/services.dart';

/// The plugin's method channel, the same one [MethodChannelProVideoEditor]
/// uses.
const _channel = MethodChannel('pro_video_editor');

/// Copies an Android `content://` URI into a local file on the native side
/// and returns the file's path.
///
/// The file is [outputPathWithoutExtension] plus the extension of the
/// source's MIME type, e.g. `.mp4` or `.mov`. Android only.
Future<String> copyContentUriToFile(
  String uri,
  String outputPathWithoutExtension,
) async {
  final path = await _channel.invokeMethod<String>('copyContentToFile', {
    'inputPath': uri,
    'outputPath': outputPathWithoutExtension,
  });
  if (path == null) {
    throw StateError('Copying $uri returned no file path.');
  }
  return path;
}
