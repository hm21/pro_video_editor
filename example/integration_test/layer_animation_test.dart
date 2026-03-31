import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Creates a simple semi-transparent PNG overlay image for testing.
Future<Uint8List> createTestOverlayImage({
  int width = 200,
  int height = 100,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  final paint = ui.Paint()
    ..color = const ui.Color.fromARGB(128, 255, 0, 0)
    ..style = ui.PaintingStyle.fill;

  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    paint,
  );

  final borderPaint = ui.Paint()
    ..color = const ui.Color.fromARGB(255, 255, 255, 255)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 4;

  canvas.drawRect(ui.Rect.fromLTWH(2, 2, width - 4, height - 4), borderPaint);

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

  return byteData!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final inputVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  Future<VideoMetadata> testRender({
    required String description,
    required VideoRenderData renderModel,
  }) async {
    final result = await ProVideoEditor.instance.renderVideo(renderModel);
    expect(result, isNotNull, reason: '$description failed — result is null');
    expect(
      result.lengthInBytes,
      greaterThan(100000),
      reason: '$description failed — video is too small',
    );

    final meta = await ProVideoEditor.instance.getMetadata(
      EditorVideo.memory(result),
    );
    expect(
      meta.extension,
      equals(renderModel.outputFormat.name),
      reason: '$description — wrong format',
    );

    return meta;
  }

  // ───────────────────────────────────────────────────────────
  // Layer Animations
  // ───────────────────────────────────────────────────────────
  group('Layer animations', () {
    late EditorLayerImage overlayImage;

    setUp(() async {
      final bytes = await createTestOverlayImage(width: 200, height: 100);
      overlayImage = EditorLayerImage.memory(bytes);
    });

    // ── All animation types × all phases ──────────────────────
    for (final type in LayerAnimationType.values) {
      for (final phase in AnimationPhase.values) {
        testWidgets('${type.name} / ${phase.name}', (_) async {
          await testRender(
            description: '${type.name} ${phase.name}',
            renderModel: VideoRenderData(
              videoSegments: [VideoSegment(video: inputVideo)],
              outputFormat: VideoOutputFormat.mp4,
              imageLayers: [
                ImageLayer(
                  image: overlayImage,
                  offset: const Offset(100, 100),
                  startTime: const Duration(seconds: 1),
                  endTime: const Duration(seconds: 5),
                  animations: [
                    LayerAnimation(
                      type: type,
                      phase: phase,
                      duration: const Duration(milliseconds: 500),
                      slideDirection: type == LayerAnimationType.slide
                          ? SlideDirection.left
                          : null,
                      scaleFrom: type == LayerAnimationType.scale ? 0.3 : null,
                    ),
                  ],
                ),
              ],
            ),
          );
        });
      }
    }

    // ── All easing curves ─────────────────────────────────────
    for (final curve in AnimationCurve.values) {
      testWidgets('easing curve: ${curve.name}', (_) async {
        await testRender(
          description: 'easing ${curve.name}',
          renderModel: VideoRenderData(
            videoSegments: [VideoSegment(video: inputVideo)],
            outputFormat: VideoOutputFormat.mp4,
            imageLayers: [
              ImageLayer(
                image: overlayImage,
                offset: const Offset(100, 100),
                startTime: const Duration(seconds: 1),
                endTime: const Duration(seconds: 5),
                animations: [
                  LayerAnimation(
                    type: LayerAnimationType.fade,
                    phase: AnimationPhase.animateIn,
                    duration: const Duration(milliseconds: 500),
                    curve: curve,
                  ),
                ],
              ),
            ],
          ),
        );
      });
    }

    // ── All slide directions ──────────────────────────────────
    for (final dir in SlideDirection.values) {
      testWidgets('slide direction: ${dir.name}', (_) async {
        await testRender(
          description: 'slide ${dir.name}',
          renderModel: VideoRenderData(
            videoSegments: [VideoSegment(video: inputVideo)],
            outputFormat: VideoOutputFormat.mp4,
            imageLayers: [
              ImageLayer(
                image: overlayImage,
                offset: const Offset(200, 200),
                startTime: const Duration(seconds: 1),
                endTime: const Duration(seconds: 5),
                animations: [
                  LayerAnimation(
                    type: LayerAnimationType.slide,
                    phase: AnimationPhase.animateIn,
                    duration: const Duration(milliseconds: 500),
                    slideDirection: dir,
                  ),
                ],
              ),
            ],
          ),
        );
      });
    }

    // ── Combined animations (all types at once) ───────────────
    testWidgets('combined fade + slide + scale', (_) async {
      await testRender(
        description: 'Combined fade + slide + scale',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              offset: const Offset(300, 150),
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 8),
              animations: const [
                LayerAnimation(
                  type: LayerAnimationType.fade,
                  phase: AnimationPhase.animateInOut,
                  duration: Duration(milliseconds: 500),
                  curve: AnimationCurve.easeInOut,
                ),
                LayerAnimation(
                  type: LayerAnimationType.slide,
                  phase: AnimationPhase.animateIn,
                  duration: Duration(milliseconds: 600),
                  slideDirection: SlideDirection.left,
                  curve: AnimationCurve.bounceOut,
                ),
                LayerAnimation(
                  type: LayerAnimationType.scale,
                  phase: AnimationPhase.animateIn,
                  duration: Duration(milliseconds: 400),
                  scaleFrom: 0.3,
                  curve: AnimationCurve.elasticOut,
                ),
              ],
            ),
          ],
        ),
      );
    });

    // ── Multiple layers with different animations ─────────────
    testWidgets('multiple layers with different animations', (_) async {
      final overlay2 = EditorLayerImage.memory(
        await createTestOverlayImage(width: 150, height: 80),
      );
      await testRender(
        description: 'Multiple layers with different animations',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              offset: const Offset(50, 50),
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 5),
              animations: const [
                LayerAnimation(
                  type: LayerAnimationType.fade,
                  phase: AnimationPhase.animateIn,
                  duration: Duration(milliseconds: 400),
                ),
              ],
            ),
            ImageLayer(
              image: overlay2,
              offset: const Offset(400, 300),
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 7),
              animations: const [
                LayerAnimation(
                  type: LayerAnimationType.slide,
                  phase: AnimationPhase.animateIn,
                  duration: Duration(milliseconds: 500),
                  slideDirection: SlideDirection.right,
                  curve: AnimationCurve.easeOut,
                ),
                LayerAnimation(
                  type: LayerAnimationType.scale,
                  phase: AnimationPhase.animateOut,
                  duration: Duration(milliseconds: 300),
                  scaleFrom: 0.0,
                ),
              ],
            ),
          ],
        ),
      );
    });

    // ── Animation on full-duration layer (no time range) ──────
    testWidgets('animation on layer without time range (full duration)', (
      _,
    ) async {
      await testRender(
        description: 'Animation on full-duration layer',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              animations: const [
                LayerAnimation(
                  type: LayerAnimationType.fade,
                  phase: AnimationPhase.animateInOut,
                  duration: Duration(seconds: 1),
                  curve: AnimationCurve.easeInOut,
                ),
              ],
            ),
          ],
        ),
      );
    });
  });
}
