import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A class representing a file with a given path.
class File {
  /// Creates a [File] instance with the given [path].
  File(this.path);

  /// The file path represented as a string.
  final String path;

  /// Returns the parent directory.
  Directory get parent {
    return Directory();
  }

  /// Write to the file path
  Future<void> writeAsString(String value) async {
    throw ArgumentError('This function is not supported on the web.');
  }

  /// Write to the file path
  Future<void> writeAsBytes(Uint8List value, {bool? flush}) async {
    throw ArgumentError('This function is not supported on the web.');
  }

  /// Read bytes async
  Future<Uint8List> readAsBytes() async {
    throw ArgumentError('This function is not supported on the web.');
  }

  /// Read bytes sync
  String readAsStringSync() {
    throw ArgumentError('This function is not supported on the web.');
  }

  /// Creates a new independent [IOSink] for the file.
  Future<void> openWrite() {
    throw ArgumentError('This function is not supported on the web.');
  }
}

/// Information about the environment in which the current program is running.
///
/// Platform provides information such as the operating system,
/// the hostname of the computer, the value of environment variables,
/// the path to the running program,
/// and other global properties of the program being run.
class Platform {
  /// Whether the operating system is a version of
  /// [Linux](https://en.wikipedia.org/wiki/Linux).
  ///
  /// This value is `false` if the operating system is a specialized
  /// version of Linux that identifies itself by a different name,
  /// for example Android (see [isAndroid]).
  static final bool isLinux = (operatingSystem == 'linux');

  /// Whether the operating system is a version of
  /// [macOS](https://en.wikipedia.org/wiki/MacOS).
  static final bool isMacOS = (operatingSystem == 'macos');

  /// Whether the operating system is a version of
  /// [Microsoft Windows](https://en.wikipedia.org/wiki/Microsoft_Windows).
  static final bool isWindows = (operatingSystem == 'windows');

  /// Whether the operating system is a version of
  /// [Android](https://en.wikipedia.org/wiki/Android_%28operating_system%29).
  static final bool isAndroid = (operatingSystem == 'android');

  /// Whether the operating system is a version of
  /// [iOS](https://en.wikipedia.org/wiki/IOS).
  static final bool isIOS = (operatingSystem == 'ios');

  /// Whether the operating system is a version of
  /// [Fuchsia](https://en.wikipedia.org/wiki/Google_Fuchsia).
  static final bool isFuchsia = (operatingSystem == 'fuchsia');

  /// A string representing the operating system or platform.
  static String get operatingSystem {
    final s = web.window.navigator.userAgent.toLowerCase();
    if (s.contains('iphone') ||
        s.contains('ipad') ||
        s.contains('ipod') ||
        s.contains('watch os')) {
      return 'ios';
    }
    if (s.contains('mac os')) {
      return 'macos';
    }
    if (s.contains('fuchsia')) {
      return 'fuchsia';
    }
    if (s.contains('android')) {
      return 'android';
    }
    if (s.contains('linux') || s.contains('cros') || s.contains('chromebook')) {
      return 'linux';
    }
    if (s.contains('windows')) {
      return 'windows';
    }
    return '';
  }

  /// Retrieves the number of processors available on the device.
  static int get numberOfProcessors => web.window.navigator.hardwareConcurrency;
}

/// A reference to a directory (or _folder_) on the file system.
class Directory {
  /// Creates a [Directory] instance.
  Directory([this._path = '']);

  final String _path;

  /// Gets the path of this directory.
  String get path => _path;

  /// Returns the parent directory.
  Directory get parent {
    return Directory();
  }

  /// Creates the directory.
  Future<Directory> create({bool recursive = false}) async {
    throw ArgumentError('This function is not supported on the web.');
  }

  /// System temporary directory
  static Directory get systemTemp {
    return Directory();
  }
}

/// A stub for [IOSink] on the web platform.
///
/// File-based streaming is not supported on web; this class exists solely
/// to satisfy the type system so the library compiles for web/WASM targets.
class IOSink {
  /// Flushes the sink (no-op on web).
  Future<void> flush() async {}

  /// Closes the sink (no-op on web).
  Future<void> close() async {}
}
