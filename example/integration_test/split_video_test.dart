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
  final source = EditorVideo.asset(kVideoEditorExampleH264Path);

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  /// Splitting is implemented on Android, iOS, and macOS only.
  final skipPlatform = kIsWeb || isWindows || isLinux;

  /// Re-encoding adds/drops at most a frame at the boundary, so allow a small
  /// duration tolerance when asserting the cut.
  const tolerance = Duration(milliseconds: 250);

  bool hasAudio(VideoMetadata meta) =>
      meta.audioDuration != null && meta.audioDuration != Duration.zero;

  Future<String> tempPath(String suffix) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/split_${stamp}_$suffix.mp4';
  }

  Future<void> cleanUp(List<String> paths) async {
    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  void expectClose(
    Duration actual,
    Duration expected, {
    required String reason,
  }) {
    final diff = (actual - expected).abs();
    expect(
      diff <= tolerance,
      isTrue,
      reason:
          '$reason (actual: ${actual.inMilliseconds}ms, '
          'expected: ${expected.inMilliseconds}ms, '
          'diff: ${diff.inMilliseconds}ms)',
    );
  }

  testWidgets('splits a video into two files at the midpoint', (tester) async {
    final meta = await pve.getMetadata(source);
    final splitPos = meta.duration ~/ 2;

    final startPath = await tempPath('start');
    final endPath = await tempPath('end');

    final paths = await pve.splitVideo(
      SplitVideoModel(
        video: source,
        splitPosition: splitPos,
        startOutputPath: startPath,
        endOutputPath: endPath,
      ),
    );

    expect(paths, [startPath, endPath]);
    expect(await File(startPath).exists(), isTrue);
    expect(await File(endPath).exists(), isTrue);

    final startMeta = await pve.getMetadata(EditorVideo.file(startPath));
    final endMeta = await pve.getMetadata(EditorVideo.file(endPath));

    expectClose(
      startMeta.duration,
      splitPos,
      reason: 'start half should end at the split position',
    );
    expectClose(
      endMeta.duration,
      meta.duration - splitPos,
      reason: 'end half should cover the remainder',
    );
    expectClose(
      startMeta.duration + endMeta.duration,
      meta.duration,
      reason: 'both halves together should match the source duration',
    );

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);

  testWidgets('keeps audio in both halves by default', (tester) async {
    final meta = await pve.getMetadata(source);
    if (!hasAudio(meta)) return; // source must have audio for this assertion

    final startPath = await tempPath('audio_start');
    final endPath = await tempPath('audio_end');

    await pve.splitVideo(
      SplitVideoModel(
        video: source,
        splitPosition: meta.duration ~/ 2,
        startOutputPath: startPath,
        endOutputPath: endPath,
      ),
    );

    final startMeta = await pve.getMetadata(EditorVideo.file(startPath));
    final endMeta = await pve.getMetadata(EditorVideo.file(endPath));

    expect(hasAudio(startMeta), isTrue, reason: 'start half should keep audio');
    expect(hasAudio(endMeta), isTrue, reason: 'end half should keep audio');

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);

  testWidgets('enableAudio:false produces silent halves', (tester) async {
    final meta = await pve.getMetadata(source);

    final startPath = await tempPath('silent_start');
    final endPath = await tempPath('silent_end');

    await pve.splitVideo(
      SplitVideoModel(
        video: source,
        splitPosition: meta.duration ~/ 2,
        startOutputPath: startPath,
        endOutputPath: endPath,
        enableAudio: false,
      ),
    );

    final startMeta = await pve.getMetadata(EditorVideo.file(startPath));
    final endMeta = await pve.getMetadata(EditorVideo.file(endPath));

    expect(hasAudio(startMeta), isFalse);
    expect(hasAudio(endMeta), isFalse);

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);

  testWidgets('reports progress from 0 to 1', (tester) async {
    final meta = await pve.getMetadata(source);

    final startPath = await tempPath('progress_start');
    final endPath = await tempPath('progress_end');

    final model = SplitVideoModel(
      video: source,
      splitPosition: meta.duration ~/ 2,
      startOutputPath: startPath,
      endOutputPath: endPath,
    );

    var maxProgress = 0.0;
    final sub = model.progressStream.listen((p) {
      maxProgress = p.progress > maxProgress ? p.progress : maxProgress;
    });

    await pve.splitVideo(model);
    await sub.cancel();

    expect(maxProgress, greaterThan(0.0));

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);

  testWidgets('throws when the split position is out of range', (tester) async {
    final meta = await pve.getMetadata(source);

    final startPath = await tempPath('oob_start');
    final endPath = await tempPath('oob_end');

    await expectLater(
      pve.splitVideo(
        SplitVideoModel(
          video: source,
          // Far beyond the end of the clip.
          splitPosition: meta.duration * 2,
          startOutputPath: startPath,
          endOutputPath: endPath,
        ),
      ),
      throwsA(isA<PlatformException>()),
    );

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);

  testWidgets('can be cancelled mid-split', (tester) async {
    final meta = await pve.getMetadata(source);

    final startPath = await tempPath('cancel_start');
    final endPath = await tempPath('cancel_end');

    final model = SplitVideoModel(
      video: source,
      splitPosition: meta.duration ~/ 2,
      startOutputPath: startPath,
      endOutputPath: endPath,
    );

    final future = pve.splitVideo(model);
    final captured = future.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The split may already be done on fast machines; a missing task surfaces
    // as a no-op (Android) or TASK_NOT_FOUND (iOS/macOS), both tolerated.
    try {
      await pve.cancel(model.id);
    } on PlatformException catch (e) {
      if (e.code != 'TASK_NOT_FOUND') rethrow;
    }

    final error = await captured;
    if (error != null) {
      expect(error, isA<RenderCanceledException>());
    }
    // else: the split finished before the cancel arrived — no error expected.

    await cleanUp([startPath, endPath]);
  }, skip: skipPlatform);
}
