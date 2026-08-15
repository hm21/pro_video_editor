import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
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

  /// Awaits [future], returning the error it failed with or null on success,
  /// and asserts that a failure is a cancellation rather than a crash-adjacent
  /// platform error.
  Future<void> expectCancelledOrDone(
    Future<Object?> future,
    String what,
  ) async {
    final error = await future.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    if (error != null) {
      expect(
        error,
        isA<RenderCanceledException>(),
        reason: '$what must fail as a cancellation, not as $error',
      );
    }
  }

  /// Cancel timings swept across the native setup phase — session created,
  /// export not started yet. That window is milliseconds wide and its position
  /// depends on the machine, so a single delay would only sometimes land in it.
  const cancelDelays = <int>[0, 10, 25, 50, 90, 150, 240, 400];

  /// The same sweep for the split, compressed. Both halves are stream-copied
  /// (no bitrate, so `AVAssetExportPresetPassthrough`) and finish in
  /// milliseconds, so the delays above would land after the whole job is
  /// already done and cancel nothing at all. These stay inside the setup window
  /// of the first half and of the second one that follows it.
  const splitCancelDelays = <int>[0, 1, 2, 4, 8, 15, 30, 60];

  /// The window between "export session created" and "export started" used to
  /// be lethal: a cancel landing in it force-cancelled a session that had never
  /// run, and the export started anyway a moment later. `export(to:as:)`
  /// assigns `outputURL` before it starts, which AVFoundation answers on an
  /// already-cancelled session with an Objective-C exception — uncatchable from
  /// Swift, so the whole app went down with it (issue #189).
  ///
  /// The failure mode is therefore not an assertion but a dead app: without the
  /// fix this test loses the device connection partway through the sweep.
  testWidgets(
    'a render cancelled during export setup never kills the app',
    (tester) async {
      for (final ms in cancelDelays) {
        final model = renderTask(
          'cancel-window-$ms',
          Duration.zero,
          const Duration(seconds: 3),
        );

        final future = pve.renderVideo(model);
        await Future<void>.delayed(Duration(milliseconds: ms));
        try {
          await pve.cancel(model.id);
        } on PlatformException catch (e) {
          if (e.code != 'TASK_NOT_FOUND') rethrow;
        }

        await expectCancelledOrDone(future, 'a render cancelled after ${ms}ms');
      }

      /// Still alive and still working — a native crash anywhere in the sweep
      /// above would have taken the test host with it long before this line.
      final bytes = await pve.renderVideo(
        renderTask(
          'cancel-window-survivor',
          Duration.zero,
          const Duration(seconds: 2),
        ),
      );
      expect(bytes.lengthInBytes, greaterThan(10000));
    },
    skip: !supportsCancel,
  );

  /// The same window on the split pipeline, which additionally runs two export
  /// sessions through a single job handle — the second half is created while
  /// the job may already be cancelled.
  testWidgets(
    'a split cancelled during export setup never kills the app',
    (tester) async {
      final directory = await getTemporaryDirectory();
      final outputs = <String>[];

      /// Registered before the sweep runs: a failed expectation inside it is
      /// exactly what a regression looks like, and would otherwise leak every
      /// half written up to that point.
      addTearDown(() async {
        for (final path in outputs) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      });

      for (final ms in splitCancelDelays) {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final startPath = '${directory.path}/cancel_${stamp}_start.mp4';
        final endPath = '${directory.path}/cancel_${stamp}_end.mp4';
        outputs.addAll([startPath, endPath]);

        final model = SplitVideoModel(
          id: 'split-cancel-window-$ms',
          video: testVideo,
          splitPosition: const Duration(seconds: 4),
          startOutputPath: startPath,
          endOutputPath: endPath,
        );

        final future = pve.splitVideo(model);
        await Future<void>.delayed(Duration(milliseconds: ms));
        try {
          await pve.cancel(model.id);
        } on PlatformException catch (e) {
          if (e.code != 'TASK_NOT_FOUND') rethrow;
        }

        await expectCancelledOrDone(future, 'a split cancelled after ${ms}ms');
      }
    },
    skip: !supportsCancel,
  );
}
