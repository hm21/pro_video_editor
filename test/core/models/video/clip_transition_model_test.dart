import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('ClipTransition', () {
    const transition = ClipTransition(
      type: ClipTransitionType.dissolve,
      duration: Duration(milliseconds: 800),
      curve: AnimationCurve.easeInOut,
      direction: ClipTransitionDirection.right,
    );

    group('toMap', () {
      test('serializes all fields with enum names and microseconds', () {
        final map = transition.toMap();

        expect(map['type'], 'dissolve');
        expect(map['durationUs'], 800000);
        expect(map['curve'], 'easeInOut');
        expect(map['direction'], 'right');
      });
    });

    group('fromMap', () {
      test('deserializes all fields correctly', () {
        final restored = ClipTransition.fromMap(transition.toMap());
        expect(restored, transition);
      });

      test('defaults curve and direction when missing', () {
        final restored = ClipTransition.fromMap({
          'type': 'fadeToBlack',
          'durationUs': 500000,
        });

        expect(restored.type, ClipTransitionType.fadeToBlack);
        expect(restored.duration, const Duration(milliseconds: 500));
        expect(restored.curve, AnimationCurve.linear);
        expect(restored.direction, ClipTransitionDirection.left);
      });

      test('parses numeric strings safely', () {
        final restored = ClipTransition.fromMap({
          'type': 'wipe',
          'durationUs': '700000',
          'direction': 'up',
        });

        expect(restored.duration, const Duration(milliseconds: 700));
        expect(restored.direction, ClipTransitionDirection.up);
      });
    });

    test('copyWith creates copy with updated fields', () {
      final copy = transition.copyWith(type: ClipTransitionType.push);
      expect(copy.type, ClipTransitionType.push);
      expect(copy.duration, transition.duration);
      expect(copy.direction, transition.direction);
    });

    group('equality', () {
      test('equal instances are equal', () {
        expect(ClipTransition.fromMap(transition.toMap()), transition);
      });

      test('different instances are not equal', () {
        expect(transition.copyWith(duration: Duration.zero), isNot(transition));
      });
    });

    test('toString contains class name', () {
      expect(transition.toString(), contains('ClipTransition'));
    });

    group('VideoSegment integration', () {
      final video = EditorVideo.asset('assets/test.mp4');

      test('toMap includes the transition map', () {
        final segment = VideoSegment(video: video, transition: transition);
        final map = segment.toMap();

        expect(map['transition'], isA<Map<String, dynamic>>());
        expect((map['transition'] as Map)['type'], 'dissolve');
      });

      test('toMap/fromMap round-trips the transition', () {
        final segment = VideoSegment(video: video, transition: transition);
        final restored = VideoSegment.fromMap(segment.toMap());

        expect(restored.transition, transition);
        expect(restored, segment);
      });

      test('transition is null by default', () {
        final segment = VideoSegment(video: video);
        expect(segment.transition, isNull);
        expect(segment.toMap()['transition'], isNull);
      });
    });
  });

  group('ClipTransitionType', () {
    test('every type round-trips through its map by name', () {
      for (final type in ClipTransitionType.values) {
        final restored = ClipTransition.fromMap(
          ClipTransition(type: type).toMap(),
        );
        expect(restored.type, type);
      }
    });

    test('only the fades to a color are dips', () {
      expect(ClipTransitionType.values.where((type) => type.isDip), [
        ClipTransitionType.fadeToBlack,
        ClipTransitionType.fadeToWhite,
      ]);
      for (final type in ClipTransitionType.values) {
        expect(type.isOverlap, !type.isDip, reason: type.name);
      }
    });

    test('the moving transitions use the direction', () {
      expect(ClipTransitionType.values.where((type) => type.usesDirection), [
        ClipTransitionType.slide,
        ClipTransitionType.push,
        ClipTransitionType.wipe,
        ClipTransitionType.whipPan,
        ClipTransitionType.stretch,
      ]);
    });

    test('only the flash flashes', () {
      expect(ClipTransitionType.values.where((type) => type.flashes), [
        ClipTransitionType.flash,
      ]);
    });
  });
}
