import 'package:flutter/material.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Progress indicator panel displayed while the renderer is exporting a video.
class VideoRendererProgressPanel extends StatelessWidget {
  /// Creates a [VideoRendererProgressPanel].
  const VideoRendererProgressPanel({
    super.key,
    required this.progressStream,
    required this.supportsCancel,
    this.onCancel,
  });

  /// Emits [ProgressModel] updates for the active render task.
  final Stream<ProgressModel> progressStream;

  /// Whether the current platform exposes a cancel API.
  final bool supportsCancel;

  /// Invoked when the cancel button is tapped.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ProgressModel>(
      stream: progressStream,
      builder: (context, snapshot) {
        final double progress = snapshot.data?.progress ?? 0;

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: progress),
          duration: const Duration(milliseconds: 300),
          builder: (context, animatedValue, _) {
            return Column(
              spacing: 12,
              children: [
                CircularProgressIndicator(
                  value: animatedValue,
                  // ignore: deprecated_member_use
                  year2023: false,
                ),
                Text('${(animatedValue * 100).toStringAsFixed(1)} / 100'),
                if (supportsCancel && onCancel != null)
                  FilledButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Cancel render'),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
