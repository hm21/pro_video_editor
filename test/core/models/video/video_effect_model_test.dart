import 'dart:math' as math;

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
        expect(const VideoEffect.shake().type, VideoEffectType.shake);
        expect(const VideoEffect.zoomPulse().type, VideoEffectType.zoomPulse);
        expect(const VideoEffect.mirror().type, VideoEffectType.mirror);
        expect(
          const VideoEffect.kaleidoscope().type,
          VideoEffectType.kaleidoscope,
        );
        expect(
          const VideoEffect.splitScreen().type,
          VideoEffectType.splitScreen,
        );
        expect(const VideoEffect.wave().type, VideoEffectType.wave);
        expect(const VideoEffect.glow().type, VideoEffectType.glow);
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

      test('toMap and fromMap round-trip the triggers', () {
        const triggered = VideoEffect.zoomPulse(
          triggers: [Duration(milliseconds: 500), Duration(seconds: 1)],
        );
        expect(triggered.toMap()['triggers'], [500000, 1000000]);
        expect(VideoEffect.fromMap(triggered.toMap()), triggered);
        expect(
          VideoEffect.fromMap(triggered.toMap()..remove('triggers')),
          const VideoEffect.zoomPulse(),
        );
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
        expect(copy.triggers, effect.triggers);
        expect(
          effect.copyWith(triggers: const [Duration(seconds: 2)]).triggers,
          const [Duration(seconds: 2)],
        );
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
      test('no effect flashes more than three times a second', () {
        for (final type in VideoEffectType.values) {
          final length = videoEffectCycleLengthOf(type);
          final frames = [
            for (var b = 0; b < length; b++) videoEffectFrameFor(type, 1, b),
          ];
          // The buckets in which a white flash or a negative starts, through
          // the cycle and one second past it, so a wrap is counted too.
          final onsets = <int>[];
          var wasOn = false;
          for (var b = 0; b < length + videoEffectFrameRate; b++) {
            final frame = frames[b % length];
            final on = frame.flash >= 0.5 || frame.invert >= 0.5;
            if (on && !wasOn) onsets.add(b);
            wasOn = on;
          }
          for (var start = 0; start < length; start++) {
            final inOneSecond = onsets.where(
              (b) => b >= start && b < start + videoEffectFrameRate,
            );
            expect(inOneSecond.length, lessThanOrEqualTo(3), reason: '$type');
          }
          if (type == VideoEffectType.strobe ||
              type == VideoEffectType.negativeFlash) {
            expect(onsets, isNotEmpty, reason: '$type');
          } else {
            // A brightness that changes by a tenth would be a flash as well;
            // the strobe's dimming is part of its flashes.
            final levels = frames.map((f) => f.brightness);
            expect(
              levels.reduce(math.max) - levels.reduce(math.min),
              lessThan(0.1),
              reason: '$type',
            );
          }
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

        // More intensity bursts more often.
        int bursts(double intensity) => [
          for (var b = 0; b < 480; b++)
            videoEffectFrameFor(VideoEffectType.blockGlitch, intensity, b),
        ].where((f) => !f.isIdentity).length;
        expect(bursts(0.2), lessThan(bursts(1)));
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

        // More intensity bursts more often.
        int bursts(double intensity) => [
          for (var b = 0; b < 480; b++)
            videoEffectFrameFor(
              VideoEffectType.signalInterference,
              intensity,
              b,
            ),
        ].where((f) => f.noise > 0).length;
        expect(bursts(0.2), lessThan(bursts(1)));
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
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.crt()),
          '0.000000, 0.003000, 0.550000, 0.005000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.120000, 0.000000, '
          '0.000000, 0.350000, 0.450000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
      });

      // The opening frames pinned above always burst; this pins when the
      // bursts that follow come.
      test('keeps the timing of the texture effects\' bursts', () {
        Duration bucket(int b) => Duration(microseconds: b * 41667 + 1000);
        // Blocks mark a blockGlitch burst, noise a signalInterference one.
        bool isBurst(VideoEffectFrame f) => f.pixelSize > 0 || f.noise > 0;
        List<int> bursts(VideoEffect effect) => [
          for (var b = 0; b < 48; b++)
            if (isBurst(effect.frameAt(bucket(b)))) b,
        ];
        final blockGlitch = bursts(const VideoEffect.blockGlitch());
        expect(blockGlitch, [0, 1, 2, 3, 18, 19, 20, 24, 25, 26, 36, 37]);
        final interference = bursts(const VideoEffect.signalInterference());
        expect(interference, [0, 1, 8, 9, 16, 17, 18, 32, 40, 41, 42]);
      });

      test('shake jumps every bucket without showing the edges', () {
        Duration bucket(int b) => Duration(microseconds: b * 41667 + 1000);
        final frames = [
          for (var b = 0; b < 480; b++)
            const VideoEffect.shake().frameAt(bucket(b)),
        ];
        for (final frame in frames) {
          // The zoomed picture reaches zoom / 2 past each edge.
          expect(frame.offsetX.abs(), lessThan(frame.zoom / 2));
          expect(frame.offsetY.abs(), lessThan(frame.zoom / 2));
          expect(frame.offsetX.abs(), lessThanOrEqualTo(0.02));
        }
        expect(frames.map((f) => f.zoom).toSet(), {closeTo(0.044, 1e-12)});
        expect(frames[0].offsetX, isNot(frames[1].offsetX));
        expect(frames.map((f) => f.offsetX.sign).toSet(), {-1.0, 1.0});
        expect(
          const VideoEffect.shake(intensity: 0.5).frameAt(bucket(3)).offsetY,
          closeTo(frames[3].offsetY / 2, 1e-12),
        );
      });

      test('zoomPulse punches in every half second and eases out', () {
        const effect = VideoEffect.zoomPulse(intensity: 0.8);
        Duration bucket(int b) => Duration(microseconds: b * 41667 + 1000);
        final zooms = [
          for (var b = 0; b < 12; b++) effect.frameAt(bucket(b)).zoom,
        ];
        expect(zooms.first, closeTo(0.2, 1e-12));
        for (var b = 1; b < 12; b++) {
          expect(zooms[b], lessThan(zooms[b - 1]));
        }
        expect(zooms.last, lessThan(0.002));
        expect(effect.frameAt(bucket(12)), effect.frameAt(bucket(0)));
      });

      test('mirror and kaleidoscope stay symmetric and zoom in below full '
          'intensity', () {
        expect(
          const VideoEffect.mirror().frameAt(const Duration(seconds: 9)),
          const VideoEffectFrame(mirrorX: 0.5),
        );
        final mirror = const VideoEffect.mirror(
          intensity: 0.6,
        ).frameAt(Duration.zero);
        expect(mirror.mirrorX, 0.5);
        expect(mirror.zoom, closeTo(0.4, 1e-12));
        expect(
          const VideoEffect.kaleidoscope().frameAt(Duration.zero),
          const VideoEffectFrame(mirrorX: 0.5, mirrorY: 0.5),
        );
      });

      test('splitScreen shows the whole picture four times at full '
          'intensity and zooms in below it', () {
        expect(
          const VideoEffect.splitScreen().frameAt(Duration.zero),
          const VideoEffectFrame(tiles: 2),
        );
        final weak = const VideoEffect.splitScreen(
          intensity: 0.25,
        ).frameAt(const Duration(seconds: 4));
        expect(weak.tiles, 2);
        expect(weak.zoom, closeTo(0.75, 1e-12));
      });

      test('wave rolls up by one wave every two seconds', () {
        const effect = VideoEffect.wave(intensity: 0.4);
        final start = effect.frameAt(Duration.zero);
        expect(start.waveAmplitude, closeTo(0.01, 1e-12));
        // Zoomed in past the bend: the frame's edges show the bent picture
        // zoom / 2 / (1 + zoom) of the width in from its edges.
        expect(start.zoom, closeTo(0.022, 1e-12));
        expect(start.zoom / 2 / (1 + start.zoom), greaterThan(0.01));
        expect(start.wavePeriod, 0.5);
        expect(start.wavePhase, 0);
        expect(
          effect.frameAt(const Duration(seconds: 1)).wavePhase,
          closeTo(0.5, 1e-12),
        );
        expect(effect.frameAt(const Duration(seconds: 2)), start);
      });

      // Pins the look of the geometric effects, like the glitch burst below.
      test('keeps the look of the geometric effects', () {
        String pin(VideoEffect effect) => effect
            .frameAt(const Duration(milliseconds: 100))
            .toList()
            .sublist(27, 36)
            .map((v) => v.toStringAsFixed(6))
            .join(', ');
        expect(
          pin(const VideoEffect.shake()),
          '0.044000, 0.018089, -0.007385, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.zoomPulse()),
          '0.173611, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.splitScreen(intensity: 0.7)),
          '0.300000, 0.000000, 0.000000, 0.000000, 0.000000, 2.000000, '
          '0.000000, 0.000000, 0.000000',
        );
        expect(
          pin(const VideoEffect.wave()),
          '0.055000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, '
          '0.025000, 0.500000, 0.041667',
        );
      });

      test('glow is constant, stronger and lower with more intensity', () {
        const effect = VideoEffect.glow(intensity: 0.5);
        final frame = effect.frameAt(Duration.zero);
        expect(frame.glow, closeTo(1, 1e-12));
        expect(frame.glowThreshold, closeTo(0.71, 1e-12));
        expect(frame.glowRadius, 0.035);
        expect(effect.frameAt(const Duration(seconds: 7)), frame);
        final full = const VideoEffect.glow().frameAt(Duration.zero);
        expect(full.glow, closeTo(2, 1e-12));
        expect(full.glowThreshold, closeTo(0.64, 1e-12));
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
          // zoom, offsetX, offsetY, mirrorX, mirrorY, tiles, waveAmplitude,
          // wavePeriod, wavePhase
          for (var i = 0; i < 9; i++) '0.000000',
          // glow, glowThreshold, glowRadius
          for (var i = 0; i < 3; i++) '0.000000',
        ]);
      });
    });

    group('triggers', () {
      Duration ms(int milliseconds) => Duration(milliseconds: milliseconds);

      test('shows nothing until the first trigger and once a hit has '
          'played', () {
        final effect = VideoEffect.zoomPulse(triggers: [ms(1000)]);
        expect(effect.frameAt(ms(500)), VideoEffectFrame.none);
        expect(
          effect.frameAt(ms(1000)),
          videoEffectFrameFor(VideoEffectType.zoomPulse, 1, 0),
        );
        // One zoom punch is half a second.
        expect(effect.frameAt(ms(1490)), isNot(VideoEffectFrame.none));
        expect(effect.frameAt(ms(1500)), VideoEffectFrame.none);
      });

      test('plays each hit from the start of its animation', () {
        final effect = VideoEffect.zoomPulse(triggers: [ms(1000), ms(1300)]);
        expect(
          effect.frameAt(ms(1200)),
          videoEffectFrameFor(VideoEffectType.zoomPulse, 1, 4),
        );
        expect(
          effect.frameAt(ms(1300)),
          videoEffectFrameFor(VideoEffectType.zoomPulse, 1, 0),
        );
      });

      test('counts triggers from the start, in any order, on the nearest '
          'step', () {
        final effect = VideoEffect.zoomPulse(
          startTime: ms(1000),
          triggers: [const Duration(microseconds: 1503000), ms(1200)],
        );
        // 1.503 s lands on the step at 1.5 s.
        expect(
          effect.frameAt(ms(1500)),
          videoEffectFrameFor(VideoEffectType.zoomPulse, 1, 0),
        );
        expect(
          effect.frameAt(ms(1450)),
          videoEffectFrameFor(VideoEffectType.zoomPulse, 1, 6),
        );
      });

      test('ignores triggers outside its time range', () {
        final effect = VideoEffect.zoomPulse(
          startTime: ms(1000),
          endTime: ms(2000),
          triggers: [ms(500), ms(2000), ms(2500)],
        );
        for (var t = 0; t < 3000; t += 50) {
          expect(effect.frameAt(ms(t)), VideoEffectFrame.none, reason: '$t');
        }
      });

      test('a flashing effect flashes once per trigger, without dimming in '
          'between', () {
        final triggers = [for (var t = 0; t < 3000; t += 400) ms(t)];
        for (final type in [
          VideoEffectType.strobe,
          VideoEffectType.negativeFlash,
        ]) {
          final effect = VideoEffect(type: type, triggers: triggers);
          var onsets = 0;
          var wasOn = false;
          for (var step = 0; step < 3 * videoEffectTriggerFrameRate; step++) {
            final frame = effect.frameAt(
              Duration(microseconds: step * 1000000 ~/ 120),
            );
            final on = frame.flash >= 0.5 || frame.invert >= 0.5;
            if (on && !wasOn) onsets++;
            wasOn = on;
            expect(frame.brightness, 0, reason: '$type at step $step');
          }
          expect(onsets, triggers.length, reason: '$type');
        }
      });

      test('a glitch bursts through its whole hit, differently on each '
          'hit', () {
        for (final type in [
          VideoEffectType.glitch,
          VideoEffectType.blockGlitch,
        ]) {
          final effect = VideoEffect(type: type, triggers: [ms(0), ms(500)]);
          for (final hit in [0, 500]) {
            for (var bucket = 0; bucket < 4; bucket++) {
              final frame = effect.frameAt(ms(hit + bucket * 1000 ~/ 24 + 1));
              expect(frame.bands, isNotEmpty, reason: '$type $hit $bucket');
              expect(frame.rgbShift.abs(), greaterThan(0.005));
            }
          }
          expect(effect.frameAt(ms(1)), isNot(effect.frameAt(ms(501))));
        }
      });

      test('rgbSplit swaps sides on every other hit', () {
        final effect = VideoEffect.rgbSplit(triggers: [ms(0), ms(500)]);
        expect(effect.frameAt(ms(0)).rgbShift, greaterThan(0));
        expect(effect.frameAt(ms(500)).rgbShift, lessThan(0));
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
