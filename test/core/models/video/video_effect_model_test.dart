import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/utils/video_effect_frames.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoEffect', () {
    group('construction', () {
      test('named constructors set the type', () {
        expect(const VideoEffect.glitch().type, VideoEffectType.glitch);
        expect(const VideoEffect.rgbSplit().type, VideoEffectType.rgbSplit);
        expect(const VideoEffect.vhs().type, VideoEffectType.vhs);
        expect(const VideoEffect.tvStatic().type, VideoEffectType.tvStatic);
        expect(const VideoEffect.pixelate().type, VideoEffectType.pixelate);
        expect(const VideoEffect.pixelPulse().type, VideoEffectType.pixelPulse);
        expect(const VideoEffect.oldFilm().type, VideoEffectType.oldFilm);
        expect(const VideoEffect.strobe().type, VideoEffectType.strobe);
        expect(
          const VideoEffect.negativeFlash().type,
          VideoEffectType.negativeFlash,
        );
        expect(const VideoEffect.vignette().type, VideoEffectType.vignette);
        expect(
          const VideoEffect.blockGlitch().type,
          VideoEffectType.blockGlitch,
        );
        expect(const VideoEffect.filmGrain().type, VideoEffectType.filmGrain);
        expect(
          const VideoEffect.signalInterference().type,
          VideoEffectType.signalInterference,
        );
        expect(const VideoEffect.crt().type, VideoEffectType.crt);
        expect(const VideoEffect.vhs().intensity, 1);
      });

      test('asserts an intensity between 0 and 1', () {
        expect(
          () => VideoEffect.glitch(intensity: 1.2),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VideoEffect.glitch(intensity: -0.1),
          throwsA(isA<AssertionError>()),
        );
      });

      test('an empty range never applies', () {
        const effect = VideoEffect.vhs(
          startTime: Duration(seconds: 2),
          endTime: Duration(seconds: 2),
        );
        expect(effect.isActiveAt(const Duration(seconds: 2)), isFalse);
        expect(
          effect.frameAt(const Duration(seconds: 2)),
          VideoEffectFrame.none,
        );
      });
    });

    group('serialization', () {
      const effect = VideoEffect.vhs(
        intensity: 0.4,
        startTime: Duration(milliseconds: 1500),
        endTime: Duration(seconds: 3),
      );

      test('toMap and fromMap round-trip every field', () {
        expect(effect.toMap(), {
          'type': 'vhs',
          'intensity': 0.4,
          'startTime': 1500000,
          'endTime': 3000000,
        });
        expect(VideoEffect.fromMap(effect.toMap()), effect);
      });

      test('toJson and fromJson round-trip', () {
        expect(VideoEffect.fromJson(effect.toJson()), effect);
      });

      test('fromMap clamps an out-of-range intensity', () {
        final restored = VideoEffect.fromMap({
          'type': 'glitch',
          'intensity': 3,
        });
        expect(restored.intensity, 1);
      });

      test('fromMap rejects an unknown type', () {
        expect(
          () => VideoEffect.fromMap({'type': 'sparkle'}),
          throwsArgumentError,
        );
      });

      test('copyWith replaces only the given fields', () {
        final copy = effect.copyWith(type: VideoEffectType.glitch);
        expect(copy.type, VideoEffectType.glitch);
        expect(copy.intensity, effect.intensity);
        expect(copy.startTime, effect.startTime);
        expect(copy.endTime, effect.endTime);
      });
    });

    group('isActiveAt', () {
      test('covers a half-open range', () {
        const effect = VideoEffect.pixelate(
          startTime: Duration(seconds: 1),
          endTime: Duration(seconds: 2),
        );
        expect(effect.isActiveAt(const Duration(milliseconds: 999)), isFalse);
        expect(effect.isActiveAt(const Duration(seconds: 1)), isTrue);
        expect(effect.isActiveAt(const Duration(milliseconds: 1999)), isTrue);
        expect(effect.isActiveAt(const Duration(seconds: 2)), isFalse);
      });

      test('covers everything without a range', () {
        expect(
          const VideoEffect.pixelate().isActiveAt(const Duration(hours: 1)),
          isTrue,
        );
      });
    });

    group('frameAt', () {
      test('is identity outside the time range and at zero intensity', () {
        const ranged = VideoEffect.vhs(startTime: Duration(seconds: 1));
        expect(ranged.frameAt(Duration.zero), VideoEffectFrame.none);
        expect(
          const VideoEffect.glitch(
            intensity: 0,
          ).frameAt(Duration.zero).isIdentity,
          isTrue,
        );
      });

      test('pixelate is a constant block size that grows with intensity', () {
        const effect = VideoEffect.pixelate(intensity: 0.5);
        expect(effect.frameAt(Duration.zero).pixelSize, closeTo(0.025, 1e-12));
        expect(
          effect.frameAt(const Duration(seconds: 7)),
          effect.frameAt(Duration.zero),
        );
      });

      test('glitch opens with a burst', () {
        final frame = const VideoEffect.glitch().frameAt(Duration.zero);
        expect(frame.bands, isNotEmpty);
        expect(frame.rgbShift.abs(), greaterThan(0.0025));
      });

      test('an animation counts from the effect start', () {
        const late = VideoEffect.glitch(startTime: Duration(seconds: 3));
        for (final offset in [0, 90, 500, 1250]) {
          final local = Duration(milliseconds: offset);
          expect(
            late.frameAt(const Duration(seconds: 3) + local),
            const VideoEffect.glitch().frameAt(local),
          );
        }
      });

      test('an animation repeats every 20 seconds', () {
        const effect = VideoEffect.vhs(intensity: 0.7);
        for (final ms in [0, 333, 4100, 12345]) {
          final t = Duration(milliseconds: ms);
          expect(
            effect.frameAt(t + const Duration(seconds: 20)),
            effect.frameAt(t),
          );
        }
      });

      test('the look changes 24 times per second', () {
        const effect = VideoEffect.vhs();
        // Both inside the first bucket.
        expect(
          effect.frameAt(const Duration(milliseconds: 41)),
          effect.frameAt(Duration.zero),
        );
        // The grain moves with the next bucket.
        expect(
          effect.frameAt(const Duration(microseconds: 41667)),
          isNot(effect.frameAt(Duration.zero)),
        );
      });

      test('rgbSplit punches out each second and swaps sides', () {
        const effect = VideoEffect.rgbSplit();
        final start = effect.frameAt(Duration.zero).rgbShift;
        final settled = effect.frameAt(const Duration(milliseconds: 900));
        final nextSecond = effect.frameAt(const Duration(seconds: 1)).rgbShift;

        expect(start, greaterThan(0));
        expect(settled.rgbShift, inExclusiveRange(0, start / 2));
        expect(nextSecond, closeTo(-start, 1e-12));
        expect(
          effect.frameAt(const Duration(seconds: 2)),
          effect.frameAt(Duration.zero),
        );
      });

      test('pixelPulse breaks up each second and is sharp again in 0.4 s', () {
        const effect = VideoEffect.pixelPulse(intensity: 0.5);
        expect(effect.frameAt(Duration.zero).pixelSize, closeTo(0.045, 1e-12));
        expect(
          effect.frameAt(const Duration(milliseconds: 250)).pixelSize,
          inExclusiveRange(0, 0.045),
        );
        expect(
          effect.frameAt(const Duration(milliseconds: 500)).isIdentity,
          isTrue,
        );
        expect(
          effect.frameAt(const Duration(seconds: 3)),
          effect.frameAt(Duration.zero),
        );
      });

      test('tvStatic flickers every bucket and now and then jumps', () {
        const effect = VideoEffect.tvStatic();
        final frames = [
          for (var b = 0; b < 480; b++)
            effect.frameAt(Duration(microseconds: b * 41667 + 1000)),
        ];

        expect(frames.every((f) => f.noise >= 0.45 && f.noise < 0.65), isTrue);
        expect(frames[0], isNot(frames[1]));
        final jumps = frames.where((f) => f.bands.isNotEmpty).length;
        expect(jumps, inInclusiveRange(20, 100));
      });

      test('vhs scales every operation with intensity', () {
        final strong = const VideoEffect.vhs().frameAt(Duration.zero);
        final weak = const VideoEffect.vhs(
          intensity: 0.5,
        ).frameAt(Duration.zero);
        expect(weak.scanlines, closeTo(strong.scanlines / 2, 1e-12));
        expect(weak.noise, closeTo(strong.noise / 2, 1e-12));
        expect(weak.rgbShift, closeTo(strong.rgbShift / 2, 1e-12));
        expect(weak.noiseOffsetX, strong.noiseOffsetX);
      });

      test('strobe flashes white twice a second and dims in between', () {
        const effect = VideoEffect.strobe(intensity: 0.5);
        Duration bucket(int b) => Duration(microseconds: b * 41667 + 1000);
        expect(effect.frameAt(bucket(0)).flash, closeTo(0.75, 1e-12));
        expect(effect.frameAt(bucket(1)).flash, closeTo(0.4125, 1e-12));
        expect(effect.frameAt(bucket(2)).flash, closeTo(0.15, 1e-12));
        expect(effect.frameAt(bucket(3)).flash, 0);
        expect(effect.frameAt(bucket(3)).brightness, closeTo(-0.25, 1e-12));
        expect(effect.frameAt(bucket(12)), effect.frameAt(bucket(0)));
      });

      test('negativeFlash inverts longer with more intensity', () {
        bool inverted(VideoEffect effect, int bucket) =>
            effect
                .frameAt(Duration(microseconds: bucket * 41667 + 1000))
                .invert ==
            1;
        const weak = VideoEffect.negativeFlash(intensity: 0.3);
        const strong = VideoEffect.negativeFlash();
        expect(
          [
            for (var b = 0; b < 24; b++)
              if (inverted(weak, b)) b,
          ],
          [0, 1],
        );
        expect(
          [
            for (var b = 0; b < 24; b++)
              if (inverted(strong, b)) b,
          ],
          [0, 1, 2, 3, 6],
        );
      });

      // WCAG 2.3.1: content must not flash more than three times a second.
      test('strobe and negativeFlash flash at most three times a second', () {
        for (final effect in const [
          VideoEffect.strobe(),
          VideoEffect.negativeFlash(),
        ]) {
          var flashes = 0;
          var wasOn = false;
          for (var b = 0; b < 24; b++) {
            final frame = effect.frameAt(
              Duration(microseconds: b * 41667 + 1000),
            );
            final on = frame.flash >= 0.5 || frame.invert >= 0.5;
            if (on && !wasOn) flashes++;
            wasOn = on;
          }
          expect(flashes, inInclusiveRange(1, 3), reason: '${effect.type}');
        }
      });

      test('oldFilm tones sepia with grain, flicker and a vignette', () {
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.oldFilm().frameAt(
              Duration(microseconds: b * 41667 + 1000),
            ),
        ];
        expect(frames.every((f) => f.sepia == 0.85), isTrue);
        expect(frames.every((f) => f.vignette == 0.6), isTrue);
        expect(frames.every((f) => f.brightness.abs() <= 0.04), isTrue);
        expect(frames.map((f) => f.brightness).toSet().length, greaterThan(1));
        expect(frames[0].noiseOffsetX, isNot(frames[1].noiseOffsetX));
      });

      // The constructor only asserts the range, so release builds can pass
      // anything; an infinite size would crash the Apple renderer.
      test('clamps an intensity the release build lets through', () {
        for (final type in VideoEffectType.values) {
          final full = videoEffectFrameFor(type, 1, 0);
          expect(videoEffectFrameFor(type, double.infinity, 0), full);
          expect(videoEffectFrameFor(type, 7, 0), full);
          expect(
            videoEffectFrameFor(type, double.nan, 0),
            VideoEffectFrame.none,
          );
          expect(videoEffectFrameFor(type, -1, 0), VideoEffectFrame.none);
        }
      });

      test('vignette is constant and scales with intensity', () {
        const effect = VideoEffect.vignette(intensity: 0.5);
        final frame = effect.frameAt(Duration.zero);
        expect(frame.vignette, closeTo(0.65, 1e-12));
        expect(frame.vignetteRadius, closeTo(0.25, 1e-12));
        expect(effect.frameAt(const Duration(seconds: 7)), frame);
      });

      test('blockGlitch opens on a burst and is untouched in between', () {
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.blockGlitch().frameAt(
              Duration(microseconds: b * 41667 + 1000),
            ),
        ];
        final first = frames.first;
        expect(first.pixelSize, greaterThan(0.015));
        expect(first.bands, isNotEmpty);
        expect(first.rgbShift.abs(), greaterThan(0.008));

        final bursts = frames.where((f) => !f.isIdentity).toList();
        expect(bursts.every((f) => f.pixelSize > 0), isTrue);
        expect(bursts.length, inInclusiveRange(60, 240));
        // A burst keeps its block size while its slices jump.
        expect(frames[1].pixelSize, first.pixelSize);
        expect(frames[1].bands, isNot(first.bands));
      });

      test('blockGlitch scales its blocks and shifts with intensity', () {
        final strong = const VideoEffect.blockGlitch().frameAt(Duration.zero);
        final weak = const VideoEffect.blockGlitch(
          intensity: 0.5,
        ).frameAt(Duration.zero);
        expect(weak.pixelSize, closeTo(strong.pixelSize / 2, 1e-12));
        expect(weak.rgbShift, closeTo(strong.rgbShift / 2, 1e-12));
        expect(
          weak.bands.first.shift,
          closeTo(strong.bands.first.shift / 2, 1e-12),
        );
      });

      test('filmGrain is fine grain of one strength that moves', () {
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.filmGrain(
              intensity: 0.5,
            ).frameAt(Duration(microseconds: b * 41667 + 1000)),
        ];
        for (final frame in frames) {
          expect(
            frame,
            VideoEffectFrame(
              noise: 0.07,
              noiseCellSize: 1 / 900,
              noiseOffsetX: frame.noiseOffsetX,
              noiseOffsetY: frame.noiseOffsetY,
            ),
          );
        }
        expect(frames[0].noiseOffsetX, isNot(frames[1].noiseOffsetX));
      });

      test('signalInterference moves two or three thin slices', () {
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.signalInterference().frameAt(
              Duration(microseconds: b * 41667 + 1000),
            ),
        ];
        for (final frame in frames) {
          final count = frame.bands.length;
          expect(count, inInclusiveRange(2, 3));
          for (final (k, band) in frame.bands.indexed) {
            // Each slice keeps to its own part of the frame, so none overlap.
            expect(band.top, greaterThanOrEqualTo(k / count));
            expect(band.bottom, lessThanOrEqualTo((k + 1) / count));
            expect(band.bottom - band.top, lessThanOrEqualTo(0.02));
            expect(band.shift.abs(), inInclusiveRange(0.015, 0.065));
          }
        }
        expect(frames.map((f) => f.bands.length).toSet(), {2, 3});
        expect(frames[0].bands, isNot(frames[1].bands));
      });

      // A frame carries at most four slices, and the first effect's come
      // first, so an effect that used them all would hide the next one's.
      test('signalInterference leaves room for another slice', () {
        for (var b = 0; b < 480; b++) {
          final at = Duration(microseconds: b * 41667 + 1000);
          final merged = VideoEffect.resolve(const [
            VideoEffect.signalInterference(),
            VideoEffect.vhs(),
          ], at);
          expect(
            merged.bands,
            containsAll(const VideoEffect.vhs().frameAt(at).bands),
            reason: 'bucket $b',
          );
        }
      });

      test('signalInterference opens on a noise burst and calms down', () {
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.signalInterference().frameAt(
              Duration(microseconds: b * 41667 + 1000),
            ),
        ];
        expect(frames.first.noise, greaterThanOrEqualTo(0.3));
        final noisy = frames.where((f) => f.noise > 0).toList();
        expect(noisy.length, inInclusiveRange(20, 120));
        expect(noisy.every((f) => f.rgbShift > 0), isTrue);
        expect(
          frames.where((f) => f.noise == 0).every((f) => f.rgbShift == 0),
          isTrue,
        );
      });

      test('crt is constant scanlines with a slight fringe', () {
        const effect = VideoEffect.crt(intensity: 0.5);
        final frame = effect.frameAt(Duration.zero);
        expect(frame.scanlines, closeTo(0.275, 1e-12));
        expect(frame.scanlinePeriod, closeTo(1 / 200, 1e-12));
        expect(frame.rgbShift, closeTo(0.0015, 1e-12));
        expect(frame.noise, 0);
        expect(frame.bands, isEmpty);
        expect(effect.frameAt(const Duration(milliseconds: 4321)), frame);
      });

      // Pins the look of the effects added after the first release, like the
      // glitch burst below.
      test('keeps the look of the texture effects', () {
        String pin(VideoEffect effect) => effect
            .frameAt(Duration.zero)
            .toList()
            .map((v) => v.toStringAsFixed(6))
            .join(', ');
        expect(
          pin(const VideoEffect.blockGlitch()),
          '0.037686, 0.026367, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 1.000000, 0.800680, 0.946469, 0.100334, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.filmGrain()),
          '0.000000, 0.000000, 0.000000, 0.000000, 0.140000, 0.001111, '
          '42.000000, 81.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.signalInterference()),
          '0.000000, 0.005000, 0.000000, 0.000000, 0.305781, 0.002083, '
          '38.000000, 66.000000, 3.000000, 0.053544, 0.069113, -0.054526, '
          '0.535222, 0.552951, 0.064531, 0.790203, 0.800302, 0.041834, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.crt()),
          '0.000000, 0.003000, 0.550000, 0.005000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.120000, 0.000000, '
          '0.000000, 0.350000, 0.450000',
        );
      });

      // Pins the look: renderers only play frames back, so a change here is a
      // change of what every export looks like, and should be deliberate.
      test('keeps the look of the first glitch burst', () {
        final frame = const VideoEffect.glitch().frameAt(Duration.zero);
        expect(frame.toList().map((v) => v.toStringAsFixed(6)).toList(), [
          '0.000000',
          '-0.021869',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '2.000000',
          '0.747862',
          '0.841436',
          '-0.031928',
          '0.335527',
          '0.350551',
          '-0.086091',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          // sepia, brightness, invert, flash, vignette, vignetteRadius
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
          '0.000000',
        ]);
      });
    });

    group('resolve', () {
      test('merges every active effect', () {
        final frame = VideoEffect.resolve(const [
          VideoEffect.pixelate(),
          VideoEffect.vhs(endTime: Duration(seconds: 1)),
        ], Duration.zero);
        expect(frame.pixelSize, closeTo(0.05, 1e-12));
        expect(frame.scanlines, closeTo(0.3, 1e-12));
      });

      test('skips inactive effects', () {
        final frame = VideoEffect.resolve(const [
          VideoEffect.pixelate(),
          VideoEffect.vhs(endTime: Duration(seconds: 1)),
        ], const Duration(seconds: 1));
        expect(frame, const VideoEffect.pixelate().frameAt(Duration.zero));
      });
    });
  });
}
