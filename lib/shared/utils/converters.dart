// Flutter imports:
import 'package:flutter/services.dart';

// Package imports:
import 'package:http/http.dart' as http;

import '/core/platform/io/io_helper.dart';

/// Loads an video asset as a Uint8List.
///
/// This function allows you to load an video asset from the app's assets
/// directory and convert it into a Uint8List for further use.
///
/// Parameters:
/// - `assetPath`: A String representing the asset path of the video to be
/// loaded.
///
/// Returns:
/// A Future that resolves to a Uint8List containing the video data.
///
/// Example Usage:
/// ```dart
/// final Uint8List videoBytes = await loadAssetVideoAsUint8List('assets/video.mp4');
/// ```
Future<Uint8List> loadAssetVideoAsUint8List(String assetPath) async {
  // Load the asset as a ByteData
  final ByteData data = await rootBundle.load(assetPath);

  // Convert the ByteData to a Uint8List
  final Uint8List uint8List = data.buffer.asUint8List();

  return uint8List;
}

/// Writes a video file from memory to the specified file path.
///
/// This function takes a [Uint8List] of bytes representing the video data
/// and writes it to a file at the given [filePath]. The file is flushed
/// to ensure all data is written to disk before returning.
///
/// - Parameters:
///   - bytes: The video data in memory as a [Uint8List].
///   - filePath: The path where the video file should be written.
///
/// - Returns: A [Future] that resolves to the [File] object representing
///   the written file.
///
/// - Throws: An [IOException] if the file cannot be written.
///   be written.
///
Future<File> writeMemoryVideoToFile(Uint8List bytes, String filePath) async {
  final file = File(filePath);

  await file.parent.create(recursive: true);
  await file.writeAsBytes(
    bytes,
    flush: true,
  );

  return file;
}

/// Writes a video asset to a file on the local file system.
///
/// This function takes the path of a video asset bundled with the application
/// and writes its content to a specified file path on the device's file system.
///
/// - Parameters:
///   - assetPath: The path to the video asset within the application's assets.
///   - filePath: The destination file path where the video will be written.
///
/// - Returns: A [Future] that resolves to a [File] object representing the
///   written file.
///
/// - Throws: An exception if the asset cannot be loaded or the file cannot
///   be written.
Future<File> writeAssetVideoToFile(String assetPath, String filePath) async {
  final ByteData data = await rootBundle.load(assetPath);
  final buffer = data.buffer;

  final file = File(filePath);

  await file.parent.create(recursive: true);
  await file.writeAsBytes(
    buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );

  return file;
}

/// Fetches an video from a network URL as a Uint8List.
///
/// This function allows you to fetch an video from a network URL and convert
/// it into a Uint8List for further use.
///
/// Parameters:
/// - `videoUrl`: A String representing the network URL of the video to be
/// fetched.
///
/// Returns:
/// A Future that resolves to a Uint8List containing the video data.
///
/// Example Usage:
/// ```dart
/// final Uint8List videoBytes = await fetchImageAsUint8List('https://example.com/video.mp4');
/// ```
Future<Uint8List> fetchVideoAsUint8List(String videoUrl) async {
  final response = await http.get(Uri.parse(videoUrl));

  if (response.statusCode == 200) {
    // Convert the response body to a Uint8List
    final Uint8List uint8List = Uint8List.fromList(response.bodyBytes);
    return uint8List;
  } else {
    throw Exception('Failed to load video: $videoUrl');
  }
}

/// Fetches a video from a given URL and saves it to a specified file path.
///
/// This function sends an HTTP GET request to the provided `videoUrl` and
/// streams the response directly into a file at the specified `filePath`.
///
/// Throws an [Exception] if the HTTP request fails or the response status
/// code is not 200.
///
/// Parameters:
/// - `videoUrl`: The URL of the video to be downloaded.
/// - `filePath`: The local file path where the video will be saved.
///
/// Returns:
/// A [Future] that resolves to a [File] object representing the downloaded
/// video.
///
/// Example:
/// ```dart
/// try {
///   final file = await fetchVideoToFile(
///     'https://example.com/video.mp4',
///     '/path/to/save/video.mp4',
///   );
///   print('Video saved to: ${file.path}');
/// } catch (e) {
///   print('Error downloading video: $e');
/// }
/// ```
Future<File> fetchVideoToFile(String videoUrl, String filePath) async {
  final request = http.Request('GET', Uri.parse(videoUrl));
  final response = await request.send();

  if (response.statusCode == 200) {
    final file = File(filePath);

    await file.parent.create(recursive: true);

    // Create an empty file and open an IOSink to write to it
    final sink = file.openWrite() as IOSink;

    // Pipe the streamed response into the file
    await response.stream.pipe(sink as dynamic);

    // Close the file
    await sink.flush();
    await sink.close();

    return file;
  } else {
    throw Exception('Failed to download video: $videoUrl');
  }
}

/// Reads a file as a Uint8List.
///
/// This function allows you to read the contents of a file and convert it into
/// a Uint8List for further use.
///
/// Parameters:
/// - `file`: A File object representing the video file to be read.
///
/// Returns:
/// A Future that resolves to a Uint8List containing the file's data.
///
/// Example Usage:
/// ```dart
/// final File videoFile = File('path/to/video.mp4');
/// final Uint8List fileBytes = await readFileAsUint8List(videoFile);
/// ```
Future<Uint8List> readFileAsUint8List(File file) async {
  try {
    // Read the file as bytes
    final Uint8List uint8List = await file.readAsBytes();

    return uint8List;
  } catch (e) {
    throw Exception('Failed to read file: ${file.path}');
  }
}
