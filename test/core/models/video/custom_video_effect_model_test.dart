import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group(CustomVideoEffect, () {
    const effect = CustomVideoEffect(
      id: 'divine.echo',
      params: {'intensity': 0.7, 'copies': 5},
      startTime: Duration(seconds: 1),
      endTime: Duration(seconds: 3),
    );

    group('toChannelMap', () {
      test('sends the id, the params and the range in microseconds', () {
        expect(effect.toChannelMap(), {
          'id': 'divine.echo',
          'params': {'intensity': 0.7, 'copies': 5},
          'startUs': 1000000,
          'endUs': 3000000,
        });
      });

      test('leaves an open range null', () {
        final map = const CustomVideoEffect(id: 'a').toChannelMap();
        expect(map['startUs'], isNull);
        expect(map['endUs'], isNull);
        expect(map['params'], isEmpty);
      });
    });

    group('fromMap', () {
      test('reads back what toMap writes', () {
        expect(CustomVideoEffect.fromMap(effect.toMap()), effect);
      });

      test('defaults to no params', () {
        expect(
          CustomVideoEffect.fromMap(const {'id': 'a'}),
          const CustomVideoEffect(id: 'a'),
        );
      });
    });

    group('equality', () {
      test('compares params by value', () {
        expect(
          const CustomVideoEffect(id: 'a', params: {'x': 1}),
          CustomVideoEffect(id: 'a', params: Map.of({'x': 1})),
        );
        expect(
          const CustomVideoEffect(id: 'a', params: {'x': 1}).hashCode,
          CustomVideoEffect(id: 'a', params: Map.of({'x': 1})).hashCode,
        );
        expect(
          const CustomVideoEffect(id: 'a', params: {'x': 1}),
          isNot(const CustomVideoEffect(id: 'a', params: {'x': 2})),
        );
      });
    });
  });
}
