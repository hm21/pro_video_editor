import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';

/// A dialog that displays real-time export progress for video generation.
///
/// Listens to the [VideoUtilsService.progressStream] and shows a
/// circular progress indicator with percentage text.
class VideoProgressAlert extends StatelessWidget {
  /// Creates a [VideoProgressAlert] widget.
  const VideoProgressAlert({super.key, this.taskId = ''});

  /// Optional taskId of the progress stream.
  final String taskId;

  bool get _canCancel => taskId.isNotEmpty && canCancelOnCurrentPlatform();

  Future<void> _handleCancelTap(BuildContext context) async {
    try {
      await ProVideoEditor.instance.cancel(taskId);
    } catch (error, stackTrace) {
      debugPrint('Failed to cancel render: $error\n$stackTrace');
    }
    // Always close the alert so the UI reflects the canceled render.
    LoadingDialog.instance.hide();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ModalBarrier(
          onDismiss: kDebugMode ? LoadingDialog.instance.hide : null,
          color: Colors.black54,
          dismissible: kDebugMode,
        ),
        Center(
          child: Theme(
            data: Theme.of(context),
            child: AlertDialog(
              contentPadding: const EdgeInsets.symmetric(
                vertical: 16,
                horizontal: 20,
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Padding(
                  padding: const EdgeInsets.only(top: 3.0),
                  child: _buildProgressBody(context),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBody(BuildContext context) {
    return VideoRendererProgressPanel(
      progressStream: ProVideoEditor.instance.progressStreamById(taskId),
      supportsCancel: _canCancel,
      onCancel: _canCancel ? () => _handleCancelTap(context) : null,
    );
  }
}
