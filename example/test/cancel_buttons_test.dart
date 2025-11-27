import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/features/editor/widgets/video_progress_alert.dart';
import 'package:pro_video_editor_example/features/render/video_renderer_page.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProVideoEditor originalEditor;
  late _FakeCancelableEditor fakeEditor;

  setUp(() {
    originalEditor = ProVideoEditor.instance;
    fakeEditor = _FakeCancelableEditor();
    ProVideoEditor.instance = fakeEditor;
    overrideRenderCancelCapability(() => true);
  });

  tearDown(() {
    resetRenderCancelCapability();
    ProVideoEditor.instance = originalEditor;
  });

  testWidgets('Video editor progress alert forwards cancel to plugin',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoProgressAlert(taskId: 'task-editor'),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Cancel render'), findsOneWidget);

    await tester.tap(find.text('Cancel render'));
    await tester.pump();

    expect(fakeEditor.lastCancelledTaskId, 'task-editor');
    expect(fakeEditor.cancelCalls, 1);
  });

  testWidgets('Video renderer progress panel triggers cancel callback',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoRendererProgressPanel(
            progressStream: const Stream<ProgressModel>.empty(),
            supportsCancel: true,
            onCancel: () {
              ProVideoEditor.instance.cancel('task-renderer');
            },
          ),
        ),
      ),
    );

    await tester.pump();

    await tester.tap(find.text('Cancel render'));
    await tester.pump();

    expect(fakeEditor.lastCancelledTaskId, 'task-renderer');
    expect(fakeEditor.cancelCalls, 1);
  });
}

class _FakeCancelableEditor extends ProVideoEditor {
  _FakeCancelableEditor();

  String? lastCancelledTaskId;
  int cancelCalls = 0;

  @override
  void initializeStream() {}

  @override
  Future<void> cancel(String taskId) async {
    cancelCalls += 1;
    lastCancelledTaskId = taskId;
  }

  @override
  Future<String?> getPlatformVersion() async => 'test';

  @override
  Future<VideoMetadata> getMetadata(EditorVideo value) {
    throw UnimplementedError();
  }

  @override
  Future<List<Uint8List>> getThumbnails(ThumbnailConfigs value) {
    throw UnimplementedError();
  }

  @override
  Future<List<Uint8List>> getKeyFrames(KeyFramesConfigs value) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> renderVideo(RenderVideoModel value) {
    throw UnimplementedError();
  }

  @override
  Future<String> renderVideoToFile(
    String filePath,
    RenderVideoModel value,
  ) {
    throw UnimplementedError();
  }
}
