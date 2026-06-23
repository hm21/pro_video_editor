import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('NativeLogLevel.fromMethodValue', () {
    test('parses every canonical methodValue back to its enum', () {
      for (final level in NativeLogLevel.values) {
        expect(
          NativeLogLevel.fromMethodValue(level.methodValue),
          level,
          reason: 'round-trip failed for ${level.methodValue}',
        );
      }
    });

    test('maps the "warn" alias to warning', () {
      expect(NativeLogLevel.fromMethodValue('warn'), NativeLogLevel.warning);
    });

    test('is case-insensitive', () {
      expect(NativeLogLevel.fromMethodValue('ERROR'), NativeLogLevel.error);
    });

    test('falls back to info for unknown values', () {
      expect(
        NativeLogLevel.fromMethodValue('totally-unknown'),
        NativeLogLevel.info,
      );
    });
  });

  group('NativeLogEntry.fromMap', () {
    test('parses all fields', () {
      final entry = NativeLogEntry.fromMap({
        'level': 'error',
        'tag': 'ProVideoEditor-Renderer',
        'message': 'Render failed',
        'timestamp': 1718200000000,
        'stackTrace': 'at Foo.bar(Foo.kt:42)',
      });

      expect(entry.level, NativeLogLevel.error);
      expect(entry.tag, 'ProVideoEditor-Renderer');
      expect(entry.message, 'Render failed');
      expect(
        entry.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1718200000000),
      );
      expect(entry.stackTrace, 'at Foo.bar(Foo.kt:42)');
    });

    test('degrades gracefully for missing/unknown fields', () {
      final entry = NativeLogEntry.fromMap({'level': 'made-up'});

      expect(entry.level, NativeLogLevel.info);
      expect(entry.message, '');
      expect(entry.tag, isNull);
      expect(entry.stackTrace, isNull);
      // Missing timestamp falls back to "now"-ish without throwing.
      expect(entry.timestamp, isA<DateTime>());
    });

    test('toString includes level, tag and message', () {
      final entry = NativeLogEntry.fromMap({
        'level': 'warning',
        'tag': 'ProVideoEditor',
        'message': 'heads up',
        'timestamp': 0,
      });

      expect(entry.toString(), '[WARNING] ProVideoEditor: heads up');
    });
  });
}
