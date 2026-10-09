import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// The shape of an [AudioEqualizerBand]'s filter.
enum AudioEqualizerBandType {
  /// Raises or lowers everything below the band's frequency.
  lowShelf,

  /// Raises or lowers a bell around the band's frequency, as wide as its
  /// [AudioEqualizerBand.q] makes it.
  peak,

  /// Raises or lowers everything above the band's frequency.
  highShelf,
}

/// One filter of an [AudioEqualizer]: a shelf or a peak at [frequency] that
/// raises or lowers the audio by [gain] decibels.
@immutable
class AudioEqualizerBand {
  /// Creates a band of the given [type] at [frequency] hertz.
  const AudioEqualizerBand({
    required this.type,
    required this.frequency,
    this.gain = 0,
    this.q = defaultQ,
  }) : assert(frequency > 0, '[frequency] must be greater than 0'),
       assert(q > 0, '[q] must be greater than 0');

  /// Parses a band from [toMap]'s output.
  ///
  /// Throws a [FormatException] when [map] names no known type or no
  /// frequency above 0.
  factory AudioEqualizerBand.fromMap(Map<String, dynamic> map) =>
      _tryParse(map) ??
      (throw FormatException('Not an audio equalizer band: $map'));

  /// The [q] of a band when none is given: 1/√2, about two octaves wide at
  /// half its gain.
  static const double defaultQ = 0.7071067811865476;

  /// The shape of the filter.
  final AudioEqualizerBandType type;

  /// The corner of a shelf or the center of a peak, in hertz.
  ///
  /// A frequency too close to half the sample rate of the audio is lowered to
  /// 45 % of it, where the filter still behaves.
  final double frequency;

  /// How far the band is raised (positive) or lowered (negative), in
  /// decibels.
  final double gain;

  /// How narrow a peak is: the higher, the narrower.
  ///
  /// Shelves ignore it; they always have a slope of 1.
  final double q;

  /// Converts this band to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'frequencyHz': frequency,
      'gainDb': gain,
      'q': q,
    };
  }

  /// Returns a copy of this band with the given fields replaced.
  AudioEqualizerBand copyWith({
    AudioEqualizerBandType? type,
    double? frequency,
    double? gain,
    double? q,
  }) {
    return AudioEqualizerBand(
      type: type ?? this.type,
      frequency: frequency ?? this.frequency,
      gain: gain ?? this.gain,
      q: q ?? this.q,
    );
  }

  /// The band [map] describes, or null when it names no known type or no
  /// frequency above 0. A missing or non-positive q falls back to [defaultQ].
  static AudioEqualizerBand? _tryParse(Map<dynamic, dynamic> map) {
    final typeName = map['type'];
    final type = AudioEqualizerBandType.values
        .where((type) => type.name == typeName)
        .firstOrNull;
    final frequency = safeParseDouble(map['frequencyHz']);
    if (type == null || !(frequency > 0) || frequency.isInfinite) return null;
    final q = safeParseDouble(map['q'], fallback: defaultQ);
    return AudioEqualizerBand(
      type: type,
      frequency: frequency,
      gain: safeParseDouble(map['gainDb']),
      q: q > 0 ? q : defaultQ,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AudioEqualizerBand &&
            other.type == type &&
            other.frequency == frequency &&
            other.gain == gain &&
            other.q == q;
  }

  @override
  int get hashCode => Object.hash(type, frequency, gain, q);

  @override
  String toString() {
    return 'AudioEqualizerBand(type: ${type.name}, frequency: $frequency, '
        'gain: $gain, q: $q)';
  }
}

/// Raises or lowers parts of a clip's or a track's audio with a list of
/// [bands], each a low shelf, a peak or a high shelf.
///
/// The bands are the filters of Robert Bristow-Johnson's Audio EQ Cookbook,
/// applied one after the other in the order given. A shelf has a slope of 1:
/// it passes half its gain at its corner frequency and all of it an octave or
/// two beyond. A peak passes all of its gain at its center frequency and less
/// the further away a tone is, how much less set by its Q.
///
/// A boost can push material that is already near full scale past it, so
/// while any band's gain is above zero the filtered signal is limited at
/// -1 dBFS, like an amplifying volume, rather than clipped.
@immutable
class AudioEqualizer {
  /// Creates an equalizer with the given [bands].
  const AudioEqualizer({this.bands = const []});

  /// Parses an equalizer from [toMap]'s output, skipping the bands it cannot
  /// parse (see [AudioEqualizerBand.fromMap]).
  factory AudioEqualizer.fromMap(Map<String, dynamic> map) {
    final bands = map['bands'];
    return AudioEqualizer(
      bands: [
        if (bands is List)
          for (final band in bands)
            if (band is Map) ?AudioEqualizerBand._tryParse(band),
      ],
    );
  }

  /// The filters, applied in order.
  final List<AudioEqualizerBand> bands;

  /// Whether this equalizer leaves the audio unchanged.
  bool get isFlat => bands.every((band) => band.gain == 0);

  /// Whether any band raises the audio, which can push it past full scale.
  bool get boosts => bands.any((band) => band.gain > 0);

  /// Converts this equalizer to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'bands': [for (final band in bands) band.toMap()],
    };
  }

  /// Returns a copy of this equalizer with the given fields replaced.
  AudioEqualizer copyWith({List<AudioEqualizerBand>? bands}) {
    return AudioEqualizer(bands: bands ?? this.bands);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AudioEqualizer && listEquals(other.bands, bands);
  }

  @override
  int get hashCode => Object.hashAll(bands);

  @override
  String toString() => 'AudioEqualizer(bands: $bands)';
}
