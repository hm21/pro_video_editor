// ignore_for_file: sort_constructors_first
import 'package:pro_video_editor/pro_video_editor.dart';

/// Configuration for a frame-accurate video split.
///
/// Cuts a single source video at [splitPosition] into two separate files
/// ([startOutputPath] and [endOutputPath]). The cut is frame-accurate: unlike a
/// stream-copy (passthrough) split, which can only cut on keyframe boundaries,
/// this re-encodes from the exact split frame so both halves start and end
/// precisely where requested.
///
/// This is a dedicated, lightweight operation — it does not run the full
/// rendering pipeline (no compositor, effects, overlays or audio mixing), which
/// makes it much faster and far less likely to stall than splitting via
/// [VideoRenderData].
class SplitVideoModel {
  /// Creates a [SplitVideoModel].
  ///
  /// [video] is the source clip, [splitPosition] is the absolute cut position
  /// within that source, and [startOutputPath] / [endOutputPath] are the
  /// destinations for the two resulting files.
  SplitVideoModel({
    String? id,
    required this.video,
    required this.splitPosition,
    required this.startOutputPath,
    required this.endOutputPath,
    this.outputFormat = VideoOutputFormat.mp4,
    this.qualityConfig,
    this.bitrate,
    this.enableAudio = true,
    this.exportTimeout = const Duration(seconds: 120),
    this.stallTimeout = const Duration(seconds: 12),
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
       assert(
         splitPosition > Duration.zero,
         'splitPosition must be greater than zero',
       ),
       assert(
         startOutputPath != endOutputPath,
         'startOutputPath and endOutputPath must differ',
       ),
       assert(
         bitrate == null || bitrate > 0,
         '[bitrate] must be greater than 0',
       ),
       assert(
         exportTimeout > Duration.zero,
         'exportTimeout must be greater than zero',
       ),
       assert(
         stallTimeout > Duration.zero,
         'stallTimeout must be greater than zero',
       );

  /// Unique ID for the task, used for progress updates and cancellation.
  final String id;

  /// The source video to split.
  final EditorVideo video;

  /// The absolute position within [video] at which to cut.
  ///
  /// The first half covers `0 → splitPosition`, the second half covers
  /// `splitPosition → end`.
  final Duration splitPosition;

  /// Absolute path where the first half (`0 → splitPosition`) is written.
  final String startOutputPath;

  /// Absolute path where the second half (`splitPosition → end`) is written.
  final String endOutputPath;

  /// The target container format for both output files.
  final VideoOutputFormat outputFormat;

  /// Optional quality configuration. When set, its bitrate is used unless
  /// [bitrate] is provided explicitly.
  final VideoQualityConfig? qualityConfig;

  /// Optional bitrate in bits per second for the re-encoded output.
  ///
  /// **WARNING macOS/iOS:** A specific bitrate cannot be set directly; the
  /// closest export preset is chosen instead.
  final int? bitrate;

  /// Whether to keep the source audio track in both halves.
  ///
  /// **Default**: `true`
  final bool enableAudio;

  /// Hard upper bound on how long a single half may export before the native
  /// watchdog force-cancels it and fails with a diagnostic timeout error.
  ///
  /// This is the outer safety net. In practice a stalled export is caught much
  /// sooner by [stallTimeout]; this only fires for an export that keeps
  /// reporting progress yet never finishes.
  ///
  /// **Default**: 120 seconds (the previous fixed behavior).
  final Duration exportTimeout;

  /// Inner bound: if the export makes no forward progress for this long, it is
  /// treated as stalled, force-cancelled and failed with a diagnostic error
  /// (which half, last progress, segment/total durations, preset/mime, audio).
  ///
  /// A stalled export — e.g. an encoder session waiting on an exhausted
  /// hardware pool — reports "stuck at 0%" and would otherwise sit idle until
  /// [exportTimeout]. A successful split always advances, so this never fires
  /// for a healthy export. Must be less than [exportTimeout] to have effect.
  ///
  /// **Default**: 12 seconds.
  final Duration stallTimeout;

  /// A [Stream] of [ProgressModel] updates for this split, keyed by [id].
  ///
  /// Progress spans both halves: the first half maps to `0.0 → 0.5` and the
  /// second half to `0.5 → 1.0`.
  Stream<ProgressModel> get progressStream {
    return ProVideoEditor.instance.progressStreamById(id);
  }

  /// The effective bitrate, falling back to [qualityConfig] when unset.
  int? get effectiveBitrate => bitrate ?? qualityConfig?.bitrate;
}
