import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_animation_model.dart';

void main() {
  group('LayerAnimation', () {
    group('constructor', () {
      test('creates fade animation with defaults', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );

        expect(anim.type, LayerAnimationType.fade);
        expect(anim.phase, AnimationPhase.animateIn);
        expect(anim.duration, const Duration(milliseconds: 500));
        expect(anim.curve, AnimationCurve.linear);
        expect(anim.slideDirection, isNull);
        expect(anim.scaleFrom, isNull);
      });

      test('creates slide animation with direction', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateOut,
          duration: Duration(milliseconds: 300),
          slideDirection: SlideDirection.left,
          curve: AnimationCurve.easeOut,
        );

        expect(anim.type, LayerAnimationType.slide);
        expect(anim.slideDirection, SlideDirection.left);
        expect(anim.curve, AnimationCurve.easeOut);
      });

      test('creates slide animation with a custom start point', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 300),
          slideFrom: Offset(-120, 340),
        );

        expect(anim.slideFrom, const Offset(-120, 340));
        expect(anim.slideDirection, isNull);
      });

      test('creates scale animation with scaleFrom', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateInOut,
          duration: Duration(milliseconds: 400),
          scaleFrom: 0.5,
        );

        expect(anim.type, LayerAnimationType.scale);
        expect(anim.phase, AnimationPhase.animateInOut);
        expect(anim.scaleFrom, 0.5);
      });
    });

    group('toMap', () {
      test('serializes fade animation', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        final map = anim.toMap();

        expect(map['type'], 'fade');
        expect(map['phase'], 'animateIn');
        expect(map['durationUs'], 500000);
        expect(map['curve'], 'linear');
        expect(map['slideDirection'], isNull);
        expect(map['scaleFrom'], isNull);
      });

      test('serializes slide animation with all fields', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateOut,
          duration: Duration(seconds: 1),
          curve: AnimationCurve.easeInOut,
          slideDirection: SlideDirection.bottom,
        );
        final map = anim.toMap();

        expect(map['type'], 'slide');
        expect(map['phase'], 'animateOut');
        expect(map['durationUs'], 1000000);
        expect(map['curve'], 'easeInOut');
        expect(map['slideDirection'], 'bottom');
      });

      test('serializes scale animation with scaleFrom', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateInOut,
          duration: Duration(milliseconds: 250),
          scaleFrom: 0.3,
        );
        final map = anim.toMap();

        expect(map['scaleFrom'], 0.3);
      });
    });

    group('slideFrom serialization', () {
      test('toMap writes the point as dx/dy', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 300),
          slideFrom: Offset(-120.5, 340),
        );

        expect(anim.toMap()['slideFrom'], {'dx': -120.5, 'dy': 340.0});
      });

      test('toMap writes null when no point is set', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 300),
          slideDirection: SlideDirection.left,
        );

        expect(anim.toMap()['slideFrom'], isNull);
      });

      test('fromMap reads the point back', () {
        final anim = LayerAnimation.fromMap(<String, dynamic>{
          'type': 'slide',
          'phase': 'animateIn',
          'durationUs': 300000,
          'slideFrom': {'dx': -120.5, 'dy': 340},
        });

        expect(anim.slideFrom, const Offset(-120.5, 340));
      });

      test('survives a round trip alongside a direction', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateInOut,
          duration: Duration(milliseconds: 300),
          curve: AnimationCurve.easeOutCubic,
          slideDirection: SlideDirection.top,
          slideFrom: Offset(40, -60),
        );

        expect(LayerAnimation.fromMap(anim.toMap()), anim);
      });
    });

    group('loop window', () {
      test('survives a round trip', () {
        const loop = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          loopStart: Duration(seconds: 1),
          loopEnd: Duration(seconds: 3),
        );

        final map = loop.toMap();

        expect(map['loopStartUs'], 1000000);
        expect(map['loopEndUs'], 3000000);
        expect(LayerAnimation.fromMap(map), loop);
      });

      test('writes null without a window', () {
        const loop = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
        );

        final map = loop.toMap();

        expect(map['loopStartUs'], isNull);
        expect(map['loopEndUs'], isNull);
        expect(LayerAnimation.fromMap(map).loopStart, isNull);
      });

      test('is a loop setting only', () {
        expect(
          () => LayerAnimation(
            type: LayerAnimationType.fade,
            phase: AnimationPhase.animateIn,
            duration: const Duration(milliseconds: 500),
            loopStart: Duration.zero,
          ),
          throwsAssertionError,
        );
      });
    });

    group('fromMap', () {
      test('deserializes fade animation', () {
        final map = <String, dynamic>{
          'type': 'fade',
          'phase': 'animateIn',
          'durationUs': 500000,
          'curve': 'linear',
          'slideDirection': null,
          'scaleFrom': null,
        };
        final anim = LayerAnimation.fromMap(map);

        expect(anim.type, LayerAnimationType.fade);
        expect(anim.phase, AnimationPhase.animateIn);
        expect(anim.duration, const Duration(milliseconds: 500));
        expect(anim.curve, AnimationCurve.linear);
        expect(anim.slideDirection, isNull);
        expect(anim.scaleFrom, isNull);
      });

      test('deserializes slide animation', () {
        final map = <String, dynamic>{
          'type': 'slide',
          'phase': 'animateOut',
          'durationUs': 300000,
          'curve': 'easeOut',
          'slideDirection': 'right',
          'scaleFrom': null,
        };
        final anim = LayerAnimation.fromMap(map);

        expect(anim.type, LayerAnimationType.slide);
        expect(anim.slideDirection, SlideDirection.right);
        expect(anim.curve, AnimationCurve.easeOut);
      });

      test('defaults curve to linear when missing', () {
        final map = <String, dynamic>{
          'type': 'fade',
          'phase': 'animateIn',
          'durationUs': 100000,
        };
        final anim = LayerAnimation.fromMap(map);

        expect(anim.curve, AnimationCurve.linear);
      });

      test('deserializes animateInOut phase', () {
        final map = <String, dynamic>{
          'type': 'scale',
          'phase': 'animateInOut',
          'durationUs': 400000,
          'scaleFrom': 0.5,
        };
        final anim = LayerAnimation.fromMap(map);

        expect(anim.phase, AnimationPhase.animateInOut);
        expect(anim.scaleFrom, 0.5);
      });
    });

    group('roundtrip toMap/fromMap', () {
      test('fade roundtrip preserves data', () {
        const original = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          curve: AnimationCurve.easeIn,
        );
        final restored = LayerAnimation.fromMap(original.toMap());
        expect(restored, original);
      });

      test('slide roundtrip preserves data', () {
        const original = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateOut,
          duration: Duration(milliseconds: 300),
          curve: AnimationCurve.easeOut,
          slideDirection: SlideDirection.top,
        );
        final restored = LayerAnimation.fromMap(original.toMap());
        expect(restored, original);
      });

      test('scale roundtrip preserves data', () {
        const original = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateInOut,
          duration: Duration(milliseconds: 250),
          scaleFrom: 0.2,
        );
        final restored = LayerAnimation.fromMap(original.toMap());
        expect(restored, original);
      });

      test('wiggle loop roundtrip preserves its angle', () {
        const original = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 600),
          curve: AnimationCurve.easeIn,
          wiggleAngle: 0.3,
        );
        final restored = LayerAnimation.fromMap(original.toMap());
        expect(restored, original);
        expect(restored.wiggleAngle, 0.3);
      });

      test('bounce roundtrip preserves its height', () {
        const original = LayerAnimation(
          type: LayerAnimationType.bounce,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 800),
          curve: AnimationCurve.bounceOut,
          bounceHeight: 1.25,
        );
        final restored = LayerAnimation.fromMap(original.toMap());
        expect(restored, original);
        expect(restored.bounceHeight, 1.25);
      });

      test('text reveals round-trip', () {
        for (final type in [
          LayerAnimationType.typewriter,
          LayerAnimationType.wordByWord,
        ]) {
          final original = LayerAnimation(
            type: type,
            phase: AnimationPhase.animateOut,
            duration: const Duration(seconds: 1),
          );
          expect(LayerAnimation.fromMap(original.toMap()), original);
        }
      });

      test('reads a whole-number angle and height sent as an int', () {
        final restored = LayerAnimation.fromMap({
          'type': 'wiggle',
          'phase': 'loop',
          'durationUs': 500000,
          'wiggleAngle': 1,
          'bounceHeight': 2,
        });
        expect(restored.wiggleAngle, 1.0);
        expect(restored.bounceHeight, 2.0);
      });

      test('reads a whole-number scale and a duration sent as numbers', () {
        final restored = LayerAnimation.fromMap({
          'type': 'scale',
          'phase': 'animateIn',
          'durationUs': 500000.0,
          'scaleFrom': 1,
        });
        expect(restored.scaleFrom, 1.0);
        expect(restored.duration, const Duration(milliseconds: 500));
      });
    });

    group('wiggle and bounce', () {
      test('leave angle and height unset by default', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
        );
        expect(anim.wiggleAngle, isNull);
        expect(anim.bounceHeight, isNull);
        expect(anim.toMap()['wiggleAngle'], isNull);
        expect(anim.toMap()['bounceHeight'], isNull);
      });

      test('defaults to a 10 degree tilt and half the layer height', () {
        expect(
          LayerAnimation.defaultWiggleAngle,
          closeTo(10 * 3.14159265 / 180, 1e-6),
        );
        expect(LayerAnimation.defaultBounceHeight, 0.5);
      });

      test('differ by angle and height', () {
        const a = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          wiggleAngle: 0.1,
        );
        const b = LayerAnimation(
          type: LayerAnimationType.wiggle,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          wiggleAngle: 0.2,
        );
        const c = LayerAnimation(
          type: LayerAnimationType.bounce,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          bounceHeight: 0.5,
        );
        const d = LayerAnimation(
          type: LayerAnimationType.bounce,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          bounceHeight: 1,
        );
        expect(a, isNot(b));
        expect(c, isNot(d));
      });

      test('name angle and height in toString', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.bounce,
          phase: AnimationPhase.loop,
          duration: Duration(milliseconds: 500),
          wiggleAngle: 0.1,
          bounceHeight: 0.75,
        );
        expect(anim.toString(), contains('wiggleAngle: 0.1'));
        expect(anim.toString(), contains('bounceHeight: 0.75'));
      });
    });

    group('equality', () {
      test('identical animations are equal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        const b = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('different type makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        const b = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        expect(a, isNot(b));
      });

      test('different phase makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        const b = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateOut,
          duration: Duration(milliseconds: 500),
        );
        expect(a, isNot(b));
      });

      test('different duration makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        const b = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 300),
        );
        expect(a, isNot(b));
      });

      test('different curve makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          curve: AnimationCurve.linear,
        );
        const b = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          curve: AnimationCurve.easeIn,
        );
        expect(a, isNot(b));
      });

      test('different slideDirection makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideDirection: SlideDirection.left,
        );
        const b = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideDirection: SlideDirection.right,
        );
        expect(a, isNot(b));
      });

      test('different slideFrom makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideFrom: Offset(0, 0),
        );
        const b = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideFrom: Offset(0, 100),
        );
        expect(a, isNot(b));
      });

      test('different scaleFrom makes unequal', () {
        const a = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          scaleFrom: 0.0,
        );
        const b = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          scaleFrom: 0.5,
        );
        expect(a, isNot(b));
      });
    });

    group('toString', () {
      test('contains class name and fields', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        final str = anim.toString();

        expect(str, contains('LayerAnimation'));
        expect(str, contains('fade'));
        expect(str, contains('animateIn'));
      });

      test('includes slideDirection when present', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideDirection: SlideDirection.left,
        );
        expect(anim.toString(), contains('slideDirection'));
      });

      test('includes slideFrom when present', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.slide,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          slideFrom: Offset(-120, 340),
        );
        expect(anim.toString(), contains('slideFrom'));
      });

      test('includes scaleFrom when present', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.scale,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
          scaleFrom: 0.5,
        );
        expect(anim.toString(), contains('scaleFrom'));
      });

      test('excludes slideDirection when null', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        expect(anim.toString(), isNot(contains('slideDirection')));
      });

      test('excludes scaleFrom when null', () {
        const anim = LayerAnimation(
          type: LayerAnimationType.fade,
          phase: AnimationPhase.animateIn,
          duration: Duration(milliseconds: 500),
        );
        expect(anim.toString(), isNot(contains('scaleFrom')));
      });
    });
  });

  group('Enum values', () {
    test('LayerAnimationType has expected values', () {
      expect(LayerAnimationType.values, [
        LayerAnimationType.fade,
        LayerAnimationType.slide,
        LayerAnimationType.scale,
        LayerAnimationType.wiggle,
        LayerAnimationType.bounce,
        LayerAnimationType.typewriter,
        LayerAnimationType.wordByWord,
      ]);
    });

    test('SlideDirection has expected values', () {
      expect(SlideDirection.values, [
        SlideDirection.left,
        SlideDirection.right,
        SlideDirection.top,
        SlideDirection.bottom,
      ]);
    });

    test('AnimationCurve has expected values', () {
      expect(AnimationCurve.values, [
        AnimationCurve.linear,
        AnimationCurve.easeIn,
        AnimationCurve.easeOut,
        AnimationCurve.easeInOut,
        AnimationCurve.easeInCubic,
        AnimationCurve.easeOutCubic,
        AnimationCurve.easeInOutCubic,
        AnimationCurve.bounceIn,
        AnimationCurve.bounceOut,
        AnimationCurve.bounceInOut,
        AnimationCurve.elasticIn,
        AnimationCurve.elasticOut,
        AnimationCurve.elasticInOut,
      ]);
    });

    test('AnimationPhase has expected values', () {
      expect(AnimationPhase.values, [
        AnimationPhase.animateIn,
        AnimationPhase.animateOut,
        AnimationPhase.animateInOut,
        AnimationPhase.loop,
      ]);
    });
  });
}
