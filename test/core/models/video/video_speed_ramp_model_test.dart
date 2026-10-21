import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group(VideoSpeedRamp, () {
    // Fast run-up, slow motion on the peak, fast landing.
    const hero = VideoSpeedRamp([
      VideoSpeedRampPoint(position: 0, speed: 2),
      VideoSpeedRampPoint(position: 0.4, speed: 0.3),
      VideoSpeedRampPoint(position: 0.6, speed: 0.3),
      VideoSpeedRampPoint(position: 1, speed: 2),
    ]);
    const source = Duration(seconds: 3);

    group('speedAt', () {
      test('passes through every point', () {
        for (final point in hero.points) {
          expect(hero.speedAt(point.position), closeTo(point.speed, 1e-9));
        }
      });

      test('never goes past the points it eases between', () {
        const wave = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0, speed: 1),
          VideoSpeedRampPoint(position: 0.3, speed: 0.3),
          VideoSpeedRampPoint(position: 0.7, speed: 2),
          VideoSpeedRampPoint(position: 1, speed: 1),
        ]);

        for (var i = 0; i <= 1000; i++) {
          final position = i / 1000;
          expect(wave.speedAt(position), inInclusiveRange(0.3, 2));
        }
        // Between 0.3× and 2× the curve rises without dipping back.
        var previous = wave.speedAt(0.3);
        for (var i = 301; i <= 700; i++) {
          final speed = wave.speedAt(i / 1000);
          expect(speed, greaterThanOrEqualTo(previous));
          previous = speed;
        }
      });

      test('holds the outer speeds before the first and after the last '
          'point', () {
        const middle = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0.25, speed: 0.5),
          VideoSpeedRampPoint(position: 0.75, speed: 2),
        ]);

        expect(middle.speedAt(0), 0.5);
        expect(middle.speedAt(0.2), 0.5);
        expect(middle.speedAt(0.8), 2);
        expect(middle.speedAt(1), 2);
      });
    });

    group('steps', () {
      test('cover the segment back to back', () {
        final steps = hero.steps;

        expect(steps.first.start, 0);
        expect(steps.last.end, 1);
        for (var i = 1; i < steps.length; i++) {
          expect(steps[i].start, steps[i - 1].end);
          expect(steps[i].end, greaterThan(steps[i].start));
        }
      });

      test('change speed by at most maxStepChange from one to the next', () {
        // A gentle slope right next to a steep one bends the curve hardest.
        const uneven = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0, speed: 1),
          VideoSpeedRampPoint(position: 0.5, speed: 0.9),
          VideoSpeedRampPoint(position: 0.55, speed: 0.3),
          VideoSpeedRampPoint(position: 1, speed: 0.25),
        ]);

        for (final ramp in [hero, uneven]) {
          final steps = ramp.steps;
          for (var i = 1; i < steps.length; i++) {
            final a = steps[i - 1].speed;
            final b = steps[i].speed;
            final change = a > b ? a / b : b / a;
            expect(change, lessThanOrEqualTo(VideoSpeedRamp.maxStepChange));
          }
        }
      });

      test('keep a stretch between two equal speeds as one step', () {
        final slowMotion = hero.steps.where((s) => s.speed == 0.3);

        expect(slowMotion, hasLength(1));
        expect(slowMotion.single.start, closeTo(0.4, 1e-9));
        expect(slowMotion.single.end, closeTo(0.6, 1e-9));
      });

      test('are a single step for a constant ramp', () {
        const constant = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0, speed: 1.5),
          VideoSpeedRampPoint(position: 1, speed: 1.5),
        ]);

        expect(constant.isConstant, isTrue);
        expect(constant.steps, const [
          VideoSpeedRampStep(start: 0, end: 1, speed: 1.5),
        ]);
      });
    });

    group('durations', () {
      test('a constant ramp plays like a constant speed', () {
        const half = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0, speed: 2),
        ]);

        expect(half.durationFactor, 0.5);
        expect(half.averageSpeed, 2);
        expect(half.outputDuration(source), const Duration(milliseconds: 1500));
      });

      test('outputDuration is where the last source frame plays', () {
        expect(
          hero.sourceToOutput(source, sourceDuration: source),
          hero.outputDuration(source),
        );
        // The slow middle outweighs the fast ends.
        expect(hero.outputDuration(source), greaterThan(source));
      });

      test('sourceToOutput and outputToSource undo each other', () {
        final output = hero.outputDuration(source);

        for (var ms = 0; ms <= output.inMilliseconds; ms += 37) {
          final outputOffset = Duration(milliseconds: ms);
          final sourceOffset = hero.outputToSource(
            outputOffset,
            sourceDuration: source,
          );
          final back = hero.sourceToOutput(
            sourceOffset,
            sourceDuration: source,
          );
          expect(
            (back - outputOffset).inMicroseconds.abs(),
            lessThanOrEqualTo(2),
          );
        }
      });

      test('the slow middle takes a larger share of the output than of the '
          'source', () {
        final slowStart = hero.sourceToOutput(
          source * 0.4,
          sourceDuration: source,
        );
        final slowEnd = hero.sourceToOutput(
          source * 0.6,
          sourceDuration: source,
        );

        // 20 % of the source at 0.3× plays for two thirds of its length.
        expect(
          (slowEnd - slowStart).inMicroseconds,
          closeTo((source * 0.2).inMicroseconds / 0.3, 2),
        );
      });

      test('clamp offsets to the segment', () {
        expect(
          hero.sourceToOutput(source * 2, sourceDuration: source),
          hero.outputDuration(source),
        );
        expect(
          hero.outputToSource(const Duration(hours: 1), sourceDuration: source),
          source,
        );
        expect(
          hero.sourceToOutput(-source, sourceDuration: source),
          Duration.zero,
        );
      });
    });

    group('cropped', () {
      test('keeps the speeds of the part it takes', () {
        final tail = hero.cropped(0.5, 1);

        expect(tail.points.first.position, 0);
        expect(tail.points.first.speed, closeTo(hero.speedAt(0.5), 1e-9));
        expect(
          tail.points.last,
          const VideoSpeedRampPoint(position: 1, speed: 2),
        );
        // The point at 0.6 lands a fifth of the way into the second half.
        expect(tail.points[1].position, closeTo(0.2, 1e-9));
        expect(tail.points[1].speed, 0.3);
      });

      test('plays the steps the whole played there, cut at its edges', () {
        final part = hero.cropped(0.3, 0.8);

        expect(part.steps.first.start, 0);
        expect(part.steps.last.end, 1);
        for (final step in part.steps) {
          // Back on the whole's positions, the same speed plays there.
          final middle = 0.3 + 0.5 * (step.start + step.end) / 2;
          final original = hero.steps.firstWhere(
            (s) => s.start <= middle && middle < s.end,
          );
          expect(step.speed, original.speed);
        }
        for (var i = 1; i < part.steps.length; i++) {
          expect(part.steps[i].start, part.steps[i - 1].end);
        }
      });

      test('splits the playback time without moving the cut', () {
        // A cut in the middle of the slow-down, where easing a new curve into
        // the cut used to move it by several frames.
        const sixSeconds = Duration(seconds: 6);
        const cut = Duration(seconds: 4);
        final at = cut.inMicroseconds / sixSeconds.inMicroseconds;
        final head = hero.cropped(0, at).outputDuration(cut);
        final tail = hero.cropped(at, 1).outputDuration(sixSeconds - cut);

        expect(
          (head - hero.sourceToOutput(cut, sourceDuration: sixSeconds))
              .inMicroseconds
              .abs(),
          lessThanOrEqualTo(1),
        );
        expect(
          (head + tail - hero.outputDuration(sixSeconds)).inMicroseconds.abs(),
          lessThanOrEqualTo(1),
        );
      });

      test('keeps the curve its frames had', () {
        final part = hero.cropped(0.3, 0.8);

        for (var i = 0; i <= 10; i++) {
          final position = i / 10;
          expect(
            part.speedAt(position),
            closeTo(hero.speedAt(0.3 + 0.5 * position), 1e-12),
          );
        }
      });

      test('crops a crop as a stretch of the original ramp', () {
        final twice = hero.cropped(0.2, 0.8).cropped(0.5, 1);

        expect(twice, hero.cropped(0.5, 0.8));
        expect(twice.steps, hero.cropped(0.5, 0.8).steps);
      });

      test('keeps the edge a crop of a crop leaves alone', () {
        // 0.3 + (0.9 - 0.3) is 0.9000000000000001 in doubles.
        final part = hero.cropped(0.3, 0.9);
        const middle = 0.3 + (0.9 - 0.3) * 0.5;

        expect(part.cropped(0.5, 1), hero.cropped(middle, 0.9));
        expect(part.cropped(0, 0.5), hero.cropped(0.3, middle));
        expect(part.speedAt(0), part.points.first.speed);
        expect(part.speedAt(1), part.points.last.speed);
      });

      test('round-trips through toMap and fromMap', () {
        final part = hero.cropped(0.25, 0.7);
        final restored = VideoSpeedRamp.fromMap(part.toMap());

        expect(restored, part);
        expect(restored.steps, part.steps);
      });

      test('plays its points without a usable original ramp', () {
        final part = hero.cropped(0.25, 0.7);
        final map = part.toMap();
        (map['crop'] as Map)['source'] = <String, dynamic>{'points': []};

        expect(VideoSpeedRamp.fromMap(map), VideoSpeedRamp(part.points));
      });

      test('reverses as the crop of the reversed ramp', () {
        final part = hero.cropped(0.1, 0.45);

        expect(part.reversed, hero.reversed.cropped(0.55, 0.9));
        expect(
          part.reversed.outputDuration(source),
          hero.reversed.cropped(0.55, 0.9).outputDuration(source),
        );
      });

      test('is constant when the part it takes plays at one speed', () {
        expect(hero.cropped(0.45, 0.55).isConstant, isTrue);
        expect(hero.cropped(0.3, 0.55).isConstant, isFalse);
      });

      test('returns the ramp itself for the whole segment', () {
        expect(identical(hero.cropped(0, 1), hero), isTrue);
      });
    });

    group('reversed', () {
      test('keeps every frame at its speed', () {
        final backwards = hero.reversed;

        for (var i = 0; i <= 20; i++) {
          final position = i / 20;
          expect(
            backwards.speedAt(1 - position),
            closeTo(hero.speedAt(position), 1e-9),
          );
        }
        expect(backwards.outputDuration(source), hero.outputDuration(source));
      });
    });

    group('serialization', () {
      test('round-trips through toMap and fromMap', () {
        expect(VideoSpeedRamp.fromMap(hero.toMap()), hero);
      });

      test('sends its steps over the platform channel', () async {
        final map = await VideoSegment(
          video: EditorVideo.file('test.mp4'),
          speedRamp: hero,
        ).toAsyncMap();

        expect(map['speedRamp'], hero.toChannelSteps());
        expect(map['playbackSpeed'], isNull);
        expect(
          (map['speedRamp'] as List<Map<String, double>>).first.keys,
          containsAll(['start', 'end', 'speed']),
        );
      });

      test('round-trips on a VideoSegment', () {
        final segment = VideoSegment(
          video: EditorVideo.asset('assets/test.mp4'),
          endTime: const Duration(seconds: 3),
          speedRamp: hero,
        );

        expect(VideoSegment.fromMap(segment.toMap()).speedRamp, hero);
        expect(segment.copyWith(volume: 0.5).speedRamp, hero);
      });

      test('copyWith swaps between a ramp and a constant speed', () {
        final ramped = VideoSegment(
          video: EditorVideo.asset('assets/test.mp4'),
          speedRamp: hero,
        );

        final constant = ramped.copyWith(playbackSpeed: 2);
        expect(constant.playbackSpeed, 2);
        expect(constant.speedRamp, isNull);

        final rampedAgain = constant.copyWith(speedRamp: hero);
        expect(rampedAgain.speedRamp, hero);
        expect(rampedAgain.playbackSpeed, isNull);
      });
    });

    group('validation', () {
      test('rejects a speed of zero', () {
        const ramp = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0, speed: 1),
          VideoSpeedRampPoint(position: 1, speed: 0),
        ]);

        expect(() => ramp.steps, throwsArgumentError);
      });

      test('rejects points out of order', () {
        const ramp = VideoSpeedRamp([
          VideoSpeedRampPoint(position: 0.5, speed: 1),
          VideoSpeedRampPoint(position: 0.2, speed: 2),
        ]);

        expect(() => ramp.speedAt(0.3), throwsArgumentError);
      });

      test('rejects a segment with both a speed and a ramp', () {
        expect(
          () => VideoSegment(
            video: EditorVideo.asset('assets/test.mp4'),
            playbackSpeed: 2,
            speedRamp: hero,
          ),
          throwsAssertionError,
        );
      });
    });
  });
}
