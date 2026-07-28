// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// Removes a solid-colored background (a "green screen") from the video.
///
/// Pixels whose hue is close to [color] are made transparent, with a soft edge
/// so the matte does not alias, and the key's color cast is pulled back out of
/// the pixels that remain ([spill]).
///
/// ## The algorithm
///
/// Both platforms evaluate the exact same formula, so a key tuned on one
/// renders the same on the other. Every value is gamma-encoded RGB in `0..1`:
///
/// ```text
/// Y  =  0.299·r + 0.587·g + 0.114·b
/// Cb = -0.168736·r - 0.331264·g + 0.5·b
/// Cr =  0.5·r - 0.418688·g - 0.081312·b
///
/// d     = distance((Cb, Cr), (Cb_key, Cr_key))
/// alpha = smoothstep(similarity, similarity + smoothness, d)
/// ```
///
/// The distance is measured in the **Cb/Cr chroma plane**, which is a position,
/// not a pure hue: Cb and Cr scale with brightness, so a dimly lit patch of the
/// screen sits closer to neutral and therefore further from the key point. The
/// default [similarity] covers roughly 40%–100% of the screen's reference
/// brightness; a badly lit screen needs a wider one. This is the same behaviour
/// as FFmpeg's `chromakey` and OBS.
///
/// ## What the keyed area becomes
///
/// - [backgroundImage] — the image fills it (stretched to the frame).
/// - [backgroundColor] — that color fills it.
/// - neither — the area is **transparent**, so a lower [VideoLayer] of a
///   [VideoComposition] shows through. This is how you put a video behind a
///   green screen.
///
/// **Important:** H.264 and HEVC carry no alpha channel. In the single-track
/// [VideoRenderData.videoSegments] path there is no layer underneath, so a key
/// without a background is flattened to opaque **black**. Set a background, or
/// use [VideoRenderData.composition] and place the keyed clip on a layer above
/// another one.
///
/// ## Where it can be set
///
/// On [VideoRenderData], [VideoLayer] and [VideoSegment]. The most specific one
/// wins for a given clip — `segment → layer → global` — they are not merged.
///
/// ## Limits
///
/// - No time ranges (unlike [ColorFilter]). Split the clip into two
///   [VideoSegment]s when the key has to change mid-clip.
/// - Ignored inside an overlap [ClipTransition] (dissolve/slide/push/wipe) when
///   the two clips at that boundary do not carry the same key — the blend is
///   pre-rendered from the raw sources and is emitted unkeyed with a warning.
/// - No matte choke/erode and no light wrap.
/// - Combining a transparent key with [VideoRenderData.blur] is not
///   recommended: the blur bleeds color out of the transparent pixels.
/// - Ignored on Web, Windows and Linux, which have no render pipeline.
class ChromaKey {
  /// Creates a [ChromaKey].
  const ChromaKey({
    this.color = const Color(0xFF00B140),
    this.similarity = 0.20,
    this.smoothness = 0.08,
    this.spill = 0.5,
    this.backgroundColor,
    this.backgroundImage,
  }) : assert(
         similarity > 0 && similarity <= 1,
         '[similarity] must be greater than 0 and at most 1',
       ),
       assert(
         smoothness >= 0 && smoothness <= 1,
         '[smoothness] must be between 0 and 1',
       ),
       assert(spill >= 0 && spill <= 1, '[spill] must be between 0 and 1'),
       assert(
         backgroundColor == null || backgroundImage == null,
         'Provide at most one of [backgroundColor] or [backgroundImage]',
       );

  /// A key tuned for a **green** screen.
  ///
  /// Identical to the default constructor; it exists so the counterpart
  /// [ChromaKey.blueScreen] reads as a deliberate choice rather than an
  /// afterthought.
  ///
  /// Prefer [autoDetect] when you have the footage: measuring the screen beats
  /// any constant, because it removes the offset between the paint and what the
  /// camera recorded.
  const ChromaKey.greenScreen({
    this.similarity = 0.20,
    this.smoothness = 0.08,
    this.spill = 0.5,
    this.backgroundColor,
    this.backgroundImage,
  }) : color = const Color(0xFF00B140),
       assert(
         similarity > 0 && similarity <= 1,
         '[similarity] must be greater than 0 and at most 1',
       ),
       assert(
         smoothness >= 0 && smoothness <= 1,
         '[smoothness] must be between 0 and 1',
       ),
       assert(spill >= 0 && spill <= 1, '[spill] must be between 0 and 1'),
       assert(
         backgroundColor == null || backgroundImage == null,
         'Provide at most one of [backgroundColor] or [backgroundImage]',
       );

  /// A key tuned for a **blue** screen.
  ///
  /// Blue is not green with a different hue — the two fail on opposite things.
  /// Blue separates skin better (`0.41`–`0.46` versus green's `0.38`–`0.42`),
  /// which is why it was the film standard, but denim (`0.19`), blue eyes
  /// (`0.20`) and a light blue shirt (`0.21`) all crowd it. So this preset
  /// keys **tighter** than the green one and despills more gently, or a pair of
  /// jeans disappears along with the background.
  ///
  /// The price of the tighter [similarity] is that the screen has to be lit
  /// more evenly: `0.12` reaches down to about 64% of its brightest patch,
  /// where green's `0.20` reaches 40%. If parts of the screen survive, raise
  /// [similarity] — but check the subject's wardrobe when you do.
  const ChromaKey.blueScreen({
    this.similarity = 0.12,
    this.smoothness = 0.08,
    this.spill = 0.25,
    this.backgroundColor,
    this.backgroundImage,
  }) : color = const Color(0xFF0047BB),
       assert(
         similarity > 0 && similarity <= 1,
         '[similarity] must be greater than 0 and at most 1',
       ),
       assert(
         smoothness >= 0 && smoothness <= 1,
         '[smoothness] must be between 0 and 1',
       ),
       assert(spill >= 0 && spill <= 1, '[spill] must be between 0 and 1'),
       assert(
         backgroundColor == null || backgroundImage == null,
         'Provide at most one of [backgroundColor] or [backgroundImage]',
       );

  /// Measures the screen in [video] and returns a key tuned to it.
  ///
  /// This is the most reliable way to build a key, and it is hue-agnostic —
  /// green, blue or anything else, as long as it is saturated.
  ///
  /// A constant [color] is always a compromise. Paint, fabric, lighting and the
  /// camera's color science all shift the recorded screen away from it, and
  /// every bit of that shift has to be absorbed by a wider [similarity] — which
  /// is exactly the margin that protects the subject. Measured on a real studio
  /// clip: against the SMPTE constant the screen sat `0.10`–`0.20` away and
  /// needed `similarity: 0.20`; against its own measured color it sat within
  /// `0.05` and `0.10` was plenty. Same footage, twice the headroom.
  ///
  /// Frames are sampled through the existing thumbnail pipeline, so this costs
  /// one decode and no render.
  ///
  /// **The screen has to reach the frame border**, because that is what lets
  /// the subject be ignored — only a ring around the edge is sampled. A frame
  /// that also shows the studio around the screen will throw a
  /// [ChromaKeyDetectionException]; crop it first, or set the key by hand.
  ///
  /// ```dart
  /// final key = await ChromaKey.autoDetect(
  ///   myClip,
  ///   backgroundColor: Colors.black,
  /// );
  /// ```
  ///
  /// Throws [ChromaKeyDetectionException] when no usable screen is found.
  static Future<ChromaKey> autoDetect(
    EditorVideo video, {
    List<Duration>? timestamps,
    double smoothness = 0.08,
    double spill = 0.5,
    Color? backgroundColor,
    EditorLayerImage? backgroundImage,
  }) async {
    final detection = await detect(video, timestamps: timestamps);
    return ChromaKey(
      color: detection.color,
      similarity: detection.similarity,
      smoothness: smoothness,
      spill: spill,
      backgroundColor: backgroundColor,
      backgroundImage: backgroundImage,
    );
  }

  /// Measures the screen in [video] without building a key.
  ///
  /// Use this when you want to show the measurement to the user — the detected
  /// color, how evenly the screen is lit ([ChromaKeyDetection.spread]) and how
  /// much of the border it covers — before committing to it.
  static Future<ChromaKeyDetection> detect(
    EditorVideo video, {
    List<Duration>? timestamps,
  }) async {
    final editor = ProVideoEditor.instance;
    final metadata = await editor.getMetadata(video);

    // Sample across the clip so a subject that briefly touches an edge cannot
    // decide the result on its own.
    final duration = metadata.duration;
    final at = timestamps ?? [duration * 0.25, duration * 0.5, duration * 0.75];

    // Small, and at the source aspect ratio: `cover` then neither crops nor
    // pads, so the sampled ring really is the frame's own border.
    const sampleHeight = 160.0;
    final aspect = metadata.resolution.aspectRatio;
    final size = Size((sampleHeight * aspect).roundToDouble(), sampleHeight);

    final frames = await editor.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.png,
        timestamps: at,
        outputSize: size,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );

    if (frames.isEmpty) {
      throw const ChromaKeyDetectionException(
        'Could not extract a frame from the video',
      );
    }

    final buffers = <Uint8List>[];
    int? width;
    int? height;
    for (final frame in frames) {
      final codec = await instantiateImageCodec(frame);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData();
      if (data == null) continue;
      width ??= image.width;
      height ??= image.height;
      if (image.width != width || image.height != height) continue;
      buffers.add(data.buffer.asUint8List());
    }

    if (buffers.isEmpty || width == null || height == null) {
      throw const ChromaKeyDetectionException('Could not decode any frame');
    }

    return ChromaKeyDetector.fromFrames(buffers, width: width, height: height);
  }

  /// The screen color to remove.
  ///
  /// **Default**: `0xFF00B140`, the SMPTE "chroma key green" most physical
  /// screens are painted in. Only the hue is used — the brightness of this
  /// color does not matter.
  ///
  /// ## Blue screens
  ///
  /// Any saturated hue works; nothing here is specific to green. A blue screen
  /// (`0xFF0047BB`) keys just as cleanly and is in fact *safer for skin*, which
  /// sits `0.41`–`0.46` from it versus `0.38`–`0.42` from green.
  ///
  /// The trade is what the subject wears. Measured against SMPTE blue:
  ///
  /// | | distance |
  /// |---|---|
  /// | denim / jeans | `0.19` |
  /// | blue eyes | `0.20` |
  /// | light blue shirt | `0.21` |
  ///
  /// All three sit at or below the default [similarity] of `0.20`, which is
  /// tuned for green — so on a blue screen denim and a light blue shirt are
  /// keyed away along with the background. Drop [similarity] to about `0.12`
  /// for blue, and lower [spill] as well when the subject wears blue, or the
  /// despill pulls the blue out of the garment too (denim measured
  /// `(59,91,140)` → `(92,79,98)` at the default `spill`). Skin is unaffected
  /// by despill on a blue screen, since it leans away from that hue.
  ///
  /// A lower [similarity] needs a more evenly lit screen: `0.12` only covers
  /// down to about 65% of the screen's reference brightness.
  ///
  /// Avoid the darker "digital blue" (`0xFF1A46A8`) — its chroma magnitude is
  /// only `0.25` versus `0.33`, so every subject color crowds it, a white shirt
  /// included.
  final Color color;

  /// How far from [color] a pixel may sit and still be removed completely.
  ///
  /// Measured as a distance in the Cb/Cr chroma plane. Some anchors for
  /// calibration, all against the default SMPTE green (whose own chroma
  /// magnitude is `0.33`):
  ///
  /// - skin tones sit `0.38`–`0.42` away, so the default keeps faces safe by a
  ///   wide margin;
  /// - the same screen lit at 40% of its brightest patch sits `0.20` away —
  ///   exactly at the default threshold. A real, evenly lit studio screen
  ///   measured `0.18` in its darkest corners, which is why the default is not
  ///   tighter;
  /// - a green-ish garment (an olive shirt) sits around `0.26`, so that is the
  ///   case where raising this too far starts eating the subject.
  ///
  /// So: raise it when shadowed or unevenly lit parts of the screen survive the
  /// key, and lower it when the subject starts disappearing.
  ///
  /// **Default**: `0.20`
  final double similarity;

  /// The width of the soft ramp just beyond [similarity].
  ///
  /// Pixels between `similarity` and `similarity + smoothness` fade from fully
  /// removed to fully opaque, which is what keeps hair and motion blur from
  /// turning into a jagged cutout.
  ///
  /// `0` asks for a hard edge. Note that Apple evaluates the key through a
  /// 33³ color cube with trilinear interpolation, so a perfectly hard edge is
  /// not reachable there — about one cube cell of ramp always remains, which in
  /// practice just anti-aliases the matte. Values from `0.05` up span several
  /// cells and are smooth on both platforms.
  ///
  /// **Default**: `0.08`
  final double smoothness;

  /// How strongly the key's color cast is removed from the pixels that stay.
  ///
  /// A green screen bounces green light onto everything near it, leaving a tint
  /// along the subject's edges. This pulls the chroma component that points
  /// toward [color] back out, without changing the pixel's brightness.
  ///
  /// - `0.0`: off
  /// - `1.0`: neutralize the key hue completely
  ///
  /// **Default**: `0.5`
  final double spill;

  /// A solid color to put behind the subject.
  ///
  /// Mutually exclusive with [backgroundImage]. When both are `null` the keyed
  /// area is transparent — see the class docs for what that means per path.
  final Color? backgroundColor;

  /// An image to put behind the subject, stretched to fill the frame.
  ///
  /// Mutually exclusive with [backgroundColor].
  final EditorLayerImage? backgroundImage;

  /// Whether the keyed area is left transparent rather than filled.
  bool get isTransparent => backgroundColor == null && backgroundImage == null;

  /// Converts this key to a map for platform channel communication.
  ///
  /// Resolves [backgroundImage] to bytes, so this is asynchronous.
  Future<Map<String, dynamic>> toAsyncMap() async {
    return {
      'keyColor': color.toARGB32(),
      'similarity': similarity,
      'smoothness': smoothness,
      'spill': spill,
      'bgColor': backgroundColor?.toARGB32(),
      'bgImageData': await backgroundImage?.safeByteArray(),
    };
  }

  /// Creates a copy with updated values.
  ChromaKey copyWith({
    Color? color,
    double? similarity,
    double? smoothness,
    double? spill,
    Color? backgroundColor,
    EditorLayerImage? backgroundImage,
  }) {
    return ChromaKey(
      color: color ?? this.color,
      similarity: similarity ?? this.similarity,
      smoothness: smoothness ?? this.smoothness,
      spill: spill ?? this.spill,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundImage: backgroundImage ?? this.backgroundImage,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'color': color.toARGB32(),
      'similarity': similarity,
      'smoothness': smoothness,
      'spill': spill,
      'backgroundColor': backgroundColor?.toARGB32(),
      'backgroundImage': backgroundImage?.toMap(),
    };
  }

  factory ChromaKey.fromMap(Map<String, dynamic> map) {
    return ChromaKey(
      color: Color(safeParseInt(map['color'], fallback: 0xFF00B140)),
      similarity: safeParseDouble(map['similarity'], fallback: 0.20),
      smoothness: safeParseDouble(map['smoothness'], fallback: 0.08),
      spill: safeParseDouble(map['spill'], fallback: 0.5),
      backgroundColor: map['backgroundColor'] != null
          ? Color(safeParseInt(map['backgroundColor']))
          : null,
      backgroundImage: map['backgroundImage'] != null
          ? EditorLayerImage.fromMap(
              map['backgroundImage'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory ChromaKey.fromJson(String source) =>
      ChromaKey.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'ChromaKey(color: $color, '
        'similarity: $similarity, '
        'smoothness: $smoothness, '
        'spill: $spill, '
        'backgroundColor: $backgroundColor, '
        'backgroundImage: $backgroundImage)';
  }

  @override
  bool operator ==(covariant ChromaKey other) {
    if (identical(this, other)) return true;

    return other.color == color &&
        other.similarity == similarity &&
        other.smoothness == smoothness &&
        other.spill == spill &&
        other.backgroundColor == backgroundColor &&
        other.backgroundImage == backgroundImage;
  }

  @override
  int get hashCode {
    return color.hashCode ^
        similarity.hashCode ^
        smoothness.hashCode ^
        spill.hashCode ^
        backgroundColor.hashCode ^
        backgroundImage.hashCode;
  }
}
