import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import '/core/constants/example_constants.dart';
import '../../shared/utils/bytes_formatter.dart';

/// A sample page demonstrating how to extract and display video
/// information using Flutter widgets. This widget is stateful,
/// allowing dynamic updates based on video data interactions.
class VideoMetadataExamplePage extends StatefulWidget {
  /// Creates a [VideoMetadataExamplePage] widget.
  ///
  /// This constructor optionally takes a key to uniquely identify
  /// the widget in the widget tree.
  const VideoMetadataExamplePage({super.key});

  @override
  State<VideoMetadataExamplePage> createState() =>
      _VideoMetadataExamplePageState();
}

class _VideoMetadataExamplePageState extends State<VideoMetadataExamplePage> {
  VideoMetadata? _videoMetadata;
  VideoMetadata? _audioMetadata;
  final _numberFormatter = NumberFormat();

  Future<void> _setVideoMetadata() async {
    _videoMetadata = await ProVideoEditor.instance.getMetadata(
      EditorVideo.asset(kVideoEditorExampleH264Path),
      checkStreamingOptimization: true, // Enable streaming optimization check
    );
    setState(() {});
  }

  Future<void> _setAudioMetadata() async {
    // `getMetadata` works with any media file, including audio-only tracks.
    // For audio sources the video-specific fields (resolution, rotation,
    // frame rate, ...) stay empty while duration, bitrate and the descriptive
    // tags (title, artist, album, ...) are populated.
    _audioMetadata = await ProVideoEditor.instance.getMetadata(
      EditorVideo.asset(kVideoEditorExampleAudio1Path),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Metadata')),
      body: ListView(
        children: [
          _buildSectionHeader('Video'),
          ListTile(
            onTap: _setVideoMetadata,
            leading: const Icon(Icons.movie_outlined),
            title: const Text('Read video metadata'),
          ),
          if (_videoMetadata != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: _buildVideoTable(_videoMetadata!),
            ),
          const Divider(height: 32),
          _buildSectionHeader('Audio'),
          ListTile(
            onTap: _setAudioMetadata,
            leading: const Icon(Icons.audiotrack_outlined),
            title: const Text('Read audio metadata'),
          ),
          if (_audioMetadata != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: _buildAudioTable(_audioMetadata!),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _buildVideoTable(VideoMetadata meta) {
    return _buildTable([
      _buildMetadataRow('FileSize:', formatBytes(meta.fileSize)),
      _buildMetadataRow('Format:', meta.extension),
      _buildMetadataRow('Resolution:', meta.resolution.toString()),
      _buildMetadataRow('Rotation:', '${meta.rotation}°'),
      _buildMetadataRow('Duration:', '${meta.duration.inSeconds}s'),
      _buildMetadataRow(
        'Audio Duration:',
        meta.audioDuration != null
            ? '${meta.audioDuration!.inSeconds}s'
            : 'No audio track',
      ),
      _buildMetadataRow('Bitrate:', _numberFormatter.format(meta.bitrate)),
      _buildMetadataRow('Date:', meta.date.toString()),
      _buildMetadataRow('Title:', meta.title),
      _buildMetadataRow('Artist:', meta.artist),
      _buildMetadataRow('Author:', meta.author),
      _buildMetadataRow('Album:', meta.album),
      _buildMetadataRow('AlbumArtist:', meta.albumArtist),
      _buildMetadataRow(
        'GPS:',
        meta.gpsCoordinates != null
            ? '${meta.gpsCoordinates!.latitude}, '
                  '${meta.gpsCoordinates!.longitude}'
            : 'Not available',
      ),
      _buildMetadataRow(
        'Frame Rate:',
        meta.frameRate != null
            ? '${meta.frameRate!.toStringAsFixed(2)} fps'
            : 'N/A',
      ),
      _buildMetadataRow('Camera Make:', meta.cameraMake),
      _buildMetadataRow('Camera Model:', meta.cameraModel),
      _buildMetadataRow(
        'Optimized for Streaming:',
        meta.isOptimizedForStreaming == null
            ? 'N/A (non-MP4/MOV)'
            : meta.isOptimizedForStreaming!
            ? '✅ Yes (moov before mdat)'
            : '❌ No (mdat before moov)',
      ),
    ]);
  }

  Widget _buildAudioTable(VideoMetadata meta) {
    return _buildTable([
      _buildMetadataRow('FileSize:', formatBytes(meta.fileSize)),
      _buildMetadataRow('Format:', meta.extension),
      _buildMetadataRow('Duration:', '${meta.duration.inSeconds}s'),
      _buildMetadataRow(
        'Audio Duration:',
        meta.audioDuration != null
            ? '${meta.audioDuration!.inSeconds}s'
            : 'No audio track',
      ),
      _buildMetadataRow('Bitrate:', _numberFormatter.format(meta.bitrate)),
      _buildMetadataRow('Date:', meta.date.toString()),
      _buildMetadataRow('Title:', meta.title),
      _buildMetadataRow('Artist:', meta.artist),
      _buildMetadataRow('Author:', meta.author),
      _buildMetadataRow('Album:', meta.album),
      _buildMetadataRow('AlbumArtist:', meta.albumArtist),
    ]);
  }

  Widget _buildTable(List<TableRow> rows) {
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: rows,
    );
  }

  TableRow _buildMetadataRow(String label, String value) {
    return TableRow(
      children: [
        Padding(padding: const EdgeInsets.only(right: 10), child: Text(label)),
        Text(value.isEmpty ? '-' : value),
      ],
    );
  }
}
