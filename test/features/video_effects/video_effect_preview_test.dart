import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group('VideoEffectPreview', () {
    late _Position position;

    setUp(() => position = _Position(Duration.zero));
    tearDown(() => position.dispose());

    Widget build(List<VideoEffect> effects) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: VideoEffectPreview(
          effects: effects,
          position: position,
          child: const _Player(),
        ),
      );
    }

    testWidgets('keeps the player mounted while effects come and go', (
      tester,
    ) async {
      _Player.mounts = 0;
      await tester.pumpWidget(build(const []));
      await tester.pumpWidget(build(const [VideoEffect.glitch()]));
      for (final ms in [40, 90, 500, 1200]) {
        position.value = Duration(milliseconds: ms);
        await tester.pump();
      }
      await tester.pumpWidget(build(const []));

      expect(find.byType(_Player), findsOneWidget);
      expect(_Player.mounts, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('follows a replaced position notifier', (tester) async {
      await tester.pumpWidget(build(const [VideoEffect.vhs()]));
      final replaced = _Position(const Duration(seconds: 3));
      addTearDown(replaced.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: VideoEffectPreview(
            effects: const [VideoEffect.vhs()],
            position: replaced,
            child: const _Player(),
          ),
        ),
      );
      replaced.value = const Duration(seconds: 4);
      await tester.pump();
      position.value = const Duration(seconds: 1);
      await tester.pump();

      expect(position.isListenedTo, isFalse);
      expect(replaced.isListenedTo, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}

class _Player extends StatefulWidget {
  const _Player();

  static int mounts = 0;

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  @override
  void initState() {
    super.initState();
    _Player.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 90, height: 160);
}

class _Position extends ValueNotifier<Duration> {
  _Position(super.value);

  bool get isListenedTo => hasListeners;
}
