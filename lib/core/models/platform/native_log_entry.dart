import 'native_log_level.dart';

/// A single log entry forwarded from the native plugin implementation.
///
/// The native renderer (and the rest of the plugin) writes its diagnostics
/// through a shared logging layer that, in addition to the platform console,
/// streams every entry back to Dart. Host apps can listen to
/// [ProVideoEditor.logStream] and pipe these entries into their own Dart
/// logger so they can be exported and analyzed later.
///
/// Forwarding is gated by the same level as the native console output, so the
/// entries you receive match the [NativeLogLevel] requested via the
/// `nativeLogLevel` parameter of the individual operations.
class NativeLogEntry {
  /// Creates a [NativeLogEntry].
  const NativeLogEntry({
    required this.level,
    required this.message,
    required this.timestamp,
    this.tag,
    this.stackTrace,
  });

  /// Parses a [NativeLogEntry] from a platform channel event map.
  ///
  /// Missing or malformed fields degrade gracefully: an unknown level becomes
  /// [NativeLogLevel.info], a missing message becomes an empty string, and a
  /// missing timestamp falls back to the current time.
  factory NativeLogEntry.fromMap(Map<dynamic, dynamic> map) {
    final timestampMs = map['timestamp'];
    final timestamp = timestampMs is int
        ? DateTime.fromMillisecondsSinceEpoch(timestampMs)
        : DateTime.now();

    return NativeLogEntry(
      level: NativeLogLevel.fromMethodValue(
        (map['level'] as String?) ?? 'info',
      ),
      message: (map['message'] as String?) ?? '',
      tag: map['tag'] as String?,
      stackTrace: map['stackTrace'] as String?,
      timestamp: timestamp,
    );
  }

  /// Severity of the log entry.
  final NativeLogLevel level;

  /// The log message emitted by the native side.
  final String message;

  /// Optional source tag (e.g. `ProVideoEditor-Renderer`).
  ///
  /// Android logs always carry a tag. On Darwin a package-wide default tag is
  /// used since the native logger does not track per-call tags.
  final String? tag;

  /// Optional stack trace, present when the native side forwarded a throwable.
  final String? stackTrace;

  /// Timestamp at which the entry was emitted natively.
  final DateTime timestamp;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..write('[${level.methodValue.toUpperCase()}]');
    if (tag != null && tag!.isNotEmpty) {
      buffer.write(' $tag');
    }
    buffer.write(': $message');
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      buffer.write('\n$stackTrace');
    }
    return buffer.toString();
  }
}
