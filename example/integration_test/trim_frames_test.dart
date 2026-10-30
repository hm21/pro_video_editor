import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// H.264 with B-frames (`has_b_frames=2`), 30 fps, 120 frames. Pictures 39
/// to 41 reference P42, and pictures 87 to 89 reference P90.
const _bFrames = 'assets/tests/test_b.mp4';

/// First and end picture of each cut. Every third picture of a 30 fps clip
/// starts on a whole microsecond, so these cuts hit them exactly.
const _cuts = [(12, 42), (12, 90)];

/// Cuts on pictures that start a third of a microsecond off a whole one, so
/// a microsecond cut lands just before or just after them.
const _fractionalCuts = [(10, 86), (11, 85)];

/// A trimmed segment keeps every source picture before its end. In decode
/// order the reference picture after a cut comes ahead of the B-frames shown
/// before it; ending the segment on that reference lost those B-frames on
/// Android.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final video = EditorVideo.asset(_bFrames);

  Future<List<Duration>> frameTimes(EditorVideo video) async => [
    await for (final frame in pve.getLumaFrameStream(
      LumaFrameConfigs(video: video, outputSize: const ui.Size(64, 64)),
    ))
      frame.time,
  ];

  /// Renders pictures [first] to `end - 1` of [video] cut at [startTime] and
  /// [endTime], and checks that exactly those pictures arrive, each at its
  /// source time.
  Future<void> expectPictures(
    List<Duration> source, {
    required int first,
    required int end,
    required Duration startTime,
    required Duration endTime,
    bool preserveSourceFrameTiming = false,
  }) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: video, startTime: startTime, endTime: endTime),
        ],
        preserveSourceFrameTiming: preserveSourceFrameTiming,
      ),
    );
    final rendered = await frameTimes(EditorVideo.memory(bytes));

    expect(rendered, hasLength(end - first));
    for (var k = 0; k < rendered.length; k++) {
      final expected = source[first + k] - source[first];
      expect(
        (rendered[k] - expected).inMicroseconds.abs(),
        lessThanOrEqualTo(1000),
        reason: 'picture ${first + k}',
      );
    }
  }

  group('trimmed segment', () {
    late List<Duration> source;

    setUpAll(() async {
      source = await frameTimes(video);
    });

    for (final (first, end) in _cuts) {
      testWidgets('keeps pictures $first to ${end - 1} of a B-frame video', (
        tester,
      ) async {
        expect(source, hasLength(120));
        await expectPictures(
          source,
          first: first,
          end: end,
          startTime: source[first],
          endTime: source[end],
        );
      });
    }

    // A frame time read back as whole microseconds is rounded on iOS and
    // truncated on Android, so a cut taken from one lands a fraction of a
    // microsecond before or after the picture it names. Either way the cut
    // means that picture, not a sliver of its neighbour.
    for (final preserveSourceFrameTiming in [false, true]) {
      final timing = preserveSourceFrameTiming
          ? 'source timing'
          : 'fixed clock';
      for (final (first, end) in _fractionalCuts) {
        for (final startRoundsUp in [false, true]) {
          for (final endRoundsUp in [false, true]) {
            testWidgets('keeps pictures $first to ${end - 1} cut '
                '${_rounding(startRoundsUp)} at the start and '
                '${_rounding(endRoundsUp)} at the end ($timing)', (
              tester,
            ) async {
              expect(source, hasLength(120));
              for (final picture in [first, end]) {
                expect(
                  source[picture] - _truncated(picture),
                  anyOf(Duration.zero, const Duration(microseconds: 1)),
                  reason: 'picture $picture starts between whole microseconds',
                );
              }
              await expectPictures(
                source,
                first: first,
                end: end,
                startTime: startRoundsUp
                    ? _roundedUp(first)
                    : _truncated(first),
                endTime: endRoundsUp ? _roundedUp(end) : _truncated(end),
                preserveSourceFrameTiming: preserveSourceFrameTiming,
              );
            });
          }
        }
      }
    }
  });
}

String _rounding(bool roundsUp) => roundsUp ? 'rounded up' : 'truncated';

/// Picture [index] of a 30 fps clip starts at `index / 30` s, which these
/// round down and up to whole microseconds.
Duration _truncated(int index) => Duration(microseconds: index * 100000 ~/ 3);
Duration _roundedUp(int index) =>
    Duration(microseconds: (index * 100000 + 2) ~/ 3);
