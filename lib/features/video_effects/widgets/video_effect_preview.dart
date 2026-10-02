import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '/core/models/video/video_effect_frame_model.dart';
import '/core/models/video/video_effect_model.dart';

/// Shows [child] with [effects] applied, the way an export renders them.
///
/// [child] is usually the video player. For every [position] the preview
/// draws the same frame of each effect the native renderer draws at that
/// time, so what the preview shows is what the file will contain.
///
/// The preview needs Impeller: on another backend, or while the shaders are
/// still loading, [child] is shown unchanged. The effects still apply to the
/// export. Check [isSupported] to tell the user.
///
/// A glow is screened over [child] through a [BackdropFilter], blurred with
/// Flutter's own Gaussian, which stays close to the export's blur but not
/// pixel-exact. It glows from whatever is painted within the preview's
/// bounds, so a [child] that leaves some of them transparent lets what lies
/// behind it glow too; give it the video's aspect ratio.
///
/// ```dart
/// VideoEffectPreview(
///   effects: const [VideoEffect.vhs(intensity: 0.6)],
///   position: playbackPosition,
///   child: videoPlayer,
/// )
/// ```
class VideoEffectPreview extends StatefulWidget {
  /// Creates a preview of [effects] over [child].
  const VideoEffectPreview({
    super.key,
    required this.effects,
    required this.position,
    required this.child,
  });

  /// The effects to show, with their time ranges on the same timeline as
  /// [position].
  final List<VideoEffect> effects;

  /// The playhead. Animated effects advance as it moves.
  final ValueListenable<Duration> position;

  /// The widget the effects are applied to.
  final Widget child;

  /// Whether this renderer can show the preview.
  ///
  /// `ImageFilter.shader` is Impeller-only; on Skia, and on Android's Impeller
  /// OpenGLES fallback, it is unavailable and [child] shows unchanged.
  static bool get isSupported => ui.ImageFilter.isShaderFilterSupported;

  /// Loads the preview shaders ahead of the first preview, so the first frames
  /// do not show the video without its effect. Safe to call repeatedly.
  ///
  /// Completes with `false` when the shaders cannot be used here.
  static Future<bool> precache() => _VideoEffectShader.ensureLoaded();

  @override
  State<VideoEffectPreview> createState() => _VideoEffectPreviewState();
}

class _VideoEffectPreviewState extends State<VideoEffectPreview> {
  /// Stands in for the shader filter while it is disabled, so the widget type
  /// in the tree never changes and the video player is never remounted.
  static final ui.ImageFilter _identity = ui.ImageFilter.matrix(
    Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
  );

  VideoEffectFrame _frame = VideoEffectFrame.none;
  ui.FragmentShader? _shader;
  ui.ImageFilter? _filter;

  /// The glow's bright pass, while the frame glows.
  ui.FragmentShader? _glowShader;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_update);
    _update(rebuild: false);
  }

  @override
  void didUpdateWidget(VideoEffectPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_update);
      widget.position.addListener(_update);
    }
    if (oldWidget.position != widget.position ||
        !listEquals(oldWidget.effects, widget.effects)) {
      _update(rebuild: false);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_update);
    _replaceShader(null);
    _replaceGlowShader(null);
    super.dispose();
  }

  /// Whether this state already waits for the shader, so a playing video
  /// does not queue one wait per position update. Stays set after a failed
  /// load, which is not retried.
  bool _awaitingProgram = false;

  /// Resolves the frame at the current position and swaps the shader when it
  /// changed. [rebuild] is false where a build follows anyway.
  void _update({bool rebuild = true}) {
    final frame = VideoEffect.resolve(widget.effects, widget.position.value);
    final hasShader = _shader != null || _glowShader != null;
    if (frame == _frame && hasShader == !frame.isIdentity) return;

    if (frame.isIdentity) {
      _frame = frame;
      if (!hasShader) return;
      _replaceShader(null);
      _replaceGlowShader(null);
      if (rebuild) _markNeedsBuild();
      return;
    }

    final program = _VideoEffectShader.programOrNull;
    final glowProgram = _VideoEffectShader.glowProgramOrNull;
    if (program == null || glowProgram == null) {
      if (_awaitingProgram) return;
      _awaitingProgram = true;
      _VideoEffectShader.ensureLoaded().then((loaded) {
        if (!loaded || !mounted) return;
        _awaitingProgram = false;
        _update();
      });
      return;
    }

    final previous = _frame;
    _frame = frame;
    // A frame that only glows skips the effect shader, which would leave the
    // picture as it is.
    _replaceShader(
      _withoutGlow(frame).isIdentity
          ? null
          : _VideoEffectShader.build(program, frame),
    );
    if (frame.glow <= 0) {
      _replaceGlowShader(null);
    } else if (_glowShader == null ||
        frame.glow != previous.glow ||
        frame.glowThreshold != previous.glowThreshold) {
      _replaceGlowShader(_VideoEffectShader.buildGlow(glowProgram, frame));
    }
    if (rebuild) _markNeedsBuild();
  }

  /// [frame] without its glow, the last three values of its table.
  static VideoEffectFrame _withoutGlow(VideoEffectFrame frame) {
    if (frame.glow <= 0) return frame;
    final values = frame.toList()
      ..fillRange(VideoEffectFrame.stride - 3, VideoEffectFrame.stride, 0);
    return VideoEffectFrame.fromList(values);
  }

  /// Rebuilds, or schedules the rebuild when the position changed while the
  /// tree is being built, as a player driven by another widget's build can.
  void _markNeedsBuild() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// A filter that compares equal is not applied again, so every new frame
  /// gets a new shader rather than new uniforms on the old one. The old shader
  /// is released once the frame that stopped using it has been built.
  void _replaceShader(ui.FragmentShader? shader) {
    final previous = _shader;
    _shader = shader;
    _filter = shader == null ? null : ui.ImageFilter.shader(shader);
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  /// Like [_replaceShader], for the glow's bright pass.
  void _replaceGlowShader(ui.FragmentShader? shader) {
    final previous = _glowShader;
    _glowShader = shader;
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = _filter;
    final glowShader = _glowShader;
    final glowRadius = _frame.glowRadius;
    // The clip bounds the area the glow's backdrop filter reads and draws, so
    // it is only there while the frame glows. Every layer stays in the tree
    // while it is off, so the player is never remounted.
    return ClipRect(
      clipBehavior: glowShader == null ? Clip.none : Clip.hardEdge,
      child: Stack(
        alignment: Alignment.topLeft,
        fit: StackFit.passthrough,
        children: [
          ImageFiltered(
            imageFilter: filter ?? _identity,
            enabled: filter != null,
            child: widget.child,
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => BackdropFilter(
                filterConfig: glowShader == null
                    ? ImageFilterConfig(_identity)
                    : _glowFilter(
                        glowShader,
                        glowRadius * constraints.maxHeight,
                      ),
                enabled: glowShader != null,
                blendMode: BlendMode.screen,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The halo: the bright pass blurred by [sigma] logical pixels. The blur
  /// is bounded to the preview, as the export's blur is to the frame. It
  /// leaves out what lies beyond the edge where the export repeats the edge
  /// pixels, so a thin bright line right at the edge glows less than in the
  /// file.
  static ImageFilterConfig _glowFilter(ui.FragmentShader shader, double sigma) {
    final brightPass = ImageFilterConfig(ui.ImageFilter.shader(shader));
    if (sigma < 0.5) return brightPass;
    return ImageFilterConfig.compose(
      outer: ImageFilterConfig.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.clamp,
        bounded: true,
      ),
      inner: brightPass,
    );
  }
}

/// The compiled preview shaders, `shaders/video_effect.frag` and the glow's
/// `shaders/video_effect_glow.frag`, loaded once per process.
abstract final class _VideoEffectShader {
  static const _assetKey =
      'packages/pro_video_editor/shaders/video_effect.frag';
  static const _glowAssetKey =
      'packages/pro_video_editor/shaders/video_effect_glow.frag';

  static ui.FragmentProgram? _program;
  static ui.FragmentProgram? _glowProgram;
  static Future<bool>? _loading;

  /// Set once a load failed; the assets do not change within a process, so
  /// it is not retried.
  static bool _failed = false;

  static ui.FragmentProgram? get programOrNull => _program;

  static ui.FragmentProgram? get glowProgramOrNull => _glowProgram;

  static Future<bool> ensureLoaded() {
    if (_program != null && _glowProgram != null) {
      return SynchronousFuture(true);
    }
    if (_failed || !VideoEffectPreview.isSupported) {
      return SynchronousFuture(false);
    }
    return _loading ??= _load();
  }

  static Future<bool> _load() async {
    try {
      final programs = await Future.wait([
        ui.FragmentProgram.fromAsset(_assetKey),
        ui.FragmentProgram.fromAsset(_glowAssetKey),
      ]);
      _program = programs[0];
      _glowProgram = programs[1];
      return true;
    } catch (error, stackTrace) {
      _failed = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'pro_video_editor',
          context: ErrorDescription(
            'while loading the video effect preview shaders; the preview '
            'shows the video without its effects',
          ),
        ),
      );
      return false;
    } finally {
      _loading = null;
    }
  }

  /// The glow's bright pass for [frame].
  static ui.FragmentShader buildGlow(
    ui.FragmentProgram program,
    VideoEffectFrame frame,
  ) {
    // Uniforms 0 and 1 are the bound texture's size, which the engine sets.
    return program.fragmentShader()
      ..setFloat(2, frame.glow)
      ..setFloat(3, frame.glowThreshold);
  }

  static ui.FragmentShader build(
    ui.FragmentProgram program,
    VideoEffectFrame frame,
  ) {
    final shader = program.fragmentShader();
    // Uniforms 0 and 1 are the bound texture's size, which the engine sets.
    final values = <double>[
      frame.pixelSize,
      frame.rgbShift,
      frame.scanlines,
      frame.scanlinePeriod,
      frame.noise,
      frame.noiseCellSize,
      frame.noiseOffsetX.toDouble(),
      frame.noiseOffsetY.toDouble(),
      math.min(frame.bands.length, VideoEffectFrame.maxBands).toDouble(),
    ];
    for (var i = 0; i < VideoEffectFrame.maxBands; i++) {
      final band = i < frame.bands.length ? frame.bands[i] : null;
      values.addAll([band?.top ?? 0, band?.bottom ?? 0, band?.shift ?? 0]);
    }
    values.addAll([
      frame.sepia,
      frame.brightness,
      frame.invert,
      frame.flash,
      frame.vignette,
      frame.vignetteRadius,
      frame.zoom,
      frame.offsetX,
      frame.offsetY,
      frame.mirrorX,
      frame.mirrorY,
      frame.tiles.toDouble(),
      frame.waveAmplitude,
      frame.wavePeriod,
      frame.wavePhase,
    ]);
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(2 + i, values[i]);
    }
    return shader;
  }
}
