import 'dart:math' as math;

/// A 2D similarity transform (uniform scale, rotation, translation) in
/// pixel coordinates centered on the frame, with y pointing down:
///
/// `x' = a·x − b·y + tx`, `y' = b·x + a·y + ty`.
///
/// A positive [angle] turns content clockwise on screen.
class SimilarityTransform {
  /// Creates a transform from its matrix coefficients.
  const SimilarityTransform(this.a, this.b, this.tx, this.ty);

  /// Creates a transform from a translation, an [angle] in radians and the
  /// natural logarithm of its scale.
  factory SimilarityTransform.fromParams({
    double tx = 0,
    double ty = 0,
    double angle = 0,
    double logScale = 0,
  }) {
    final scale = math.exp(logScale);
    return SimilarityTransform(
      scale * math.cos(angle),
      scale * math.sin(angle),
      tx,
      ty,
    );
  }

  /// The transform that leaves every point where it is.
  static const identity = SimilarityTransform(1, 0, 0, 0);

  /// `scale · cos(angle)`.
  final double a;

  /// `scale · sin(angle)`.
  final double b;

  /// Horizontal translation in pixels.
  final double tx;

  /// Vertical translation in pixels.
  final double ty;

  /// The uniform scale factor.
  double get scale => math.sqrt(a * a + b * b);

  /// The rotation in radians, clockwise on screen.
  double get angle => math.atan2(b, a);

  /// The natural logarithm of [scale].
  double get logScale => math.log(scale);

  /// Returns the transform that applies `this` first and [other] second.
  SimilarityTransform then(SimilarityTransform other) => SimilarityTransform(
    other.a * a - other.b * b,
    other.a * b + other.b * a,
    other.a * tx - other.b * ty + other.tx,
    other.b * tx + other.a * ty + other.ty,
  );

  /// Returns the transform that undoes this one.
  SimilarityTransform inverse() {
    final d = a * a + b * b;
    final ia = a / d;
    final ib = -b / d;
    return SimilarityTransform(
      ia,
      ib,
      -(ia * tx - ib * ty),
      -(ib * tx + ia * ty),
    );
  }

  /// The x coordinate of the point (x, y) after the transform.
  double mapX(double x, double y) => a * x - b * y + tx;

  /// The y coordinate of the point (x, y) after the transform.
  double mapY(double x, double y) => b * x + a * y + ty;

  @override
  String toString() =>
      'SimilarityTransform(t: (${tx.toStringAsFixed(3)}, '
      '${ty.toStringAsFixed(3)}), angle: '
      '${(angle * 180 / math.pi).toStringAsFixed(3)}°, '
      'scale: ${scale.toStringAsFixed(4)})';
}
