import 'dart:convert';

import 'package:flutter/foundation.dart';

import '/shared/models/time_range_mixin.dart';
import '/shared/utils/parser/int_parser.dart';

/// A video effect the app implements itself, in native code it registers with
/// the plugin under [id].
///
/// The plugin renders it on every frame between [startTime] and [endTime],
/// right after the frame is decoded and before the built-in
/// `VideoRenderData.effects`, so it sees the clip as recorded. It hands the
/// effect the current frame and, when the effect asks for them, earlier frames
/// of the same clip, which lets an effect such as an echo trail look the same
/// however the video is played or seeked.
///
/// Register the implementation before rendering, on Android:
///
/// ```kotlin
/// CustomVideoEffects.register("my.echo") { params -> EchoRenderer(params) }
/// ```
///
/// and on iOS and macOS:
///
/// ```swift
/// CustomVideoEffects.register("my.echo") { params in EchoRenderer(params) }
/// ```
///
/// A render that names an [id] nothing is registered under fails.
///
/// **Note:** Android, iOS and macOS export custom effects. On iOS and macOS a
/// render with a `VideoRenderData.composition` skips them for now. Web,
/// Windows, Linux and `VideoEffectPreview` ignore them.
@immutable
class CustomVideoEffect with TimeRangeMixin {
  /// Creates a custom effect, rendered by whatever is registered under [id].
  const CustomVideoEffect({
    required this.id,
    this.params = const {},
    this.startTime,
    this.endTime,
  }) : assert(id != '', 'id must not be empty');

  /// Reads an effect written by [toMap].
  factory CustomVideoEffect.fromMap(Map<String, dynamic> map) {
    return CustomVideoEffect(
      id: map['id'] as String,
      params: Map<String, Object?>.from(map['params'] as Map? ?? const {}),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
    );
  }

  /// The name the native implementation is registered under.
  ///
  /// Prefix it with your app or package, like `divine.echo`, so it cannot
  /// collide with another package's effect.
  final String id;

  /// Settings handed to the native implementation as they are.
  ///
  /// Values must be types the platform channel can carry: `null`, `bool`,
  /// numbers, `String`, and lists and maps of those.
  final Map<String, Object?> params;

  @override
  final Duration? startTime;

  @override
  final Duration? endTime;

  /// The entry the native renderers read, with its time range in
  /// microseconds on the rendered video.
  Map<String, dynamic> toChannelMap() => <String, dynamic>{
    'id': id,
    'params': params,
    'startUs': startTime?.inMicroseconds,
    'endUs': endTime?.inMicroseconds,
  };

  /// Converts the effect into a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'params': params,
    'startTime': startTime?.inMicroseconds,
    'endTime': endTime?.inMicroseconds,
  };

  /// Converts the effect into JSON.
  String toJson() => json.encode(toMap());

  @override
  bool operator ==(Object other) =>
      other is CustomVideoEffect &&
      other.id == id &&
      mapEquals(other.params, params) &&
      other.startTime == startTime &&
      other.endTime == endTime;

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAllUnordered(
      params.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    startTime,
    endTime,
  );

  @override
  String toString() =>
      'CustomVideoEffect(id: $id, params: $params, '
      'startTime: $startTime, endTime: $endTime)';
}
