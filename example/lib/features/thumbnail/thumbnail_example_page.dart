import 'package:flutter/material.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import '/core/constants/example_constants.dart';

/// A sample page demonstrating video thumbnail generation on the web.
///
/// This widget is intended to showcase how to use the
/// [WebThumbnailGenerator] to extract and display video thumbnails.
class ThumbnailExamplePage extends StatefulWidget {
  /// Creates a [ThumbnailExamplePage].
  const ThumbnailExamplePage({super.key});

  @override
  State<ThumbnailExamplePage> createState() => _ThumbnailExamplePageState();
}

class _ThumbnailExamplePageState extends State<ThumbnailExamplePage> {
  List<MemoryImage> _thumbnails = [];
  List<MemoryImage> _keyFrames = [];

  final int _exampleImageCount = 8;
  final double _imageSize = 50;
  final ThumbnailFormat _thumbnailFormat = ThumbnailFormat.jpeg;
  VideoMetadata? _informations;

  final _thumbnailTaskId = 'ThumbnailTaskId';
  final _keyFramesTaskId = 'KeyFramesTaskId';

  Future<void> _setMetadata() async {
    _informations = await ProVideoEditor.instance.getMetadata(
      EditorVideo.asset(kVideoEditorExampleH264Path),
    );
    setState(() {});
  }

  void _generateThumbnails() async {
    var outputSize = _imageSize * MediaQuery.devicePixelRatioOf(context);

    if (_informations == null) await _setMetadata();

    var raw = await ProVideoEditor.instance.getThumbnails(
      ThumbnailConfigs(
        id: _thumbnailTaskId,
        video: EditorVideo.asset(kVideoEditorExampleH264Path),
        outputFormat: _thumbnailFormat,
        timestamps: List.generate(
          _exampleImageCount,
          (i) => Duration(
            milliseconds:
                (_informations!.duration.inMilliseconds /
                        _exampleImageCount *
                        i)
                    .toInt(),
          ),
        ),
        outputSize: Size(outputSize, outputSize),
        boxFit: ThumbnailBoxFit.cover,
      ),
    );

    _thumbnails = raw.map(MemoryImage.new).toList();
    setState(() {});
  }

  void _generateKeyFrames() async {
    var outputSize = _imageSize * MediaQuery.devicePixelRatioOf(context);

    var raw = await ProVideoEditor.instance.getKeyFrames(
      KeyFramesConfigs(
        id: _keyFramesTaskId,
        video: EditorVideo.asset(kVideoEditorExampleH264Path),
        outputFormat: _thumbnailFormat,
        maxOutputFrames: _exampleImageCount,
        outputSize: Size(outputSize, outputSize),
        boxFit: ThumbnailBoxFit.cover,
      ),
    );

    _keyFrames = raw.map(MemoryImage.new).toList();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thumbnails')),
      body: ListView(
        children: [
          ListTile(
            onTap: _generateThumbnails,
            leading: const Icon(Icons.image_outlined),
            title: const Text('Generate Thumbnails'),
            trailing: _buildProgress(_thumbnailTaskId),
          ),
          _buildThumbnails(_thumbnails),
          ListTile(
            onTap: _generateKeyFrames,
            leading: const Icon(Icons.animation_rounded),
            title: const Text('Generate Keyframes'),
            trailing: _buildProgress(_keyFramesTaskId),
          ),
          _buildThumbnails(_keyFrames),
        ],
      ),
    );
  }

  Widget _buildThumbnails(List<MemoryImage> data) {
    return Wrap(
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: data
          .map(
            (item) => Container(
              width: _imageSize,
              height: _imageSize,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Image(image: item, fit: BoxFit.cover),
            ),
          )
          .toList(),
    );
  }

  Widget _buildProgress(String taskId) {
    return FittedBox(
      child: StreamBuilder<ProgressModel>(
        key: ValueKey(taskId),
        stream: ProVideoEditor.instance.progressStreamById(taskId),
        builder: (context, snapshot) {
          double progress = snapshot.data?.progress ?? 0;

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 300),
            builder: (context, animatedValue, _) {
              return Column(
                children: [
                  CircularProgressIndicator(
                    value: animatedValue,
                    // ignore: deprecated_member_use
                    year2023: false,
                  ),
                  Text('${(animatedValue * 100).toStringAsFixed(1)} / 100'),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
