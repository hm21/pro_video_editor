import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  final video = EditorVideo.asset('assets/test.mp4');

  group('SegmentTransform', () {
    const transform = SegmentTransform(
      offset: Offset(20, 40),
      size: Size(360, 640),
      fit: SegmentFit.contain,
    );

    test('toMap serializes all fields', () {
      final map = transform.toMap();

      expect(map['offset'], {'dx': 20.0, 'dy': 40.0});
      expect(map['size'], {'width': 360.0, 'height': 640.0});
      expect(map['fit'], 'contain');
    });

    test('defaults fit to cover', () {
      const minimal = SegmentTransform();
      expect(minimal.fit, SegmentFit.cover);
      expect(minimal.toMap()['offset'], isNull);
      expect(minimal.toMap()['size'], isNull);
    });

    test('toJson / fromJson roundtrip', () {
      final restored = SegmentTransform.fromJson(transform.toJson());
      expect(restored, transform);
    });

    test('copyWith updates fields', () {
      final copy = transform.copyWith(fit: SegmentFit.fill);
      expect(copy.fit, SegmentFit.fill);
      expect(copy.offset, transform.offset);
    });
  });

  group('VideoSegment composition fields', () {
    final segment = VideoSegment(
      video: video,
      timelineStart: const Duration(seconds: 5),
      transform: const SegmentTransform(
        offset: Offset(10, 10),
        size: Size(100, 100),
      ),
    );

    test('toMap includes timelineStart and transform', () {
      final map = segment.toMap();
      expect(map['timelineStart'], 5000000);
      expect(map['transform'], isA<Map<String, dynamic>>());
    });

    test('toJson / fromJson roundtrip', () {
      final restored = VideoSegment.fromJson(segment.toJson());
      expect(restored, segment);
      expect(restored.timelineStart, const Duration(seconds: 5));
      expect(restored.transform?.offset, const Offset(10, 10));
    });

    test('defaults to null when not provided', () {
      final minimal = VideoSegment(video: video);
      expect(minimal.timelineStart, isNull);
      expect(minimal.transform, isNull);
    });
  });

  group('VideoLayer', () {
    final layer = VideoLayer(
      clips: [VideoSegment(video: video)],
      opacity: 0.5,
      transform: const SegmentTransform(offset: Offset(0, 100)),
    );

    test('toMap serializes clips, opacity and transform', () {
      final map = layer.toMap();
      expect(map['clips'], isA<List<dynamic>>());
      expect((map['clips'] as List<dynamic>).length, 1);
      expect(map['opacity'], 0.5);
      expect(map['transform'], isA<Map<String, dynamic>>());
    });

    test('defaults opacity to 1.0', () {
      final l = VideoLayer(clips: [VideoSegment(video: video)]);
      expect(l.opacity, 1.0);
    });

    test('toJson / fromJson roundtrip', () {
      final restored = VideoLayer.fromJson(layer.toJson());
      expect(restored, layer);
    });

    test('asserts at least one clip', () {
      expect(() => VideoLayer(clips: const []), throwsAssertionError);
    });

    test('asserts opacity in range', () {
      expect(
        () => VideoLayer(clips: [VideoSegment(video: video)], opacity: 1.5),
        throwsAssertionError,
      );
    });

    group('chromaKey', () {
      const key = ChromaKey(similarity: 0.25);

      test('defaults to null so clips inherit the global key', () {
        expect(layer.chromaKey, isNull);
      });

      // toAsyncMap resolves each clip's source to a local path, so these use a
      // file video — an asset would need the platform channel.
      final local = VideoLayer(
        clips: [VideoSegment(video: EditorVideo.file('test.mp4'))],
      );

      test('toAsyncMap sends the key over the platform channel', () async {
        final map = await local.copyWith(chromaKey: key).toAsyncMap();

        expect(map['chromaKey'], isA<Map<String, dynamic>>());
        expect((map['chromaKey'] as Map)['similarity'], 0.25);
      });

      test('toAsyncMap omits the key when unset', () async {
        expect((await local.toAsyncMap())['chromaKey'], isNull);
      });

      test('toJson / fromJson roundtrip preserves the key', () {
        final withKey = layer.copyWith(chromaKey: key);

        expect(VideoLayer.fromJson(withKey.toJson()), withKey);
        expect(VideoLayer.fromJson(layer.toJson()).chromaKey, isNull);
      });

      test('a differing key breaks equality', () {
        expect(layer.copyWith(chromaKey: key), isNot(layer));
      });
    });
  });

  group('VideoComposition', () {
    final composition = VideoComposition(
      canvasSize: const Size(1080, 1920),
      backgroundColor: const Color(0xFF112233),
      layers: [
        VideoLayer(clips: [VideoSegment(video: video)]),
        VideoLayer(
          clips: [VideoSegment(video: video)],
          transform: const SegmentTransform(
            offset: Offset(20, 20),
            size: Size(360, 640),
          ),
        ),
      ],
    );

    test('toMap serializes canvas, background and layers', () {
      final map = composition.toMap();
      expect(map['canvasSize'], {'width': 1080.0, 'height': 1920.0});
      expect(map['backgroundColor'], 0xFF112233);
      expect((map['layers'] as List<dynamic>).length, 2);
    });

    test('defaults background to opaque black', () {
      final c = VideoComposition(
        layers: [
          VideoLayer(clips: [VideoSegment(video: video)]),
        ],
      );
      expect(c.backgroundColor, const Color(0xFF000000));
      expect(c.canvasSize, isNull);
    });

    test('toJson / fromJson roundtrip', () {
      final restored = VideoComposition.fromJson(composition.toJson());
      expect(restored, composition);
    });

    test('asserts at least one layer', () {
      expect(() => VideoComposition(layers: const []), throwsAssertionError);
    });
  });

  group('VideoRenderData composition source', () {
    final composition = VideoComposition(
      layers: [
        VideoLayer(clips: [VideoSegment(video: video)]),
      ],
    );

    test('accepts composition as the single source', () {
      final data = VideoRenderData(composition: composition);
      expect(data.composition, composition);
      expect(data.videoSegments, isNull);
    });

    test('throws when combined with videoSegments', () {
      expect(
        () => VideoRenderData(
          videoSegments: [VideoSegment(video: video)],
          composition: composition,
        ),
        throwsAssertionError,
      );
    });

    test('throws when no source is provided', () {
      expect(VideoRenderData.new, throwsAssertionError);
    });

    test('toMap / fromMap roundtrip preserves composition', () {
      final data = VideoRenderData(id: 'x', composition: composition);
      final restored = VideoRenderData.fromMap(data.toMap());
      expect(restored.composition, composition);
    });
  });
}
