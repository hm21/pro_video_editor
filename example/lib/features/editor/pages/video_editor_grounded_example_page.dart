import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/designs/grounded/grounded_design.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/core/platform/io/io_helper.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_player/video_player.dart';

import '/core/constants/example_constants.dart';
import '/features/editor/widgets/video_initializing_widget.dart';
import '../widgets/demo_build_stickers.dart';
import '../widgets/preview_video.dart';
import '../widgets/video_progress_alert.dart';

/// A sample page demonstrating how to use the video-editor.
class VideoEditorGroundedExamplePage extends StatefulWidget {
  /// Creates a [VideoEditorGroundedExamplePage] widget.
  const VideoEditorGroundedExamplePage({super.key});

  @override
  State<VideoEditorGroundedExamplePage> createState() =>
      _VideoEditorGroundedExamplePageState();
}

class _VideoEditorGroundedExamplePageState
    extends State<VideoEditorGroundedExamplePage> {
  final _mainEditorBarKey = GlobalKey<GroundedMainBarState>();
  final bool _useMaterialDesign =
      platformDesignMode == ImageEditorDesignMode.material;

  /// The target format for the exported video.
  final _outputFormat = VideoOutputFormat.mp4;

  /// Video editor configuration settings.
  final VideoEditorConfigs _videoConfigs = const VideoEditorConfigs(
    initialMuted: true,
    initialPlay: false,
    isAudioSupported: true,
    minTrimDuration: Duration(seconds: 7),
    enablePlayButton: true,
  );

  /// Indicates whether a seek operation is in progress.
  bool _isSeeking = false;

  /// Stores the currently selected trim duration span.
  TrimDurationSpan? _durationSpan;

  /// Temporarily stores a pending trim duration span.
  TrimDurationSpan? _tempDurationSpan;

  /// Controls video playback and trimming functionalities.
  ProVideoController? _proVideoController;

  /// Stores generated thumbnails for the trimmer bar and filter background.
  List<ImageProvider>? _thumbnails;

  /// Holds information about the selected video.
  ///
  /// This will be populated via [_setMetadata].
  late VideoMetadata _videoMetadata;

  /// Number of thumbnails to generate across the video timeline.
  final int _thumbnailCount = 7;

  /// The video currently loaded in the editor.
  final _video = EditorVideo.asset(kVideoEditorExampleAssetPath);

  String? _outputPath;

  /// The duration it took to generate the exported video.
  Duration _videoGenerationTime = Duration.zero;
  late VideoPlayerController _videoController;

  final _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  @override
  void dispose() {
    _videoController.dispose();
    super.dispose();
  }

  /// Loads and sets [_videoMetadata] for the given [_video].
  Future<void> _setMetadata() async {
    _videoMetadata = await ProVideoEditor.instance.getMetadata(_video);
  }

  /// Generates thumbnails for the given [_video].
  void _generateThumbnails() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      var imageWidth = MediaQuery.sizeOf(context).width /
          _thumbnailCount *
          MediaQuery.devicePixelRatioOf(context);

      List<Uint8List> thumbnailList = [];

      /// On android `getKeyFrames` is a way faster than `getThumbnails` but
      /// the timestamps are more "random". If you want the best results i
      /// recommend you to use only `getThumbnails`.
      if (!kIsWeb && Platform.isAndroid) {
        thumbnailList = await ProVideoEditor.instance.getKeyFrames(
          KeyFramesConfigs(
            video: _video,
            outputSize: Size.square(imageWidth),
            boxFit: ThumbnailBoxFit.cover,
            maxOutputFrames: _thumbnailCount,
            outputFormat: ThumbnailFormat.jpeg,
          ),
        );
      } else {
        final duration = _videoMetadata.duration;
        final segmentDuration = duration.inMilliseconds / _thumbnailCount;

        thumbnailList = await ProVideoEditor.instance.getThumbnails(
          ThumbnailConfigs(
            video: _video,
            outputSize: Size.square(imageWidth),
            boxFit: ThumbnailBoxFit.cover,
            timestamps: List.generate(_thumbnailCount, (i) {
              final midpointMs = (i + 0.5) * segmentDuration;
              return Duration(milliseconds: midpointMs.round());
            }),
            outputFormat: ThumbnailFormat.jpeg,
          ),
        );
      }

      List<ImageProvider> temporaryThumbnails =
          thumbnailList.map(MemoryImage.new).toList();

      /// Optional precache every thumbnail
      var cacheList =
          temporaryThumbnails.map((item) => precacheImage(item, context));
      await Future.wait(cacheList);
      _thumbnails = temporaryThumbnails;

      if (_proVideoController != null) {
        _proVideoController!.thumbnails = _thumbnails;
      }
    });
  }

  void _initializePlayer() async {
    await _setMetadata();
    _generateThumbnails();

    _videoController =
        VideoPlayerController.asset(kVideoEditorExampleAssetPath);

    await Future.wait([
      _videoController.initialize(),
      _videoController.setLooping(false),
      _videoController.setVolume(_videoConfigs.initialMuted ? 0 : 100),
      _videoConfigs.initialPlay
          ? _videoController.play()
          : _videoController.pause(),
    ]);
    if (!mounted) return;

    _proVideoController = ProVideoController(
      videoPlayer: _buildVideoPlayer(),
      initialResolution: _videoMetadata.resolution,
      videoDuration: _videoMetadata.duration,
      fileSize: _videoMetadata.fileSize,
      thumbnails: _thumbnails,
    );

    _videoController.addListener(_onDurationChange);

    setState(() {});
  }

  void _onDurationChange() {
    var totalVideoDuration = _videoMetadata.duration;
    var duration = _videoController.value.position;
    _proVideoController!.setPlayTime(duration);

    if (_durationSpan != null && duration >= _durationSpan!.end) {
      _seekToPosition(_durationSpan!);
    } else if (duration >= totalVideoDuration) {
      _seekToPosition(
        TrimDurationSpan(start: Duration.zero, end: totalVideoDuration),
      );
    }
  }

  Future<void> _seekToPosition(TrimDurationSpan span) async {
    _durationSpan = span;

    if (_isSeeking) {
      _tempDurationSpan = span; // Store the latest seek request
      return;
    }
    _isSeeking = true;

    _proVideoController!.pause();
    _proVideoController!.setPlayTime(_durationSpan!.start);

    await _videoController.pause();
    await _videoController.seekTo(span.start);

    _isSeeking = false;

    // Check if there's a pending seek request
    if (_tempDurationSpan != null) {
      TrimDurationSpan nextSeek = _tempDurationSpan!;
      _tempDurationSpan = null; // Clear the pending seek
      await _seekToPosition(nextSeek); // Process the latest request
    }
  }

  /// Generates the final video based on the given [parameters].
  ///
  /// Applies blur, color filters, cropping, rotation, flipping, and trimming
  /// before exporting using FFmpeg. Measures and stores the generation time.
  Future<void> generateVideo(CompleteParameters parameters) async {
    final stopwatch = Stopwatch()..start();

    unawaited(_videoController.pause());

    var exportModel = RenderVideoModel(
      id: _taskId,
      video: _video,
      outputFormat: _outputFormat,
      enableAudio: _proVideoController?.isAudioEnabled ?? true,
      imageBytes: parameters.layers.isNotEmpty ? parameters.image : null,
      blur: parameters.blur,
      colorMatrixList: parameters.colorFilters,
      startTime: parameters.startTime,
      endTime: parameters.endTime,
      transform: parameters.isTransformed
          ? ExportTransform(
              width: parameters.cropWidth,
              height: parameters.cropHeight,
              rotateTurns: parameters.rotateTurns,
              x: parameters.cropX,
              y: parameters.cropY,
              flipX: parameters.flipX,
              flipY: parameters.flipY,
            )
          : null,
      // bitrate: _videoMetadata.bitrate,
    );

    final directory = await getTemporaryDirectory();
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      _outputPath = await ProVideoEditor.instance.renderVideoToFile(
        '${directory.path}/my_video_$now.mp4',
        exportModel,
      );
    } on RenderCanceledException {
      stopwatch.stop();
      _outputPath = null;
      _videoGenerationTime = Duration.zero;
      return;
    }
    _videoGenerationTime = stopwatch.elapsed;
  }

  /// Closes the video editor and opens a preview screen if a video was
  /// exported.
  ///
  /// If [_outputPath] is available, it navigates to [PreviewVideo].
  /// Afterwards, it pops the current editor page.
  void onCloseEditor(EditorMode editorMode) async {
    if (editorMode != EditorMode.main) return Navigator.pop(context);
    if (_outputPath != null) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PreviewVideo(
            filePath: _outputPath!,
            generationTime: _videoGenerationTime,
          ),
        ),
      );
      _outputPath = null;
    } else {
      return Navigator.pop(context);
    }
  }

  /// Calculates the number of columns for the EmojiPicker.
  int _calculateEmojiColumns(BoxConstraints constraints) =>
      max(1, (_useMaterialDesign ? 6 : 10) / 400 * constraints.maxWidth - 1)
          .floor();

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: _proVideoController == null
          ? const VideoInitializingWidget()
          : _buildEditor(),
    );
  }

  Widget _buildEditor() {
    return LayoutBuilder(builder: (context, constraints) {
      return ProImageEditor.video(
        _proVideoController!,
        callbacks: ProImageEditorCallbacks(
          onCompleteWithParameters: generateVideo,
          onCloseEditor: onCloseEditor,
          videoEditorCallbacks: VideoEditorCallbacks(
            onPause: _videoController.pause,
            onPlay: _videoController.play,
            onMuteToggle: (isMuted) {
              _videoController.setVolume(isMuted ? 0 : 100);
            },
            onTrimSpanUpdate: (durationSpan) {
              if (_videoController.value.isPlaying) {
                _proVideoController!.pause();
              }
            },
            onTrimSpanEnd: _seekToPosition,
          ),
          mainEditorCallbacks: MainEditorCallbacks(
            onStartCloseSubEditor: (value) {
              /// Start the reversed animation for the bottombar
              _mainEditorBarKey.currentState?.setState(() {});
            },
          ),
          stickerEditorCallbacks: StickerEditorCallbacks(
            onSearchChanged: (value) {
              /// Filter your stickers
              debugPrint(value);
            },
          ),
        ),
        configs: ProImageEditorConfigs(
          dialogConfigs: DialogConfigs(
            widgets: DialogWidgets(
              loadingDialog: (message, configs) => VideoProgressAlert(
                taskId: _taskId,
              ),
            ),
          ),
          videoEditor: _videoConfigs.copyWith(
            playTimeSmoothingDuration: const Duration(milliseconds: 600),
          ),
          designMode: platformDesignMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue.shade800,
              brightness: Brightness.dark,
            ),
          ),
          layerInteraction: const LayerInteractionConfigs(
            hideToolbarOnInteraction: false,
          ),
          mainEditor: MainEditorConfigs(
            widgets: MainEditorWidgets(
              removeLayerArea: (
                removeAreaKey,
                editor,
                rebuildStream,
                isLayerBeingTransformed,
              ) =>
                  VideoEditorRemoveArea(
                removeAreaKey: removeAreaKey,
                editor: editor,
                rebuildStream: rebuildStream,
                isLayerBeingTransformed: isLayerBeingTransformed,
              ),
              appBar: (editor, rebuildStream) => null,
              bottomBar: (editor, rebuildStream, key) => ReactiveWidget(
                key: key,
                builder: (context) {
                  return GroundedMainBar(
                    key: _mainEditorBarKey,
                    editor: editor,
                    configs: editor.configs,
                    callbacks: editor.callbacks,
                  );
                },
                stream: rebuildStream,
              ),
            ),
            style: const MainEditorStyle(
              background: Color(0xFF000000),
              bottomBarBackground: Color(0xFF161616),
            ),
          ),
          paintEditor: PaintEditorConfigs(
            tools: [
              PaintMode.freeStyle,
              PaintMode.arrow,
              PaintMode.line,
              PaintMode.rect,
              PaintMode.circle,
              PaintMode.dashLine,
              PaintMode.polygon,
              // Blur and pixelate are not supported.
              // PaintMode.pixelate,
              // PaintMode.blur,
              PaintMode.eraser,
            ],
            style: const PaintEditorStyle(
              background: Color(0xFF000000),
              bottomBarBackground: Color(0xFF161616),
              initialStrokeWidth: 5,
            ),
            widgets: PaintEditorWidgets(
              appBar: (paintEditor, rebuildStream) => null,
              colorPicker:
                  (paintEditor, rebuildStream, currentColor, setColor) => null,
              bottomBar: (editorState, rebuildStream) {
                return ReactiveWidget(
                  builder: (context) {
                    return GroundedPaintBar(
                        configs: editorState.configs,
                        callbacks: editorState.callbacks,
                        editor: editorState,
                        i18nColor: 'Color',
                        showColorPicker: (currentColor) {
                          Color? newColor;
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              content: SingleChildScrollView(
                                child: ColorPicker(
                                  pickerColor: currentColor,
                                  onColorChanged: (color) {
                                    newColor = color;
                                  },
                                ),
                              ),
                              actions: <Widget>[
                                ElevatedButton(
                                  child: const Text('Got it'),
                                  onPressed: () {
                                    if (newColor != null) {
                                      setState(() =>
                                          editorState.setColor(newColor!));
                                    }
                                    Navigator.of(context).pop();
                                  },
                                ),
                              ],
                            ),
                          );
                        });
                  },
                  stream: rebuildStream,
                );
              },
            ),
          ),
          textEditor: TextEditorConfigs(
            customTextStyles: [
              GoogleFonts.roboto(),
              GoogleFonts.averiaLibre(),
              GoogleFonts.lato(),
              GoogleFonts.comicNeue(),
              GoogleFonts.actor(),
              GoogleFonts.odorMeanChey(),
              GoogleFonts.nabla(),
            ],
            style: TextEditorStyle(
              textFieldMargin: const EdgeInsets.only(top: kToolbarHeight),
              bottomBarBackground: const Color(0xFF161616),
              bottomBarMainAxisAlignment: !_useMaterialDesign
                  ? MainAxisAlignment.spaceEvenly
                  : MainAxisAlignment.start,
            ),
            widgets: TextEditorWidgets(
              appBar: (textEditor, rebuildStream) => null,
              colorPicker:
                  (textEditor, rebuildStream, currentColor, setColor) => null,
              bottomBar: (editorState, rebuildStream) {
                return ReactiveWidget(
                  builder: (context) {
                    return GroundedTextBar(
                        configs: editorState.configs,
                        callbacks: editorState.callbacks,
                        editor: editorState,
                        i18nColor: 'Color',
                        showColorPicker: (currentColor) {
                          Color? newColor;
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              content: SingleChildScrollView(
                                child: ColorPicker(
                                  pickerColor: currentColor,
                                  onColorChanged: (color) {
                                    newColor = color;
                                  },
                                ),
                              ),
                              actions: <Widget>[
                                ElevatedButton(
                                  child: const Text('Got it'),
                                  onPressed: () {
                                    if (newColor != null) {
                                      setState(() =>
                                          editorState.primaryColor = newColor!);
                                    }
                                    Navigator.of(context).pop();
                                  },
                                ),
                              ],
                            ),
                          );
                        });
                  },
                  stream: rebuildStream,
                );
              },
              bodyItems: (editorState, rebuildStream) => [
                ReactiveWidget(
                  stream: rebuildStream,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.only(top: kToolbarHeight),
                    child: GroundedTextSizeSlider(textEditor: editorState),
                  ),
                ),
              ],
            ),
          ),
          cropRotateEditor: CropRotateEditorConfigs(
            style: const CropRotateEditorStyle(
              cropCornerColor: Color(0xFFFFFFFF),
              cropCornerLength: 36,
              cropCornerThickness: 4,
              background: Color(0xFF000000),
              bottomBarBackground: Color(0xFF161616),
              helperLineColor: Color(0x25FFFFFF),
            ),
            widgets: CropRotateEditorWidgets(
              appBar: (cropRotateEditor, rebuildStream) => null,
              bottomBar: (cropRotateEditor, rebuildStream) => ReactiveWidget(
                stream: rebuildStream,
                builder: (_) => GroundedCropRotateBar(
                  configs: cropRotateEditor.configs,
                  callbacks: cropRotateEditor.callbacks,
                  editor: cropRotateEditor,
                  selectedRatioColor: kImageEditorPrimaryColor,
                ),
              ),
            ),
          ),
          filterEditor: FilterEditorConfigs(
            fadeInUpDuration: kGroundedFadeInDuration,
            fadeInUpStaggerDelayDuration: kGroundedFadeInStaggerDelay,
            style: const FilterEditorStyle(
              filterListSpacing: 7,
              filterListMargin: EdgeInsets.fromLTRB(8, 0, 8, 8),
              background: Color(0xFF000000),
            ),
            widgets: FilterEditorWidgets(
              slider:
                  (editorState, rebuildStream, value, onChanged, onChangeEnd) =>
                      ReactiveWidget(
                stream: rebuildStream,
                builder: (_) => Slider(
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                  value: value,
                  activeColor: Colors.blue.shade200,
                ),
              ),
              appBar: (editorState, rebuildStream) => null,
              bottomBar: (editorState, rebuildStream) {
                return ReactiveWidget(
                  builder: (context) {
                    return GroundedFilterBar(
                      configs: editorState.configs,
                      callbacks: editorState.callbacks,
                      editor: editorState,
                      image: _buildVideoPlayer(),
                    );
                  },
                  stream: rebuildStream,
                );
              },
            ),
          ),
          tuneEditor: TuneEditorConfigs(
            style: const TuneEditorStyle(
              background: Color(0xFF000000),
              bottomBarBackground: Color(0xFF161616),
            ),
            widgets: TuneEditorWidgets(
              appBar: (editor, rebuildStream) => null,
              bottomBar: (editorState, rebuildStream) {
                return ReactiveWidget(
                  builder: (context) {
                    return GroundedTuneBar(
                      configs: editorState.configs,
                      callbacks: editorState.callbacks,
                      editor: editorState,
                    );
                  },
                  stream: rebuildStream,
                );
              },
            ),
          ),
          blurEditor: BlurEditorConfigs(
            style: const BlurEditorStyle(
              background: Color(0xFF000000),
            ),
            widgets: BlurEditorWidgets(
              appBar: (blurEditor, rebuildStream) => null,
              bottomBar: (editorState, rebuildStream) {
                return ReactiveWidget(
                  builder: (context) {
                    return GroundedBlurBar(
                      configs: editorState.configs,
                      callbacks: editorState.callbacks,
                      editor: editorState,
                    );
                  },
                  stream: rebuildStream,
                );
              },
            ),
          ),
          emojiEditor: EmojiEditorConfigs(
            checkPlatformCompatibility: !kIsWeb,
            style: EmojiEditorStyle(
              backgroundColor: Colors.transparent,
              textStyle: DefaultEmojiTextStyle.copyWith(
                fontFamily:
                    !kIsWeb ? null : GoogleFonts.notoColorEmoji().fontFamily,
                fontSize: _useMaterialDesign ? 48 : 30,
              ),
              emojiViewConfig: EmojiViewConfig(
                gridPadding: EdgeInsets.zero,
                horizontalSpacing: 0,
                verticalSpacing: 0,
                recentsLimit: 40,
                backgroundColor: Colors.transparent,
                buttonMode: !_useMaterialDesign
                    ? ButtonMode.CUPERTINO
                    : ButtonMode.MATERIAL,
                loadingIndicator:
                    const Center(child: CircularProgressIndicator()),
                columns: _calculateEmojiColumns(constraints),
                emojiSizeMax: !_useMaterialDesign ? 32 : 64,
                replaceEmojiOnLimitExceed: false,
              ),
              bottomActionBarConfig:
                  const BottomActionBarConfig(enabled: false),
            ),
          ),
          i18n: const I18n(
            paintEditor: I18nPaintEditor(
              changeOpacity: 'Opacity',
              lineWidth: 'Thickness',
            ),
            textEditor: I18nTextEditor(
              backgroundMode: 'Mode',
              textAlign: 'Align',
            ),
          ),
          stickerEditor: StickerEditorConfigs(
            builder: (setLayer, scrollController) => DemoBuildStickers(
                categoryColor: const Color(0xFF161616),
                setLayer: setLayer,
                scrollController: scrollController),
          ),
        ),
      );
    });
  }

  Widget _buildVideoPlayer() {
    return Center(
      child: AspectRatio(
        aspectRatio: _videoController.value.size.aspectRatio,
        child: VideoPlayer(
          _videoController,
        ),
      ),
    );
  }
}
