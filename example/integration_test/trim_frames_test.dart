import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// H.264 with B-frames (`has_b_frames=2`), 30 fps, 120 frames. Pictures 39
/// to 41 reference P42, and pictures 87 to 89 reference P90.
const _bFrames = 'assets/tests/test_b.mp4';

/// First and end picture of each cut. Every third picture of a 30 fps clip
/// starts on a whole microsecond; a cut a fraction of a microsecond early
/// leaves a sliver of the picture before it, which Darwin renders as a
/// picture of its own.
const _cuts = [(12, 42), (12, 90)];

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
        final bytes = await pve.renderVideo(
          VideoRenderData(
            videoSegments: [
              VideoSegment(
                video: video,
                startTime: source[first],
                endTime: source[end],
              ),
            ],
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
      });
    }
  });
}
