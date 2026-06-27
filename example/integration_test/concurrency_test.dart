import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final testVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  final isAndroid = !kIsWeb && Platform.isAndroid;
  final isIOS = !kIsWeb && Platform.isIOS;
  final isMacOS = !kIsWeb && Platform.isMacOS;
  final supportsCancel = !kIsWeb && (isAndroid || isIOS || isMacOS);

  ThumbnailConfigs thumbTask(String id) => ThumbnailConfigs(
    id: id,
    video: testVideo,
    outputFormat: ThumbnailFormat.jpeg,
    timestamps: List.generate(6, (i) => Duration(seconds: i * 2)),
    outputSize: const Size(64, 64),
    boxFit: ThumbnailBoxFit.cover,
  );

  VideoRenderData renderTask(String id, Duration start, Duration end) =>
      VideoRenderData(
        id: id,
        videoSegments: [
          VideoSegment(video: testVideo, startTime: start, endTime: end),
        ],
        outputFormat: VideoOutputFormat.mp4,
      );

  testWidgets('concurrent tasks keep progress streams isolated', (
    tester,
  ) async {
    final taskA = thumbTask('concurrent-a');
    final taskB = thumbTask('concurrent-b');

    final aEvents = <ProgressModel>[];
    final bEvents = <ProgressModel>[];
    final seenIds = <String>{};

    final subA = taskA.progressStream.listen(aEvents.add);
    final subB = taskB.progressStream.listen(bEvents.add);
    final subAll = pve.progressStream.listen((e) => seenIds.add(e.id));

    await Future.wait([pve.getThumbnails(taskA), pve.getThumbnails(taskB)]);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await subA.cancel();
    await subB.cancel();
    await subAll.cancel();

    expect(aEvents, isNotEmpty, reason: 'task A produced no progress');
    expect(bEvents, isNotEmpty, reason: 'task B produced no progress');
    expect(
      aEvents.every((e) => e.id == taskA.id),
      isTrue,
      reason: 'task A stream leaked events from another task',
    );
    expect(
      bEvents.every((e) => e.id == taskB.id),
      isTrue,
      reason: 'task B stream leaked events from another task',
    );
    expect(seenIds, containsAll(<String>{taskA.id, taskB.id}));
  }, skip: kIsWeb);

  testWidgets('two concurrent in-memory renders both succeed', (tester) async {
    // Both renders start in the same instant; the native temp output filename
    // must be unique per task so they don't collide.
    final results = await Future.wait([
      pve.renderVideo(
        renderTask('render-a', Duration.zero, const Duration(seconds: 2)),
      ),
      pve.renderVideo(
        renderTask(
          'render-b',
          const Duration(seconds: 2),
          const Duration(seconds: 4),
        ),
      ),
    ]);

    for (final bytes in results) {
      expect(bytes.lengthInBytes, greaterThan(10000));
    }
  }, skip: kIsWeb);

  testWidgets('cancelling one render leaves the other running', (tester) async {
    final modelA = renderTask(
      'cancel-a',
      Duration.zero,
      const Duration(seconds: 8),
    );
    final modelB = renderTask(
      'cancel-b',
      Duration.zero,
      const Duration(seconds: 2),
    );

    final futureA = pve.renderVideo(modelA);
    final errorA = futureA.then<Object?>((_) => null, onError: (Object e) => e);
    final futureB = pve.renderVideo(modelB);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    try {
      await pve.cancel(modelA.id);
    } on PlatformException catch (e) {
      if (e.code != 'TASK_NOT_FOUND') rethrow;
    }

    /// Task B must finish untouched by task A's cancellation.
    final bytesB = await futureB;
    expect(bytesB.lengthInBytes, greaterThan(10000));

    /// Task A was either cancelled (RenderCanceledException) or had already
    /// finished before the cancel landed on a fast machine.
    final error = await errorA;
    if (error != null) {
      expect(error, isA<RenderCanceledException>());
    }
  }, skip: !supportsCancel);
}
