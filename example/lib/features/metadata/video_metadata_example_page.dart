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
  VideoMetadata? _metadata;
  final _numberFormatter = NumberFormat();

  Future<void> _setMetadata() async {
    _metadata = await ProVideoEditor.instance.getMetadata(
      EditorVideo.asset(kVideoEditorExampleH264Path),
      checkStreamingOptimization: true, // Enable streaming optimization check
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video-Metadata')),
      body: ListView(
        children: [
          ListTile(
            onTap: _setMetadata,
            leading: const Icon(Icons.find_in_page_outlined),
            title: const Text('Read metadata'),
          ),
          if (_metadata != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: _buildTable(),
            ),
        ],
      ),
    );
  }

  Widget _buildTable() {
    var meta = _metadata!;
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
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
      ],
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
