import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

/// What [ChromaKeyDetector] read out of a frame.
class ChromaKeyDetection {
  /// Creates a [ChromaKeyDetection].
  const ChromaKeyDetection({
    required this.color,
    required this.similarity,
    required this.coverage,
    required this.spread,
  });

  /// The screen color as it was actually recorded — not the paint it was
  /// mixed from. These differ by more than you would expect: a studio screen
  /// painted SMPTE green (`0xFF00B140`) measured `0xFF2A9D37` through the
  /// camera, which is a chroma distance of `0.12` — most of the budget a
  /// hand-set key has to spend before it touches the subject.
  final Color color;

  /// A [similarity] that covers the measured spread of the screen with room to
  /// spare, without reaching further than it has to.
  final double similarity;

  /// The fraction of sampled border pixels that belong to the detected screen,
  /// in `0..1`.
  ///
  /// Low coverage means the border was not one solid color — the frame likely
  /// shows more than just the screen (studio walls, lights, a subject standing
  /// at the edge), and the result should not be trusted.
  final double coverage;

  /// The 99th-percentile chroma distance of the screen from [color].
  ///
  /// This is the raw measurement [similarity] is derived from; a large value
  /// means an unevenly lit screen.
  final double spread;

  @override
  String toString() =>
      'ChromaKeyDetection(color: $color, similarity: '
      '${similarity.toStringAsFixed(3)}, coverage: '
      '${(coverage * 100).toStringAsFixed(0)}%, spread: '
      '${spread.toStringAsFixed(3)})';
}

/// Thrown when a frame does not contain a usable screen.
class ChromaKeyDetectionException implements Exception {
  /// Creates a [ChromaKeyDetectionException] with a [message] explaining what
  /// the frame looked like instead.
  const ChromaKeyDetectionException(this.message);

  /// What was measured, and why it is not a screen.
  final String message;

  @override
  String toString() => 'ChromaKeyDetectionException: $message';
}

/// Reads the screen color and its spread out of a frame.
///
/// A fixed key color is always a compromise: paint, fabric, lighting and the
/// camera's own color science all move the recorded green away from whatever
/// constant the caller picked, and every bit of that offset has to be absorbed
/// by a wider [ChromaKey.similarity] — which is budget taken away from the
/// margin that protects the subject. Measuring the screen instead removes the
/// offset entirely, and works the same for a green, blue or any other screen.
///
/// The screen is assumed to reach the frame border, which is what lets the
/// subject be ignored: only a ring around the edge is sampled.
abstract final class ChromaKeyDetector {
  /// Fraction of the frame, per side, sampled as the border ring.
  static const _ringFraction = 0.12;

  /// A screen has to be at least this saturated. Below it, the border is grey
  /// or black and there is nothing to key.
  static const _minChromaMagnitude = 0.08;

  /// At least this share of the border must belong to one color.
  static const _minCoverage = 0.6;

  /// Multiplier on the measured spread, so the soft edge and a little
  /// frame-to-frame noise stay inside the key.
  static const _spreadMargin = 2.0;

  /// Never key tighter than this, or compression noise on a flat screen starts
  /// poking through.
  static const _minSimilarity = 0.08;

  /// Never key wider than this from a measurement alone — beyond it the risk of
  /// eating the subject outweighs whatever the border suggested.
  static const _maxSimilarity = 0.35;

  /// BT.601 chroma of a gamma-encoded RGB triple in `0..1`, matching the
  /// keying formula the renderers use.
  static ({double cb, double cr}) chromaOf(double r, double g, double b) => (
    cb: -0.168736 * r - 0.331264 * g + 0.5 * b,
    cr: 0.5 * r - 0.418688 * g - 0.081312 * b,
  );

  /// Detects the screen in one or more RGBA frames.
  ///
  /// [frames] are raw RGBA buffers, all [width] x [height]. Passing several
  /// frames pools their border pixels, which averages out sensor noise and a
  /// subject that briefly touches the edge.
  ///
  /// Throws a [ChromaKeyDetectionException] when the border is not one
  /// saturated color.
  static ChromaKeyDetection fromFrames(
    List<Uint8List> frames, {
    required int width,
    required int height,
  }) {
    if (frames.isEmpty) {
      throw const ChromaKeyDetectionException('No frames to analyze');
    }

    final ringR = <double>[];
    final ringG = <double>[];
    final ringB = <double>[];

    final marginX = max(1, (width * _ringFraction).round());
    final marginY = max(1, (height * _ringFraction).round());

    for (final frame in frames) {
      if (frame.length < width * height * 4) {
        throw ChromaKeyDetectionException(
          'Frame buffer is ${frame.length} bytes, expected at least '
          '${width * height * 4} for ${width}x$height RGBA',
        );
      }
      for (var y = 0; y < height; y++) {
        final onHorizontalEdge = y < marginY || y >= height - marginY;
        for (var x = 0; x < width; x++) {
          if (!onHorizontalEdge && x >= marginX && x < width - marginX) {
            // Interior: skip ahead to the right-hand band in one step.
            x = width - marginX - 1;
            continue;
          }
          final i = (y * width + x) * 4;
          ringR.add(frame[i] / 255);
          ringG.add(frame[i + 1] / 255);
          ringB.add(frame[i + 2] / 255);
        }
      }
    }

    if (ringR.isEmpty) {
      throw const ChromaKeyDetectionException('Frame is too small to sample');
    }

    // The median rejects the subject and any studio clutter that reaches the
    // edge, as long as they are the minority there — which an average would
    // not, since a few bright pixels drag it a long way.
    final r = _median(ringR);
    final g = _median(ringG);
    final b = _median(ringB);
    final key = chromaOf(r, g, b);
    final magnitude = sqrt(key.cb * key.cb + key.cr * key.cr);

    if (magnitude < _minChromaMagnitude) {
      throw ChromaKeyDetectionException(
        'The frame border averages to a near-neutral color '
        '(chroma magnitude ${magnitude.toStringAsFixed(3)}), so there is no '
        'screen to key. Is the screen actually reaching the frame edge?',
      );
    }

    // How far each border pixel sits from that color.
    final distances = List<double>.generate(ringR.length, (i) {
      final c = chromaOf(ringR[i], ringG[i], ringB[i]);
      final dcb = c.cb - key.cb;
      final dcr = c.cr - key.cr;
      return sqrt(dcb * dcb + dcr * dcr);
    })..sort();

    final spread = distances[(distances.length * 0.99).floor().clamp(
      0,
      distances.length - 1,
    )];

    // Coverage uses a generous band around the median, so a soft edge counts
    // as screen while a wall or a sleeve does not.
    final band = max(spread, _minSimilarity);
    final covered = distances.where((d) => d <= band).length;
    final coverage = covered / distances.length;

    if (coverage < _minCoverage) {
      throw ChromaKeyDetectionException(
        'Only ${(coverage * 100).toStringAsFixed(0)}% of the frame border is '
        'one color, so it is not a clean screen. Crop the frame to the screen '
        'area, or set the key manually.',
      );
    }

    final similarity = (spread * _spreadMargin).clamp(
      _minSimilarity,
      _maxSimilarity,
    );

    return ChromaKeyDetection(
      color: Color.fromARGB(
        255,
        (r * 255).round().clamp(0, 255),
        (g * 255).round().clamp(0, 255),
        (b * 255).round().clamp(0, 255),
      ),
      similarity: similarity,
      coverage: coverage,
      spread: spread,
    );
  }

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
}
