import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('NativeFailureDetails.of', () {
    test('reads the platform details off a failed job', () {
      final details = NativeFailureDetails.of(
        PlatformException(
          code: 'RENDER_ERROR',
          message: 'Video frame processing error',
          details: <Object?, Object?>{
            'domain': 'androidx.media3.transformer.ExportException',
            'code': 5001,
            'codeName': 'ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED',
            'cause': 'androidx.media3.effect.VideoFrameProcessingException: gl',
          },
        ),
      );

      expect(details, isNotNull);
      expect(details!.domain, 'androidx.media3.transformer.ExportException');
      expect(details.code, 5001);
      expect(details.codeName, 'ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED');
      expect(
        details.cause,
        'androidx.media3.effect.VideoFrameProcessingException: gl',
      );
    });

    test('leaves the optional fields null when the platform sent none', () {
      final details = NativeFailureDetails.of(
        PlatformException(
          code: 'RENDER_ERROR',
          message: 'Render export stalled after 20s with no progress',
          details: <Object?, Object?>{'domain': 'ExportWatchdog', 'code': 408},
        ),
      );

      expect(details!.domain, 'ExportWatchdog');
      expect(details.code, 408);
      expect(details.codeName, isNull);
      expect(details.cause, isNull);
    });

    test('reads the formats of the sources a failed render read', () {
      final details = NativeFailureDetails.of(
        PlatformException(
          code: 'RENDER_ERROR',
          details: <Object?, Object?>{
            'domain': 'androidx.media3.transformer.ExportException',
            'sources': <Object?>[
              <Object?, Object?>{
                'mime': 'video/avc',
                'bitDepth': 8,
                'transfer': 'sdr',
              },
              <Object?, Object?>{
                'mime': 'video/hevc',
                'bitDepth': 10,
                'transfer': 'hlg',
              },
              <Object?, Object?>{},
            ],
          },
        ),
      );

      final sources = details!.sources!;
      expect(sources, hasLength(3));
      expect(sources[1].mimeType, 'video/hevc');
      expect(sources[1].bitDepth, 10);
      expect(sources[1].colorTransfer, 'hlg');
      expect(sources[2].mimeType, isNull, reason: 'an unreadable source');
      expect(details.hasHdrSource, isTrue);
    });

    test('is null for an error that carries no details', () {
      expect(
        NativeFailureDetails.of(PlatformException(code: 'CANCELED')),
        isNull,
      );
      expect(
        NativeFailureDetails.of(
          PlatformException(code: 'RENDER_ERROR', details: 'a string'),
        ),
        isNull,
      );
      expect(
        NativeFailureDetails.of(
          PlatformException(
            code: 'RENDER_ERROR',
            details: <Object?, Object?>{'code': 1},
          ),
        ),
        isNull,
        reason: 'the domain is what gives a code its meaning',
      );
    });
  });

  group('NativeFailureDetails.isOutOfStorage', () {
    test(
      'recognises AVErrorDiskFull whatever language it was described in',
      () {
        const details = NativeFailureDetails(
          domain: 'AVFoundationErrorDomain',
          code: NativeFailureDetails.avErrorDiskFull,
        );

        expect(details.isOutOfStorage, isTrue);
      },
    );

    test('recognises ENOSPC at the POSIX and Cocoa layers', () {
      expect(
        const NativeFailureDetails(
          domain: 'NSPOSIXErrorDomain',
          code: NativeFailureDetails.posixErrorNoSpace,
        ).isOutOfStorage,
        isTrue,
      );
      expect(
        const NativeFailureDetails(
          domain: 'NSCocoaErrorDomain',
          code: NativeFailureDetails.cocoaErrorWriteOutOfSpace,
        ).isOutOfStorage,
        isTrue,
      );
    });

    test('recognises a full disk reported underneath an export failure', () {
      // AVFoundation usually answers with the generic AVErrorExportFailed and
      // puts the real reason in the underlying chain, described in the
      // device's language.
      const details = NativeFailureDetails(
        domain: 'AVFoundationErrorDomain',
        code: -11800,
        cause:
            'NSPOSIXErrorDomain 28: '
            'Auf dem Volume ist kein Speicherplatz mehr verfügbar.',
      );

      expect(details.isOutOfStorage, isTrue);
    });

    test("recognises Android's ENOSPC in the muxer's cause", () {
      const details = NativeFailureDetails(
        domain: 'androidx.media3.transformer.ExportException',
        code: 7001,
        codeName: 'ERROR_CODE_MUXING_FAILED',
        cause:
            'androidx.media3.muxer.MuxerException: write <- '
            'java.io.IOException: write failed: ENOSPC '
            '(No space left on device)',
      );

      expect(details.isOutOfStorage, isTrue);
    });

    test(
      'does not mistake another code in the same domain for a full disk',
      () {
        const details = NativeFailureDetails(
          domain: 'AVFoundationErrorDomain',
          code: -11828,
        );

        expect(details.isOutOfStorage, isFalse);
      },
    );
  });

  test('toString names the domain, code and cause', () {
    const details = NativeFailureDetails(
      domain: 'AVFoundationErrorDomain',
      code: -11807,
      cause: 'NSOSStatusErrorDomain -17512: ...',
    );

    expect(
      details.toString(),
      'NativeFailureDetails(AVFoundationErrorDomain -11807: '
      'NSOSStatusErrorDomain -17512: ...)',
    );
  });

  group('NativeFailureDetails.hasHdrSource', () {
    test('is false when every source is SDR or states no transfer', () {
      const details = NativeFailureDetails(
        domain: 'androidx.media3.transformer.ExportException',
        sources: [
          NativeSourceFormat(mimeType: 'video/avc', colorTransfer: 'sdr'),
          NativeSourceFormat(mimeType: 'video/hevc', bitDepth: 10),
        ],
      );

      expect(details.hasHdrSource, isFalse);
    });

    test('is false when the platform reported no sources', () {
      const details = NativeFailureDetails(domain: 'AVFoundationErrorDomain');

      expect(details.hasHdrSource, isFalse);
    });

    test('counts PQ as HDR', () {
      const details = NativeFailureDetails(
        domain: 'androidx.media3.transformer.ExportException',
        sources: [NativeSourceFormat(colorTransfer: 'pq')],
      );

      expect(details.hasHdrSource, isTrue);
    });
  });
}
