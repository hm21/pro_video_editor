import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  Duration frame(int i) => Duration(microseconds: (i * 1e6 / 30).round());

  /// A track along a straight line, [jitter] fractions off it on every other
  /// frame, growing by the same factor every frame, marked on frame [anchor].
  VideoObjectTrack line({int frames = 30, int anchor = 0, double jitter = 0}) =>
      VideoObjectTrack(
        anchorTime: frame(anchor),
        samples: [
          for (var i = 0; i < frames; i++)
            ObjectTrackSample(
              time: frame(i),
              center: Offset(
                0.2 + 0.01 * i + (i.isEven ? jitter : -jitter),
                0.5 - 0.004 * i,
              ),
              size: Size(
                0.1 * exp(0.01 * (i - anchor)),
                0.2 * exp(0.01 * (i - anchor)),
              ),
              scale: exp(0.01 * (i - anchor)),
              rotation: 0.002 * (i - anchor),
            ),
        ],
      );

  group(VideoObjectTrack, () {
    test('survives a round trip through its map', () {
      final track = VideoObjectTrack(
        anchorTime: frame(3),
        reachedStart: false,
        samples: [
          for (var i = 0; i < 5; i++)
            ObjectTrackSample(
              time: frame(i + 1),
              center: Offset(0.1 * i, 0.2),
              size: const Size(0.3, 0.25),
              scale: 1 + 0.1 * i,
              rotation: -0.05 * i,
            ),
        ],
      );
      expect(VideoObjectTrack.fromMap(track.toMap()), track);
    });

    test('names its marked frame and whether it got past it', () {
      final track = line(frames: 5, anchor: 2);
      expect(track.anchor, track.samples[2]);
      expect(track.isFollowed, isTrue);

      final alone = VideoObjectTrack(
        anchorTime: Duration.zero,
        samples: [track.samples.first],
      );
      expect(alone.isFollowed, isFalse);
    });

    group('smoothed', () {
      test('takes the jitter out of a straight path', () {
        final raw = line(jitter: 0.004);
        final smooth = raw.smoothed();
        double offLine(ObjectTrackSample s, int i) =>
            (s.center.dx - (0.2 + 0.01 * i)).abs();
        for (var i = 0; i < raw.samples.length; i++) {
          expect(
            offLine(smooth.samples[i], i),
            lessThan(offLine(raw.samples[i], i)),
            reason: '$i',
          );
        }
        // Away from the ends, where a fit sees both sides, almost all of it.
        for (var i = 4; i < raw.samples.length - 4; i++) {
          expect(offLine(smooth.samples[i], i), lessThan(0.0005), reason: '$i');
        }
      });

      test('keeps a steady motion where it is, at the ends too', () {
        final raw = line(anchor: 15);
        final smooth = raw.smoothed();
        for (var i = 0; i < raw.samples.length; i++) {
          final a = raw.samples[i];
          final b = smooth.samples[i];
          expect(b.time, a.time);
          expect(b.center.dx, closeTo(a.center.dx, 1e-6), reason: '$i');
          expect(b.center.dy, closeTo(a.center.dy, 1e-6), reason: '$i');
          expect(b.rotation, closeTo(a.rotation, 1e-6), reason: '$i');
          expect(b.scale, closeTo(a.scale, 1e-6), reason: '$i');
        }
      });

      test('keeps the size in step with the scale', () {
        final smooth = line(jitter: 0.003, anchor: 10).smoothed();
        final marked = smooth.anchor!;
        expect(marked.scale, 1);
        expect(marked.rotation, 0);
        for (final s in smooth.samples) {
          expect(s.size.width, closeTo(marked.size.width * s.scale, 1e-12));
          expect(s.size.height, closeTo(marked.size.height * s.scale, 1e-12));
        }
      });

      test('leaves a track without smoothing as it is', () {
        final track = line(jitter: 0.003);
        expect(
          identical(
            track.smoothed(position: Duration.zero, shape: Duration.zero),
            track,
          ),
          isTrue,
        );
        final short = line(frames: 2);
        expect(identical(short.smoothed(), short), isTrue);
      });

      test('rounds off a corner rather than cutting it with a jump', () {
        final corner = VideoObjectTrack(
          anchorTime: Duration.zero,
          samples: [
            for (var i = 0; i < 30; i++)
              ObjectTrackSample(
                time: frame(i),
                center: Offset(0.2 + 0.01 * min(i, 15), 0.5),
                size: const Size(0.1, 0.1),
              ),
          ],
        ).smoothed();
        final xs = [for (final s in corner.samples) s.center.dx];
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThanOrEqualTo(xs[i - 1] - 1e-4), reason: '$i');
        }
        expect(xs[15], lessThan(0.35));
        expect(xs.last, closeTo(0.35, 1e-6));
      });
    });
  });
}
