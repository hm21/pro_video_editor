import 'package:flutter/services.dart';

/// What the platform reported behind a failed job's [PlatformException].
///
/// The exception's message is the platform's own description of the failure,
/// written for a person in that person's language: AVFoundation's
/// `AVErrorDiskFull` reads "Disk Full" on an English device and "Das Volume
/// ist voll." on a German one, and Media3 reduces every failure to one line
/// per error code ("Video frame processing error") with the exception
/// underneath dropped. Neither is something an app can branch on. These
/// details are: the error's domain and code, and the chain of causes below it.
///
/// Attached to `RENDER_ERROR`, `SPLIT_ERROR`, `EXTRACT_ERROR` and
/// `MERGE_ERROR`. A cancellation, an argument error and a plugin built before
/// 2.13.0 carry none, so [of] is nullable.
class NativeFailureDetails {
  /// Creates details as the platform attached them.
  const NativeFailureDetails({
    required this.domain,
    this.code,
    this.codeName,
    this.cause,
  });

  /// Reads the details a native handler attached to [error], or `null` when
  /// it attached none.
  static NativeFailureDetails? of(PlatformException error) {
    final details = error.details;
    if (details is! Map) return null;
    final domain = details['domain'];
    if (domain is! String) return null;
    final code = details['code'];
    final codeName = details['codeName'];
    final cause = details['cause'];
    return NativeFailureDetails(
      domain: domain,
      code: code is int ? code : null,
      codeName: codeName is String ? codeName : null,
      cause: cause is String ? cause : null,
    );
  }

  /// Who defined [code].
  ///
  /// On Apple platforms the `NSError.domain`: `AVFoundationErrorDomain`,
  /// `NSPOSIXErrorDomain`, the plugin's own `ExportWatchdog`, or a Swift
  /// error's type name. On Android the outermost throwable's class name, e.g.
  /// `androidx.media3.transformer.ExportException`.
  final String domain;

  /// The platform's numeric code within [domain]: `NSError.code` on Apple
  /// platforms, `ExportException.errorCode` on Android. Null on Android when
  /// no `ExportException` was involved.
  final int? code;

  /// Media3's name for [code], e.g. `ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED`.
  /// Apple platforms have none.
  final String? codeName;

  /// The failures underneath the reported one, outermost first, joined with
  /// ` <- `: the `NSUnderlyingErrorKey` chain on Apple platforms, the Java
  /// cause chain on Android. Null when there is none.
  final String? cause;

  /// Whether the job failed because the device has no room left for its
  /// output.
  ///
  /// `AVErrorDiskFull`, `ENOSPC` and `NSFileWriteOutOfSpaceError` on Apple
  /// platforms; on Android Media3 reports the muxer's `IOException`, whose
  /// message carries the `ENOSPC` errno.
  bool get isOutOfStorage => switch ((domain, code)) {
    ('AVFoundationErrorDomain', avErrorDiskFull) => true,
    ('NSPOSIXErrorDomain', posixErrorNoSpace) => true,
    ('NSCocoaErrorDomain', cocoaErrorWriteOutOfSpace) => true,
    _ => cause?.contains('ENOSPC') ?? false,
  };

  /// `AVError.Code.diskFull`.
  static const int avErrorDiskFull = -11807;

  /// `ENOSPC`.
  static const int posixErrorNoSpace = 28;

  /// `NSFileWriteOutOfSpaceError`.
  static const int cocoaErrorWriteOutOfSpace = 640;

  @override
  String toString() =>
      'NativeFailureDetails($domain'
      '${code == null ? '' : ' $code'}'
      '${codeName == null ? '' : ' $codeName'}'
      '${cause == null ? '' : ': $cause'})';
}
