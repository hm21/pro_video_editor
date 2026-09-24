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
    this.sources,
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
    final sources = details['sources'];
    return NativeFailureDetails(
      domain: domain,
      code: code is int ? code : null,
      codeName: codeName is String ? codeName : null,
      cause: cause is String ? cause : null,
      sources: sources is List
          ? [
              for (final source in sources)
                if (source is Map) NativeSourceFormat._fromMap(source),
            ]
          : null,
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
  /// cause chain on Android, where each entry keeps only the first line of
  /// its message. Null when there is none.
  final String? cause;

  /// The distinct video formats of the sources a failed render read, in
  /// input order; sources that share a format are listed once.
  ///
  /// A failure names what broke, not what it was given: "Video frame
  /// processing error" reads the same for an HDR clip as for an SDR one,
  /// although the two take different GPU paths. Android only; null on Apple
  /// platforms, for any job other than a render, and from a plugin before
  /// 2.16.0.
  final List<NativeSourceFormat>? sources;

  /// Whether any of [sources] is HDR. False when [sources] is null.
  bool get hasHdrSource => sources?.any((source) => source.isHdr) ?? false;

  /// Whether the job failed because the device has no room left for its
  /// output.
  ///
  /// `AVErrorDiskFull`, `ENOSPC` and `NSFileWriteOutOfSpaceError` on Apple
  /// platforms — reported directly, or underneath a generic export failure
  /// such as `AVErrorExportFailed`, which is where AVFoundation usually puts
  /// them; on Android Media3 reports the muxer's `IOException`, whose message
  /// carries the `ENOSPC` errno.
  bool get isOutOfStorage {
    switch ((domain, code)) {
      case ('AVFoundationErrorDomain', avErrorDiskFull):
      case ('NSPOSIXErrorDomain', posixErrorNoSpace):
      case ('NSCocoaErrorDomain', cocoaErrorWriteOutOfSpace):
        return true;
    }
    final cause = this.cause;
    return cause != null && _outOfStorageCauses.any(cause.contains);
  }

  /// What a full disk looks like inside [cause]: an Apple entry is
  /// `<domain> <code>: <description>`, an Android one carries the errno name.
  static const List<String> _outOfStorageCauses = [
    'AVFoundationErrorDomain $avErrorDiskFull:',
    'NSPOSIXErrorDomain $posixErrorNoSpace:',
    'NSCocoaErrorDomain $cocoaErrorWriteOutOfSpace:',
    'ENOSPC',
  ];

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
      '${cause == null ? '' : ': $cause'}'
      '${sources == null ? '' : ' sources: $sources'})';
}

/// The video format of one or more sources of a failed render.
///
/// Read off the file's video track. A source whose track could not be read
/// has every field null.
class NativeSourceFormat {
  /// Creates a source format as the platform reported it.
  const NativeSourceFormat({this.mimeType, this.bitDepth, this.colorTransfer});

  factory NativeSourceFormat._fromMap(Map<Object?, Object?> map) {
    final mimeType = map['mime'];
    final bitDepth = map['bitDepth'];
    final colorTransfer = map['transfer'];
    return NativeSourceFormat(
      mimeType: mimeType is String ? mimeType : null,
      bitDepth: bitDepth is int ? bitDepth : null,
      colorTransfer: colorTransfer is String ? colorTransfer : null,
    );
  }

  /// The video track's MIME type, e.g. `video/hevc`.
  final String? mimeType;

  /// Bits per color channel, e.g. 10 for an HDR recording. Null when the
  /// file does not state it.
  final int? bitDepth;

  /// The transfer function the file states: `sdr`, `hlg`, `pq`, `linear`, or
  /// the platform's raw value for any other. Null when the file states none.
  final String? colorTransfer;

  /// Whether the source is HDR: an HLG or PQ transfer, which is what makes the
  /// renderer tone-map it.
  bool get isHdr => colorTransfer == 'hlg' || colorTransfer == 'pq';

  @override
  String toString() =>
      '${mimeType ?? 'unreadable'}'
      '${bitDepth == null ? '' : ' $bitDepth-bit'}'
      '${colorTransfer == null ? '' : ' $colorTransfer'}';
}
