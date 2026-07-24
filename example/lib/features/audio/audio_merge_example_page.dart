import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import '/core/constants/example_constants.dart';

/// A sample page demonstrating [ProVideoEditor.mergeAudioToFile]: it merges
/// several trimmed clip windows (including a sped-up clip and a silent one)
/// into a single, gap-less audio file and shows the returned offset map.
class AudioMergeExamplePage extends StatefulWidget {
  /// Creates an [AudioMergeExamplePage] widget.
  const AudioMergeExamplePage({super.key});

  @override
  State<AudioMergeExamplePage> createState() => _AudioMergeExamplePageState();
}

class _AudioMergeExamplePageState extends State<AudioMergeExamplePage> {
  final _pve = ProVideoEditor.instance;

  /// The clip windows to concatenate, in output order.
  ///
  /// Note the third clip plays at 2× (so it contributes half its window) and
  /// the last one has no audio track — it contributes silence, keeping the
  /// offset map aligned instead of throwing.
  final List<_DemoSegment> _demoSegments = const [
    _DemoSegment(
      label: 'demo.mp4 · 0–3s',
      assetPath: kVideoEditorExampleH264Path,
      start: Duration(seconds: 0),
      end: Duration(seconds: 3),
    ),
    _DemoSegment(
      label: 'demo_world.mp4 · 1–3s',
      assetPath: kVideoEditorExampleAssetWorldPath,
      start: Duration(seconds: 1),
      end: Duration(seconds: 3),
    ),
    _DemoSegment(
      label: 'demo.mp4 · 10–14s @ 2×',
      assetPath: kVideoEditorExampleH264Path,
      start: Duration(seconds: 10),
      end: Duration(seconds: 14),
      speed: 2.0,
    ),
    _DemoSegment(
      label: 'demo_muted.mp4 · 0–2s (no audio → silence)',
      assetPath: 'assets/demo_muted.mp4',
      start: Duration(seconds: 0),
      end: Duration(seconds: 2),
    ),
  ];

  /// When on, the output is 16 kHz mono — the typical speech-to-text preset.
  bool _asrPreset = true;

  bool _isMerging = false;
  double _progress = 0;
  String? _error;
  _MergeOutput? _output;
  StreamSubscription<ProgressModel>? _progressSub;

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _merge() async {
    setState(() {
      _isMerging = true;
      _progress = 0;
      _error = null;
      _output = null;
    });

    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${dir.path}/merged_audio_$stamp.wav';

      final configs = AudioMergeConfigs(
        segments: [
          for (final s in _demoSegments)
            AudioMergeSegment(
              video: EditorVideo.asset(s.assetPath),
              startTime: s.start,
              endTime: s.end,
              speed: s.speed,
            ),
        ],
        format: AudioFormat.wav,
        sampleRate: _asrPreset ? 16000 : null,
        channels: _asrPreset ? 1 : null,
      );

      await _progressSub?.cancel();
      _progressSub = _pve.progressStreamById(configs.id).listen((p) {
        if (mounted) setState(() => _progress = p.progress);
      });

      final result = await _pve.mergeAudioToFile(outputPath, configs);

      final fileSize = await File(result.outputPath).length();

      if (!mounted) return;
      setState(() {
        _output = _MergeOutput(result: result, fileSizeBytes: fileSize);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
      if (mounted) setState(() => _isMerging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Audio-Merge')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Merges the clip windows below into ONE gap-less audio file and '
            'returns a per-segment offset map (start + duration in the '
            'output). One clip is sped up 2× and one has no audio track — it '
            'contributes silence so the map stays aligned.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _demoSegments.length; i++)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 12, child: Text('${i + 1}')),
                    title: Text(_demoSegments[i].label),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _asrPreset,
            onChanged: _isMerging
                ? null
                : (v) => setState(() => _asrPreset = v),
            title: const Text('16 kHz mono (speech-to-text preset)'),
            subtitle: const Text(
              'Off = keep the first clip\'s native rate / channels',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _isMerging ? null : _merge,
            icon: const Icon(Icons.merge),
            label: const Text('Merge audio'),
          ),
          if (_isMerging) ...[
            const SizedBox(height: 24),
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            Text('${(_progress * 100).toStringAsFixed(0)}%'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 24),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_output != null) ...[
            const Divider(height: 32),
            Text('Result', style: theme.textTheme.titleMedium),
            Text('Total duration: ${_fmt(_output!.result.totalDuration)}'),
            Text('File size: ${_output!.fileSizeKb} KB'),
            Text(
              _output!.result.outputPath,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 16),
            Text('Offset map', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _OffsetTable(segments: _output!.result.segments),
          ],
        ],
      ),
    );
  }

  String _fmt(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
}

/// Renders the per-segment offset map as a compact table.
class _OffsetTable extends StatelessWidget {
  const _OffsetTable({required this.segments});

  final List<AudioMergeSegmentOffset> segments;

  String _fmt(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';

  @override
  Widget build(BuildContext context) {
    final headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.primary,
    );
    return Table(
      border: TableBorder.all(
        color: Theme.of(context).dividerColor,
        borderRadius: BorderRadius.circular(6),
      ),
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(2),
        3: FlexColumnWidth(2),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            _cell('#', style: headerStyle),
            _cell('start', style: headerStyle),
            _cell('duration', style: headerStyle),
            _cell('end', style: headerStyle),
          ],
        ),
        for (var i = 0; i < segments.length; i++)
          TableRow(
            children: [
              _cell('${i + 1}'),
              _cell(_fmt(segments[i].outputStart)),
              _cell(_fmt(segments[i].outputDuration)),
              _cell(_fmt(segments[i].outputEnd)),
            ],
          ),
      ],
    );
  }

  Widget _cell(String text, {TextStyle? style}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Text(text, style: style),
  );
}

/// A demo clip window used to build the merge configuration.
class _DemoSegment {
  const _DemoSegment({
    required this.label,
    required this.assetPath,
    required this.start,
    required this.end,
    this.speed = 1.0,
  });

  final String label;
  final String assetPath;
  final Duration start;
  final Duration end;
  final double speed;
}

/// The merge result plus the on-disk file size, for display.
class _MergeOutput {
  _MergeOutput({required this.result, required this.fileSizeBytes});

  final AudioMergeResult result;
  final int fileSizeBytes;

  String get fileSizeKb => (fileSizeBytes / 1024).toStringAsFixed(1);
}
