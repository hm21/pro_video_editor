import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '/core/platform/io/io_helper.dart';

/// A model that encapsulates various ways to load and represent an image.
///
/// This class supports images from in-memory bytes, file system, network,
/// or asset bundle. It provides convenience methods for identifying the
/// source type and safely retrieving image bytes.
class EditorLayerImage {
  /// Creates an instance of the `EditorImage` class with the specified
  /// properties.
  ///
  /// At least one of `byteArray`, `file`, `networkUrl`, or `assetPath`
  /// must not be null.
  EditorLayerImage._({
    this.byteArray,
    this.networkUrl,
    this.assetPath,
    this.file,
  }) : assert(
          byteArray != null ||
              file != null ||
              networkUrl != null ||
              assetPath != null,
          'At least one of bytes, file, networkUrl, or assetPath must not '
          'be null.',
        );

  /// Creates an [EditorLayerImage] from in-memory bytes.
  ///
  /// Suitable when you already have the image content loaded as a [Uint8List].
  ///
  /// Example:
  /// ```dart
  /// final image = EditorImage.memory(imageBytes);
  /// ```
  factory EditorLayerImage.memory(Uint8List bytes) =>
      EditorLayerImage._(byteArray: bytes);

  /// Creates an [EditorLayerImage] from a bundled asset path.
  ///
  /// Ideal for loading images packaged with the app.
  ///
  /// Example:
  /// ```dart
  /// final image = EditorImage.asset('assets/images/overlay.png');
  /// ```
  factory EditorLayerImage.asset(String name) =>
      EditorLayerImage._(assetPath: name);

  /// Creates an [EditorLayerImage] from a local file.
  ///
  /// [file] can be a `File` or the path as string to the file.
  ///
  /// Example:
  /// ```dart
  /// final image = EditorImage.file(File('/path/to/image.png'));
  /// final image = EditorImage.file('/path/to/image.png');
  /// ```
  factory EditorLayerImage.file(dynamic file) {
    if (file is String) {
      return EditorLayerImage._(file: File(file));
    }
    return EditorLayerImage._(file: file as File);
  }

  /// Creates an [EditorLayerImage] from a network URL.
  ///
  /// Useful for downloading image content from the web.
  ///
  /// Example:
  /// ```dart
  /// final image = EditorImage.network('https://example.com/overlay.png');
  /// ```
  factory EditorLayerImage.network(String src) =>
      EditorLayerImage._(networkUrl: src);

  /// A byte array representing the image data.
  Uint8List? byteArray;

  /// A `File` object representing the image file.
  final File? file;

  /// A URL string pointing to an image on the internet.
  final String? networkUrl;

  /// A string representing the asset path of an image.
  final String? assetPath;

  /// Indicates whether the `byteArray` property is not null.
  bool get hasBytes => byteArray != null;

  /// Indicates whether the `networkUrl` property is not null.
  bool get hasNetworkUrl => networkUrl != null;

  /// Indicates whether the `file` property is not null.
  bool get hasFile => file != null;

  /// Indicates whether the `assetPath` property is not null.
  bool get hasAssetPath => assetPath != null;

  /// Returns the type of the image source.
  EditorImageType get type {
    if (hasBytes) {
      return EditorImageType.memory;
    } else if (hasFile) {
      return EditorImageType.file;
    } else if (hasNetworkUrl) {
      return EditorImageType.network;
    } else {
      return EditorImageType.asset;
    }
  }

  /// Retrieves the image data as a `Uint8List` from the appropriate source.
  ///
  /// The result is cached in [byteArray] after the first call.
  Future<Uint8List> safeByteArray() async {
    if (byteArray != null) return byteArray!;

    Uint8List bytes;
    switch (type) {
      case EditorImageType.memory:
        return byteArray!;
      case EditorImageType.asset:
        final data = await rootBundle.load(assetPath!);
        bytes = data.buffer.asUint8List();
        break;
      case EditorImageType.file:
        bytes = await file!.readAsBytes();
        break;
      case EditorImageType.network:
        final response = await http.get(Uri.parse(networkUrl!));
        if (response.statusCode == 200) {
          bytes = Uint8List.fromList(response.bodyBytes);
        } else {
          throw Exception('Failed to load image: $networkUrl');
        }
        break;
    }

    byteArray = bytes;
    return bytes;
  }
}

/// Enum representing the type of source the image was loaded from.
enum EditorImageType {
  /// Represents an image loaded from a file.
  file,

  /// Represents an image loaded from a network URL.
  network,

  /// Represents an image loaded from memory (byte array).
  memory,

  /// Represents an image loaded from an asset path.
  asset,
}
