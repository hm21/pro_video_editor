import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// Model representing a progress update.
class ProgressModel {
  /// Creates a [ProgressModel] with given [id] and [progress].
  const ProgressModel({required this.id, required this.progress});

  /// Creates a [ProgressModel] from a map.
  factory ProgressModel.fromMap(Map<dynamic, dynamic> map) {
    return ProgressModel(
      id: map['id'] ?? '',
      progress: safeParseDouble(map['progress']),
    );
  }

  /// The ID of the task.
  final String id;

  /// The progress value (0.0 to 1.0).
  final double progress;
}
