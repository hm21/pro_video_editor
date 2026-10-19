import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/exceptions/render_exceptions.dart';
import '../models/frame/luma_frame_configs_model.dart';
import '../models/video/editor_video_model.dart';
import '../models/video/video_loop_point_model.dart';
import '../platform/platform_interface.dart';

/// Finds where to cut a video so that it loops without a visible jump.
///
/// A loop restarts seamlessly when the frame it would show after its last
/// one looks like its first frame: the restart is then one more step of the
/// motion. The finder compares the frames near the end of the video (the
/// tail) with the frames at its start (the head) and picks the cut where
/// they match best. It is plain frame comparison on small grayscale frames,
/// with no ML model.
///
/// Feed the head and the tail as small 8-bit luma buffers in presentation
/// order (around 192 pixels on the long side is plenty; they are reduced
/// further for the comparison), then call [find]. [findLoopPoint] does all
/// of it for a video file.
///
/// Each frame is compared together with its neighbours, so a pendulum that
/// is in the same place but swinging the other way does not match.
class VideoLoopPointFinder {
  /// Creates a finder for frames of [width] × [height] pixels.
  VideoLoopPointFinder({required this.width, required this.height})
    : assert(width > 0 && height > 0, 'frames must not be empty') {
    final factor = math.max(
      1,
      (math.max(width, height) / _analysisSide).ceil(),
    );
    _analysisWidth = math.max(1, width ~/ factor);
    _analysisHeight = math.max(1, height ~/ factor);
  }

  /// Finds the loop point of [video] end to end: streams the head and the
  /// tail with `ProVideoEditor.getLumaFrameStream` and compares them.
  ///
  /// [start] and [end] are the loop as it is now: it shows the source from
  /// [start] up to, but not including, [end]. The new end is searched
  /// between [endFrom] and [endTo]; frames past [end] count, so a cut that
  /// brings back footage trimmed off before can be found too. The start
  /// stays at [start] unless [startFrom] and [startTo] give it a range as
  /// well. Among cuts that match about equally well, the one that moves
  /// the start and end the least wins.
  ///
  /// A loop that starts over in another file than it ends in, like a
  /// composition whose first and last clips differ, passes the first one as
  /// [startVideo]; [start], [startFrom] and [startTo] are then times in
  /// [startVideo], and the end may lie before the start.
  ///
  /// [frameSize] bounds the decoded frames. [onProgress] reports the share
  /// of the frames decoded so far.
  ///
  /// The frames are compared on the calling isolate, which takes a few
  /// milliseconds for a range of a few seconds. A start range multiplies
  /// that by its frame count, so keep both ranges short when searching both.
  ///
  /// Cancel with [cancel] and the same [id]; the future then fails with a
  /// [RenderCanceledException].
  ///
  /// Throws an [ArgumentError] for an empty range, a [StateError] when no
  /// frame lies in a range to cut in, a [PlatformException] when the video
  /// cannot be decoded or a range lies past its end, and an
  /// [UnsupportedError] on the web.
  static Future<VideoLoopPoint> findLoopPoint(
    EditorVideo video, {
    EditorVideo? startVideo,
    required Duration start,
    required Duration end,
    required Duration endFrom,
    required Duration endTo,
    Duration? startFrom,
    Duration? startTo,
    Size frameSize = const Size(192, 192),
    int? maxParallelDecoders,
    String? id,
    void Function(double progress)? onProgress,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Loop point search is not supported on the web');
    }
    _checkRanges(
      start: start,
      end: end,
      endFrom: endFrom,
      endTo: endTo,
      startFrom: startFrom,
      startTo: startTo,
      startsInSameVideo: startVideo == null,
    );
    final taskId = id ?? DateTime.now().microsecondsSinceEpoch.toString();
    // The neighbours each side of a cut are compared too, so both ranges are
    // read a little wider than the cuts they allow.
    final headFrom = _atLeastZero(_min(startFrom ?? start, start) - _margin);
    final headTo = _max(startTo ?? start, start) + _margin;
    final tailFrom = _atLeastZero(_min(endFrom, end) - _margin);
    final tailTo = _max(endTo, end) + _margin;
    final headShare =
        (headTo - headFrom).inMicroseconds /
        ((headTo - headFrom) + (tailTo - tailFrom)).inMicroseconds;

    final search = _Search();
    final searches = _searches.putIfAbsent(taskId, () => {})..add(search);
    try {
      VideoLoopPointFinder? finder;
      Future<void> read(
        Duration from,
        Duration to, {
        required bool head,
        required double progressFrom,
        required double progressShare,
      }) async {
        if (search.canceled) throw const RenderCanceledException();
        // Every stream runs under a task id of its own: native refuses a
        // second task under an id whose decoder is still being torn down, as
        // after a cancel or in an earlier call under the same id.
        final stream = '$taskId-${head ? 'head' : 'tail'}-${_streams++}';
        search.stream = stream;
        await for (final frame in ProVideoEditor.instance.getLumaFrameStream(
          LumaFrameConfigs(
            video: head ? startVideo ?? video : video,
            outputSize: frameSize,
            startTime: from,
            endTime: to,
            maxParallelDecoders: maxParallelDecoders,
            id: stream,
          ),
        )) {
          finder ??= VideoLoopPointFinder(
            width: frame.width,
            height: frame.height,
          );
          if (head) {
            finder!.addHeadFrame(
              frame.bytes,
              frame.time,
              width: frame.width,
              height: frame.height,
            );
          } else {
            finder!.addTailFrame(
              frame.bytes,
              frame.time,
              width: frame.width,
              height: frame.height,
            );
          }
          onProgress?.call(progressFrom + frame.progress * progressShare);
        }
      }

      await read(
        headFrom,
        headTo,
        head: true,
        progressFrom: 0,
        progressShare: headShare,
      );
      await read(
        tailFrom,
        tailTo,
        head: false,
        progressFrom: headShare,
        progressShare: 1 - headShare,
      );
      // A cancel that came after the last frames were read.
      if (search.canceled) throw const RenderCanceledException();
      if (finder == null) throw StateError('No frames were decoded');
      final result = finder!.find(
        start: start,
        end: end,
        endFrom: endFrom,
        endTo: endTo,
        startFrom: startFrom,
        startTo: startTo,
        startsInSameVideo: startVideo == null,
      );
      onProgress?.call(1);
      return result;
    } finally {
      searches.remove(search);
      if (searches.isEmpty) _searches.remove(taskId);
    }
  }

  /// Cancels the [findLoopPoint] calls started with [id], including the
  /// frame decoding they run. They then fail with a
  /// [RenderCanceledException]. Does nothing when no such call runs.
  static Future<void> cancel(String id) async {
    final searches = _searches[id];
    if (searches == null) return;
    await Future.wait([
      for (final search in searches.toList()) search.cancel(),
    ]);
  }

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// The long side frames are reduced to before they are compared: enough
  /// to tell poses apart, and coarse enough that sensor noise and a pixel
  /// of camera shake average out.
  static const int _analysisSide = 64;

  /// How many neighbours on each side of a cut are compared as well.
  static const int _reach = 2;

  /// How much a neighbour counts, by its distance from the cut.
  static const List<double> _weights = [1, 0.5, 0.25];

  /// How much wider than the cuts it allows a range is read, so the
  /// neighbours of its first and last cut are decoded too: [_reach] frames
  /// down to about 10 fps.
  static const Duration _margin = Duration(milliseconds: 250);

  /// Cuts whose [VideoLoopPoint.difference] is within this share of one
  /// frame's worth of motion of the best one match about equally well. A
  /// cut one frame off costs about one frame's worth, so it never ties.
  static const double _tieShare = 0.25;

  /// The least two cuts may differ by and still tie, for a video whose
  /// frames do not change at all.
  static const double _tieFloor = 0.0002;

  /// The [findLoopPoint] calls running now, by the id they were started
  /// with. A call canceled under an id may still be stopping when the next
  /// one under that id starts.
  static final Map<String, Set<_Search>> _searches = {};

  /// How many frame streams were started, so that each gets a task id of
  /// its own.
  static int _streams = 0;

  late final int _analysisWidth;
  late final int _analysisHeight;
  final List<_Frame> _head = [];
  final List<_Frame> _tail = [];

  /// How many head frames were added so far.
  int get headFrameCount => _head.length;

  /// How many tail frames were added so far.
  int get tailFrameCount => _tail.length;

  /// Adds the next frame of the head: the frames at and around the start of
  /// the loop. [luma] is row-major, one byte per pixel; [time] is the
  /// frame's source timestamp.
  ///
  /// A frame of another size than [width] × [height], as the head of a
  /// `startVideo` can be, passes its own; it is stretched onto the same
  /// grid for the comparison.
  void addHeadFrame(Uint8List luma, Duration time, {int? width, int? height}) =>
      _add(_head, luma, time, width ?? this.width, height ?? this.height);

  /// Adds the next frame of the tail: the frames the new end is searched
  /// in, and the ones around them. [luma], [time], [width] and [height]
  /// work as in [addHeadFrame].
  void addTailFrame(Uint8List luma, Duration time, {int? width, int? height}) =>
      _add(_tail, luma, time, width ?? this.width, height ?? this.height);

  /// Finds the best cut among the frames added so far.
  ///
  /// The arguments mean the same as in [findLoopPoint]; pass
  /// [startsInSameVideo] false when the head was read from a `startVideo`.
  /// A cut can only land on a frame that was added: the end on a tail frame
  /// and the start on a head frame, and in one video the end after the
  /// start.
  ///
  /// Throws an [ArgumentError] for an empty range and a [StateError] when a
  /// range holds no frames.
  VideoLoopPoint find({
    required Duration start,
    required Duration end,
    required Duration endFrom,
    required Duration endTo,
    Duration? startFrom,
    Duration? startTo,
    bool startsInSameVideo = true,
  }) {
    _checkRanges(
      start: start,
      end: end,
      endFrom: endFrom,
      endTo: endTo,
      startFrom: startFrom,
      startTo: startTo,
      startsInSameVideo: startsInSameVideo,
    );
    final current = _firstAtOrAfter(_head, start);
    if (current == null) {
      throw StateError('No head frame at or after the start $start');
    }
    final starts = _candidates(_head, startFrom ?? start, startTo ?? start);
    final ends = _candidates(_tail, endFrom, endTo);
    if (starts.isEmpty) throw StateError('No head frame in the start range');
    if (ends.isEmpty) throw StateError('No tail frame in the end range');

    final cache = Float64List(_head.length * _tail.length)
      ..fillRange(0, _head.length * _tail.length, double.nan);
    double pair(int a, int b) {
      final index = a * _head.length + b;
      final cached = cache[index];
      if (!cached.isNaN) return cached;
      return cache[index] = _difference(_tail[a].pixels, _head[b].pixels);
    }

    double seam(int a, int b) {
      var sum = 0.0;
      var weight = 0.0;
      for (var k = -_reach; k <= _reach; k++) {
        final ta = a + k;
        final hb = b + k;
        if (ta < 0 || ta >= _tail.length || hb < 0 || hb >= _head.length) {
          continue;
        }
        final w = _weights[k.abs()];
        sum += w * pair(ta, hb);
        weight += w;
      }
      return sum / weight;
    }

    final scored = <(int, int, double)>[
      for (final b in starts)
        for (final a in ends)
          if (!startsInSameVideo || _tail[a].time > _head[b].time)
            (a, b, seam(a, b)),
    ];
    if (scored.isEmpty) {
      throw StateError('Every end in the range lies before every start');
    }
    final best = scored.map((s) => s.$3).reduce(math.min);
    final limit = best + math.max(_tieFloor, _tieShare * _medianStep());
    int change((int, int, double) s) =>
        (_tail[s.$1].time - end).inMicroseconds.abs() +
        (_head[s.$2].time - start).inMicroseconds.abs();
    final (a, b, difference) = scored.where((s) => s.$3 <= limit).reduce((
      x,
      y,
    ) {
      final byChange = change(x).compareTo(change(y));
      if (byChange != 0) return byChange < 0 ? x : y;
      return x.$3 <= y.$3 ? x : y;
    });

    final atEnd = _firstAtOrAfter(_tail, end);
    final double currentDifference;
    if (atEnd != null) {
      currentDifference = seam(atEnd, current);
    } else if (_tail.isNotEmpty) {
      // No frame at the end: the video stops after its last frame, which
      // then leads into the first one.
      currentDifference = pair(_tail.length - 1, current);
    } else {
      currentDifference = difference;
    }

    return VideoLoopPoint(
      start: _head[b].time,
      end: _tail[a].time,
      difference: difference,
      currentDifference: currentDifference,
    );
  }

  /// How much the tail changes from one frame to the next, typically: one
  /// frame's worth of motion.
  double _medianStep() {
    if (_tail.length < 2) return 0;
    final steps = [
      for (var i = 1; i < _tail.length; i++)
        _difference(_tail[i - 1].pixels, _tail[i].pixels),
    ]..sort();
    return steps[steps.length ~/ 2];
  }

  void _add(
    List<_Frame> frames,
    Uint8List luma,
    Duration time,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0 || luma.length < width * height) {
      throw ArgumentError.value(
        luma.length,
        'luma',
        'expected $width x $height = ${width * height} bytes',
      );
    }
    if (frames.isNotEmpty && time <= frames.last.time) {
      throw ArgumentError.value(time, 'time', 'frames must arrive in order');
    }
    frames.add(_Frame(time, _reduce(luma, width, height)));
  }

  /// [luma], [width] × [height] pixels, averaged onto the analysis grid:
  /// each cell is the mean of the pixels it covers.
  Uint8List _reduce(Uint8List luma, int width, int height) {
    final out = Uint8List(_analysisWidth * _analysisHeight);
    for (var y = 0; y < _analysisHeight; y++) {
      final y0 = y * height ~/ _analysisHeight;
      final y1 = math.max(y0 + 1, (y + 1) * height ~/ _analysisHeight);
      for (var x = 0; x < _analysisWidth; x++) {
        final x0 = x * width ~/ _analysisWidth;
        final x1 = math.max(x0 + 1, (x + 1) * width ~/ _analysisWidth);
        var sum = 0;
        for (var sy = y0; sy < y1; sy++) {
          final row = sy * width;
          for (var sx = x0; sx < x1; sx++) {
            sum += luma[row + sx];
          }
        }
        final area = (y1 - y0) * (x1 - x0);
        out[y * _analysisWidth + x] = (sum + area ~/ 2) ~/ area;
      }
    }
    return out;
  }

  /// The mean absolute difference of two reduced frames, from 0 to 1.
  static double _difference(Uint8List a, Uint8List b) {
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / (a.length * 255);
  }

  /// The indices of the first frame at or after [from] and of every later
  /// frame up to [to].
  static List<int> _candidates(
    List<_Frame> frames,
    Duration from,
    Duration to,
  ) {
    final first = _firstAtOrAfter(frames, from);
    if (first == null) return const [];
    return [
      for (var i = first; i < frames.length; i++)
        if (i == first || frames[i].time <= to) i,
    ];
  }

  static int? _firstAtOrAfter(List<_Frame> frames, Duration time) {
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].time >= time) return i;
    }
    return null;
  }

  static void _checkRanges({
    required Duration start,
    required Duration end,
    required Duration endFrom,
    required Duration endTo,
    Duration? startFrom,
    Duration? startTo,
    required bool startsInSameVideo,
  }) {
    if (start < Duration.zero) {
      throw ArgumentError.value(start, 'start', 'must not be negative');
    }
    if (end <= Duration.zero || (startsInSameVideo && end <= start)) {
      throw ArgumentError.value(end, 'end', 'must be after the start');
    }
    if (endTo < endFrom) {
      throw ArgumentError.value(endTo, 'endTo', 'must not be before endFrom');
    }
    if ((startFrom == null) != (startTo == null)) {
      throw ArgumentError('startFrom and startTo go together');
    }
    if (startFrom != null && startTo! < startFrom) {
      throw ArgumentError.value(
        startTo,
        'startTo',
        'must not be before startFrom',
      );
    }
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  static Duration _max(Duration a, Duration b) => a > b ? a : b;

  static Duration _atLeastZero(Duration d) =>
      d < Duration.zero ? Duration.zero : d;
}

class _Frame {
  _Frame(this.time, this.pixels);

  final Duration time;
  final Uint8List pixels;
}

/// One running [VideoLoopPointFinder.findLoopPoint] call.
class _Search {
  /// Whether the call was asked to stop.
  bool canceled = false;

  /// The task id of the frame stream the call reads from.
  String? stream;

  /// Stops the call: it cancels the frame stream running now and starts no
  /// other.
  Future<void> cancel() async {
    canceled = true;
    final stream = this.stream;
    if (stream == null) return;
    try {
      await ProVideoEditor.instance.cancel(stream);
    } on PlatformException {
      // Between the head and the tail no decoder runs; the call stops
      // before it reads the tail.
    }
  }
}
