import 'dart:ui';

import 'double_parser.dart';

/// Safely parses a [Map] representation of a point to an [Offset] object.
///
/// This function attempts to convert the provided [map] to an [Offset] object.
/// If the [map] is `null`, missing required keys (`dx` and `dy`), or contains
/// invalid values, a [fallback] offset is returned instead.
///
/// - Parameters:
///   - [map]: A [Map] that is expected to contain `dx` and `dy` keys, where
///            their values can be converted to [double].
///   - [fallback]: An [Offset] value to return if parsing fails or if [map] is
///                 `null`.
///                 Defaults to [Offset.zero] if not provided.
///
/// - Returns:
///   An [Offset] object constructed from the [map] if parsing succeeds, or the
///   [fallback] offset if it fails.
///
/// - Example:
/// ```dart
/// safeParseOffset({'dx': 200, 'dy': 100}); // returns Offset(200.0, 100.0)
/// safeParseOffset(null);                   // returns Offset.zero (fallback)
/// safeParseOffset({'dx': 'abc', 'dy': 50}, fallback: Offset(10, 10));
///                                          // returns Offset(10.0, 50.0)
/// ```
Offset safeParseOffset(
  Map<String, dynamic>? map, {
  Offset fallback = Offset.zero,
}) {
  if (map == null) return fallback;

  return Offset(
    safeParseDouble(map['dx'], fallback: fallback.dx),
    safeParseDouble(map['dy'], fallback: fallback.dy),
  );
}
