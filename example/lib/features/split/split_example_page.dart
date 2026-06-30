import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import '/core/constants/example_constants.dart';

/// A sample page demonstrating the frame-accurate [ProVideoEditor.splitVideo]
/// API: it cuts the demo video in half and shows the two resulting files.
class SplitExamplePage extends StatefulWidget {
  /// Creates a [SplitExamplePage] widget.
  const SplitExamplePage({super.key});

  @override
  State<SplitExamplePage> createState() => _SplitExamplePageState();
}

class _SplitExamplePageState extends State<SplitExamplePage> {
  final _pve = ProVideoEditor.instance;

  bool _isSplitting = false;
  double _progress = 0;
  String? _error;
  _SplitResult? _result;
  StreamSubscription<ProgressModel>? _progressSub;

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _split() async {
    setState(() {
      _isSplitting = true;
      _progress = 0;
      _error = null;
      _result = null;
    });

    final source = EditorVideo.asset(kVideoEditorExampleH264Path);

    try {
      final meta = await _pve.getMetadata(source);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;

      final model = SplitVideoModel(
        video: source,
        // Cut exactly in the middle.
        splitPosition: meta.duration ~/ 2,
        startOutputPath: '${dir.path}/split_${stamp}_start.mp4',
        endOutputPath: '${dir.path}/split_${stamp}_end.mp4',
      );

      await _progressSub?.cancel();
      _progressSub = model.progressStream.listen((p) {
        if (mounted) setState(() => _progress = p.progress);
      });

      final paths = await _pve.splitVideo(model);

      // Read back both halves to confirm the cut.
      final startMeta = await _pve.getMetadata(EditorVideo.file(paths[0]));
      final endMeta = await _pve.getMetadata(EditorVideo.file(paths[1]));

      if (!mounted) return;
      setState(() {
        _result = _SplitResult(
          sourceDuration: meta.duration,
          startPath: paths[0],
          startDuration: startMeta.duration,
          endPath: paths[1],
          endDuration: endMeta.duration,
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
      if (mounted) setState(() => _isSplitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Split')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Frame-accurate split of the demo video at its midpoint into two '
            'separate files.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isSplitting ? null : _split,
            icon: const Icon(Icons.content_cut),
            label: const Text('Split demo video in half'),
          ),
          if (_isSplitting) ...[
            const SizedBox(height: 24),
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            Text('${(_progress * 100).toStringAsFixed(0)}%'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 24),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_result != null) ...[
            const Divider(height: 32),
            Text('Source', style: Theme.of(context).textTheme.titleMedium),
            Text('Duration: ${_fmt(_result!.sourceDuration)}'),
            const SizedBox(height: 16),
            Text('Start clip', style: Theme.of(context).textTheme.titleMedium),
            Text('Duration: ${_fmt(_result!.startDuration)}'),
            Text(_result!.startPath, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 16),
            Text('End clip', style: Theme.of(context).textTheme.titleMedium),
            Text('Duration: ${_fmt(_result!.endDuration)}'),
            Text(_result!.endPath, style: const TextStyle(fontSize: 11)),
          ],
        ],
      ),
    );
  }

  String _fmt(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
}

class _SplitResult {
  _SplitResult({
    required this.sourceDuration,
    required this.startPath,
    required this.startDuration,
    required this.endPath,
    required this.endDuration,
  });

  final Duration sourceDuration;
  final String startPath;
  final Duration startDuration;
  final String endPath;
  final Duration endDuration;
}
