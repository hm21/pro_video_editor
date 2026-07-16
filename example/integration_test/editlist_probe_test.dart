// Regression probe for edit-list-gated split outputs.
//
// A split without an explicit bitrate stream-copies both halves; the half
// starting mid-GOP keeps the samples from the preceding keyframe and gates
// playback start with an MP4 edit list (Darwin passthrough and Android
// edit-list trim both produce this shape). This test verifies the plugin's
// own pipelines consume such files correctly:
//  - getMetadata must report the trimmed duration (not the physical samples)
//  - getThumbnails at t≈0 of the end half must show the frame AT the split
//    position, not the preceding keyframe (up to one GOP earlier) that an
//    edit-list-ignoring reader would decode.
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;
  final skipPlatform = kIsWeb || isWindows || isLinux;

  /// Decodes a thumbnail into raw RGBA bytes.
  Future<Uint8List> rgba(Uint8List encoded) async {
    final codec = await ui.instantiateImageCodec(encoded);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    return data!.buffer.asUint8List();
  }

  /// Mean absolute channel difference between two same-sized RGBA images.
  double meanDiff(Uint8List a, Uint8List b) {
    var sum = 0;
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / len;
  }

  Future<Uint8List> thumbAt(EditorVideo video, Duration position) async {
    final thumbs = await pve.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.jpeg,
        timestamps: [position],
        outputSize: const ui.Size(160, 90),
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    return thumbs.single;
  }

  testWidgets(
    'edit-list end half: metadata duration + first visible frame',
    (tester) async {
      final source = EditorVideo.asset(kVideoEditorExampleH264Path);
      final meta = await pve.getMetadata(source);
      // demo.mp4 has a keyframe at 12.96s and the next at 16.08s: a cut at
      // 14.78s sits mid-GOP, 1.82s after the keyframe an edit-list-ignoring
      // reader would show instead.
      final splitPos = meta.duration ~/ 2;

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final startPath = '${dir.path}/elst_${stamp}_start.mp4';
      final endPath = '${dir.path}/elst_${stamp}_end.mp4';

      await pve.splitVideo(
        SplitVideoModel(
          video: source,
          splitPosition: splitPos,
          startOutputPath: startPath,
          endOutputPath: endPath,
        ),
      );

      final endHalf = EditorVideo.file(endPath);
      final endMeta = await pve.getMetadata(endHalf);
      final expected = meta.duration - splitPos;
      final durationDiff = (endMeta.duration - expected).abs();
      print(
        'PROBE duration: end half ${endMeta.duration.inMilliseconds}ms, '
        'expected ${expected.inMilliseconds}ms '
        '(diff ${durationDiff.inMilliseconds}ms)',
      );

      // Reference frames from the source: at the split, and at the preceding
      // keyframe region (what a non-elst-aware reader would show first).
      final atSplit = await rgba(await thumbAt(source, splitPos));
      final atPrevKeyframe = await rgba(
        await thumbAt(source, const Duration(milliseconds: 12980)),
      );
      final endFirst = await rgba(
        await thumbAt(endHalf, const Duration(milliseconds: 1)),
      );

      final diffSplit = meanDiff(endFirst, atSplit);
      final diffKeyframe = meanDiff(endFirst, atPrevKeyframe);
      final refDiff = meanDiff(atSplit, atPrevKeyframe);
      print(
        'PROBE frames: diff(end@0, source@split)=$diffSplit '
        'diff(end@0, source@prevKf)=$diffKeyframe '
        'diff(source@split, source@prevKf)=$refDiff',
      );

      // The two reference frames must be visually distinct for the probe to
      // be meaningful at all. A true match measures ~0.0 mean channel diff
      // (JPEG noise stays well below 1), so 3.0 is comfortably separating.
      expect(refDiff, greaterThan(3.0), reason: 'probe frames too similar');
      expect(
        durationDiff,
        lessThan(const Duration(milliseconds: 250)),
        reason: 'metadata must report the trimmed duration',
      );
      expect(
        diffSplit,
        lessThan(diffKeyframe),
        reason: 'end half must start at the split frame, '
            'not the preceding keyframe',
      );

      for (final path in [startPath, endPath]) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: skipPlatform,
  );
}
