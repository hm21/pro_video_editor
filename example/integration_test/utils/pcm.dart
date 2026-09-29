import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Mono PCM read from a WAV file, for measuring rendered audio.
class Pcm {
  /// Wraps [samples] (in -1..1) played at [sampleRate].
  Pcm(this.samples, this.sampleRate);

  /// Reads 16-bit integer or 32-bit float PCM, averaging the channels.
  factory Pcm.parseWav(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    int? format;
    var channels = 0;
    var sampleRate = 0;
    var bitsPerSample = 0;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final bytesPerSample = bitsPerSample ~/ 8;
        final end = math.min(body + size, bytes.length);
        final frames = (end - body) ~/ (bytesPerSample * channels);
        final samples = Float64List(frames);
        for (var f = 0; f < frames; f++) {
          var sum = 0.0;
          for (var c = 0; c < channels; c++) {
            final p = body + (f * channels + c) * bytesPerSample;
            sum += switch ((format, bitsPerSample)) {
              (3, 32) => data.getFloat32(p, Endian.little),
              (_, 16) => data.getInt16(p, Endian.little) / 32768,
              (_, 32) => data.getInt32(p, Endian.little) / 2147483648,
              _ => throw UnsupportedError('$bitsPerSample-bit PCM'),
            };
          }
          samples[f] = sum / channels;
        }
        return Pcm(samples, sampleRate);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('WAV without a data chunk');
  }

  /// The samples, one per frame.
  final Float64List samples;

  /// Frames per second.
  final int sampleRate;

  /// Length of the audio in seconds.
  double get seconds => samples.length / sampleRate;

  /// Root-mean-square level between [fromSec] and [toSec].
  double rms(double fromSec, double toSec) {
    final from = (fromSec * sampleRate).round().clamp(0, samples.length);
    final to = (toSec * sampleRate).round().clamp(from, samples.length);
    if (to <= from) return 0;
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += samples[i] * samples[i];
    }
    return math.sqrt(sum / (to - from));
  }

  /// The first and last moment, in seconds, at which the level measured over
  /// 10 ms windows reaches [threshold], or `null` if it never does.
  (double, double)? audibleSpan(double threshold) {
    const window = 0.01;
    double? first;
    double? last;
    for (var t = 0.0; t + window <= seconds; t += window) {
      if (rms(t, t + window) >= threshold) {
        first ??= t;
        last = t + window;
      }
    }
    return first == null ? null : (first, last!);
  }

  /// The pitch of a pure tone between [fromSec] and [toSec], in Hz, counted
  /// from its zero crossings.
  double toneFrequency(double fromSec, double toSec) {
    final from = (fromSec * sampleRate).round().clamp(1, samples.length);
    final to = (toSec * sampleRate).round().clamp(from, samples.length);
    var crossings = 0;
    for (var i = from; i < to; i++) {
      if ((samples[i - 1] < 0) != (samples[i] < 0)) crossings++;
    }
    return crossings / 2 / ((to - from) / sampleRate);
  }

  /// Encodes [seconds] of a [frequency] Hz sine at [amplitude] as a 16-bit
  /// mono WAV file.
  static Uint8List toneWav({
    required double seconds,
    double frequency = 440,
    double amplitude = 0.5,
    int sampleRate = 44100,
  }) {
    final frames = (seconds * sampleRate).round();
    final bytes = ByteData(44 + frames * 2);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + frames * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, frames * 2, Endian.little);
    for (var i = 0; i < frames; i++) {
      final value =
          amplitude * math.sin(2 * math.pi * frequency * i / sampleRate);
      bytes.setInt16(44 + i * 2, (value * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
