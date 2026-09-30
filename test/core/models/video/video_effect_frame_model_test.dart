import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoEffectFrame', () {
    const bands = [
      VideoEffectBand(top: 0.1, bottom: 0.2, shift: 0.05),
      VideoEffectBand(top: 0.5, bottom: 0.7, shift: -0.1),
    ];
    const frame = VideoEffectFrame(
      pixelSize: 0.03,
      rgbShift: -0.01,
      scanlines: 0.25,
      scanlinePeriod: 1 / 270,
      noise: 0.1,
      noiseCellSize: 1 / 540,
      noiseOffsetX: 17,
      noiseOffsetY: 120,
      bands: bands,
      sepia: 0.5,
      brightness: -0.02,
      invert: 0.25,
      flash: 0.75,
      vignette: 0.6,
      vignetteRadius: 0.3,
    );

    group('toList', () {
      test('writes the layout the native renderers read', () {
        final values = frame.toList();
        expect(values, hasLength(VideoEffectFrame.stride));
        expect(values.sublist(0, 9), [
          0.03,
          -0.01,
          0.25,
          1 / 270,
          0.1,
          1 / 540,
          17,
          120,
          2,
        ]);
        expect(values.sublist(9, 15), [0.1, 0.2, 0.05, 0.5, 0.7, -0.1]);
        expect(values.sublist(15, 21), everyElement(0));
        expect(values.sublist(21), [0.5, -0.02, 0.25, 0.75, 0.6, 0.3]);
      });

      test('round-trips through fromList at an offset', () {
        final values = [1.0, 2.0, ...frame.toList()];
        expect(VideoEffectFrame.fromList(values, 2), frame);
      });

      test('writes at most maxBands bands', () {
        final crowded = VideoEffectFrame(
          bands: List.filled(
            6,
            const VideoEffectBand(top: 0, bottom: 1, shift: 0.1),
          ),
        );
        expect(crowded.toList()[8], VideoEffectFrame.maxBands);
        expect(crowded.toList(), hasLength(VideoEffectFrame.stride));
      });
    });

    group('isIdentity', () {
      test('is true for none and for bands that move nothing', () {
        expect(VideoEffectFrame.none.isIdentity, isTrue);
        expect(
          const VideoEffectFrame(
            bands: [
              VideoEffectBand(top: 0.2, bottom: 0.4, shift: 0),
              VideoEffectBand(top: 0.5, bottom: 0.5, shift: 0.3),
            ],
          ).isIdentity,
          isTrue,
        );
      });

      test('is false once any operation is on', () {
        expect(const VideoEffectFrame(rgbShift: -0.01).isIdentity, isFalse);
        expect(const VideoEffectFrame(noise: 0.1).isIdentity, isFalse);
        expect(const VideoEffectFrame(brightness: -0.01).isIdentity, isFalse);
        expect(const VideoEffectFrame(vignette: 0.1).isIdentity, isFalse);
        expect(frame.isIdentity, isFalse);
      });
    });

    group('merge', () {
      test('returns the other frame when one side is identity', () {
        expect(VideoEffectFrame.none.merge(frame), frame);
        expect(frame.merge(VideoEffectFrame.none), frame);
      });

      test('keeps the larger block, adds shifts and keeps the stronger '
          'scanlines and noise with their sizes', () {
        const other = VideoEffectFrame(
          pixelSize: 0.05,
          rgbShift: 0.004,
          scanlines: 0.1,
          scanlinePeriod: 0.5,
          noise: 0.2,
          noiseCellSize: 0.01,
          noiseOffsetX: 3,
          noiseOffsetY: 4,
          bands: [VideoEffectBand(top: 0.8, bottom: 0.9, shift: 0.2)],
        );
        final merged = frame.merge(other);
        expect(merged.pixelSize, 0.05);
        expect(merged.rgbShift, closeTo(-0.006, 1e-12));
        expect(merged.scanlines, 0.25);
        expect(merged.scanlinePeriod, 1 / 270);
        expect(merged.noise, 0.2);
        expect(merged.noiseCellSize, 0.01);
        expect((merged.noiseOffsetX, merged.noiseOffsetY), (3, 4));
        expect(merged.bands, [...bands, ...other.bands]);
      });

      test('keeps the stronger tones, adds the brightness and keeps the '
          'stronger vignette with its radius', () {
        const other = VideoEffectFrame(
          sepia: 0.2,
          brightness: 0.03,
          invert: 1,
          flash: 0.1,
          vignette: 0.9,
          vignetteRadius: 0.5,
        );
        final merged = frame.merge(other);
        expect(merged.sepia, 0.5);
        expect(merged.brightness, closeTo(0.01, 1e-12));
        expect(merged.invert, 1);
        expect(merged.flash, 0.75);
        expect((merged.vignette, merged.vignetteRadius), (0.9, 0.5));
      });

      test('keeps the first maxBands bands', () {
        const four = VideoEffectFrame(
          bands: [
            VideoEffectBand(top: 0, bottom: 0.1, shift: 0.1),
            VideoEffectBand(top: 0.2, bottom: 0.3, shift: 0.1),
            VideoEffectBand(top: 0.4, bottom: 0.5, shift: 0.1),
            VideoEffectBand(top: 0.6, bottom: 0.7, shift: 0.1),
          ],
        );
        expect(four.merge(frame).bands, four.bands);
      });
    });
  });
}
