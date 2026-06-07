import '/core/platform/io/io_helper.dart';

/// Returns a stub temporary directory for the web platform.
///
/// File-based operations are not supported on web, so this returns
/// a [Directory] stub that throws on actual use.
Future<Directory> getTemporaryDirectory() async {
  return Directory('/tmp');
}
