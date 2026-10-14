import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '/shared/utils/parser/double_parser.dart';
import '/shared/utils/parser/int_parser.dart';

/// [level] held to 0–1, with NaN counted as silent, as every renderer reads
/// a level.
double audioVisualizerUnitLevel(double level) =>
    level.isNaN ? 0 : level.clamp(0.0, 1.0);

/// How a [LayerAudioVisualizer] draws the levels of its bands.
///
/// Every style fills the layer's box and scales with it, so the
/// [AudioVisualizerPainter] in an editor and the export draw the same shapes
/// at any size.
enum AudioVisualizerStyle {
  /// One rounded bar per band, side by side, growing up from the bottom of
  /// the box; the first band is on the left.
  bars,

  /// One rounded bar per band, side by side, growing up and down from the
  /// middle of the box.
  mirroredBars,

  /// A filled wave through the bands, mirrored around the middle of the box
  /// and tapering to a point at its left and right edges.
  wave,

  /// Rounded bars pointing outward from a ring in the middle of the box, the
  /// bands running from the top down both sides, so the ring is symmetric.
  circle,
}

/// Turns an [ImageLayer] into an audio visualizer: bars or a wave that move
/// with the sound, drawn in the layer's box instead of its image.
///
/// The visualizer does not listen to the video's audio itself. It draws
/// [levels], a table the app computes from the sound, for example the
/// loudness of frequency bands, [framesPerSecond] rows a second on the
/// rendered video's timeline. A row holds one level per band, from 0
/// (silent) to 1 (loudest). Between two rows the levels are mixed linearly;
/// before the first row and after the last one every band is silent.
///
/// The layer gives the visualizer its place, size, rotation, time range,
/// animations and keyframes like any other image layer, and a fade or a
/// keyframe's opacity fades it.
///
/// ```dart
/// ImageLayer.audioVisualizer(
///   visualizer: LayerAudioVisualizer(
///     style: AudioVisualizerStyle.bars,
///     color: const Color(0xFF27C58B),
///     bandCount: 24,
///     levels: levels, // 24 values per row, 60 rows a second
///   ),
///   offset: const Offset(90, 1400),
///   size: const Size(900, 300),
/// );
/// ```
///
/// Use [AudioVisualizerPainter] to show the same visualizer in an editor.
///
/// Instances are immutable, but the constructor cannot be `const`: it checks
/// that [levels] holds whole rows.
class LayerAudioVisualizer {
  /// Creates a visualizer that draws [levels] in [style].
  LayerAudioVisualizer({
    required this.style,
    required this.bandCount,
    required this.levels,
    this.color = const Color(0xFFFFFFFF),
    this.framesPerSecond = 60,
    this.barFill,
  }) : assert(bandCount > 0, 'bandCount must be greater than 0'),
       assert(
         barFill == null || (barFill > 0 && barFill <= 1),
         'barFill must be greater than 0 and at most 1',
       ),
       assert(
         levels.length % bandCount == 0,
         'levels must hold bandCount values for every row',
       ),
       assert(
         framesPerSecond > 0 && framesPerSecond < double.infinity,
         'framesPerSecond must be a finite number greater than 0',
       );

  /// Creates a visualizer from [toMap]'s output.
  ///
  /// An unknown [style] name throws an [ArgumentError]. A [framesPerSecond]
  /// that is not a finite number above 0 falls back to 60, as the native
  /// renderers read it.
  factory LayerAudioVisualizer.fromMap(Map<String, dynamic> map) {
    final bandCount = math.max(1, safeParseInt(map['bandCount'], fallback: 1));
    final framesPerSecond = safeParseDouble(
      map['framesPerSecond'],
      fallback: 60,
    );
    final raw = map['levels'];
    final levels = switch (raw) {
      final Float32List list => list,
      final List<dynamic> list => Float32List.fromList([
        for (final value in list) safeParseDouble(value),
      ]),
      _ => Float32List(0),
    };
    return LayerAudioVisualizer(
      style: AudioVisualizerStyle.values.byName(map['style'] as String),
      bandCount: bandCount,
      // A table cut short keeps its whole rows only.
      levels: levels.length % bandCount == 0
          ? levels
          : Float32List.sublistView(
              levels,
              0,
              levels.length - levels.length % bandCount,
            ),
      color: Color(safeParseInt(map['color'], fallback: 0xFFFFFFFF)),
      framesPerSecond: framesPerSecond > 0 && framesPerSecond < double.infinity
          ? framesPerSecond
          : 60,
      barFill: switch (tryParseDouble(map['barFill'])) {
        final fill? when fill > 0 && fill <= 1 => fill,
        _ => null,
      },
    );
  }

  /// Creates a visualizer from [toJson]'s output.
  factory LayerAudioVisualizer.fromJson(String source) =>
      LayerAudioVisualizer.fromMap(json.decode(source) as Map<String, dynamic>);

  /// How the levels are drawn.
  final AudioVisualizerStyle style;

  /// The color every shape of the visualizer is filled with. Its alpha makes
  /// the visualizer see-through.
  final Color color;

  /// How many bands every row of [levels] holds.
  final int bandCount;

  /// The levels of every band, row after row: the level of `band` in row
  /// `row` is at `row * bandCount + band`. Row `row` is the moment
  /// `row / framesPerSecond` seconds into the rendered video, on the same
  /// timeline as [ImageLayer.startTime].
  ///
  /// Levels run from 0 (silent) to 1 (loudest); values outside are clamped,
  /// and NaN counts as silent.
  final Float32List levels;

  /// How many rows of [levels] there are a second.
  final double framesPerSecond;

  /// How much of its share of the box a bar fills, from above 0 to 1; the
  /// rest is the gap to the next bar.
  ///
  /// [AudioVisualizerStyle.wave] has no bars and ignores it.
  ///
  /// **Default**: `null`, which is `0.7` for [AudioVisualizerStyle.bars] and
  /// [AudioVisualizerStyle.mirroredBars] and `0.6` for
  /// [AudioVisualizerStyle.circle].
  final double? barFill;

  /// How many rows [levels] holds.
  int get frameCount => levels.length ~/ bandCount;

  /// The level of every band at [time] on the rendered video, mixed linearly
  /// between the two rows around it.
  ///
  /// Written into [into] when it is given and holds [bandCount] values.
  Float32List levelsAt(Duration time, [Float32List? into]) {
    final out = into != null && into.length == bandCount
        ? into
        : Float32List(bandCount);
    final position =
        time.inMicroseconds * framesPerSecond / Duration.microsecondsPerSecond;
    final row = position.floor();
    final mix = position - row;
    for (var band = 0; band < bandCount; band++) {
      final from = _level(row, band);
      final to = _level(row + 1, band);
      out[band] = from + (to - from) * mix;
    }
    return out;
  }

  double _level(int row, int band) {
    if (row < 0 || row >= frameCount) return 0;
    return audioVisualizerUnitLevel(levels[row * bandCount + band]);
  }

  /// The entry the native renderers read, with [levels] as typed data so the
  /// platform channel copies them in one piece.
  Map<String, dynamic> toChannelMap() => <String, dynamic>{
    'style': style.name,
    'color': color.toARGB32(),
    'bandCount': bandCount,
    'levels': levels,
    'framesPerSecond': framesPerSecond,
    'barFill': barFill,
  };

  /// Converts the visualizer into a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'style': style.name,
    'color': color.toARGB32(),
    'bandCount': bandCount,
    'levels': levels.toList(),
    'framesPerSecond': framesPerSecond,
    'barFill': barFill,
  };

  /// Converts the visualizer into JSON.
  String toJson() => json.encode(toMap());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayerAudioVisualizer &&
          other.style == style &&
          other.color == color &&
          other.bandCount == bandCount &&
          other.framesPerSecond == framesPerSecond &&
          other.barFill == barFill &&
          listEquals(other.levels, levels);

  @override
  int get hashCode => Object.hash(
    style,
    color,
    bandCount,
    framesPerSecond,
    barFill,
    Object.hashAll(levels),
  );

  @override
  String toString() =>
      'LayerAudioVisualizer(style: ${style.name}, color: $color, '
      'bandCount: $bandCount, frames: $frameCount, '
      'framesPerSecond: $framesPerSecond, barFill: $barFill)';
}
