import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import '/core/constants/example_constants.dart';

/// A sample page demonstrating audio extraction from video files.
///
/// This widget showcases how to use the [ProVideoEditor] plugin to extract
/// audio tracks from video files with various formats and quality settings.
class AudioExtractExamplePage extends StatefulWidget {
  /// Creates an [AudioExtractExamplePage].
  const AudioExtractExamplePage({super.key});

  @override
  State<AudioExtractExamplePage> createState() =>
      _AudioExtractExamplePageState();
}

class _AudioExtractExamplePageState extends State<AudioExtractExamplePage> {
  String? _extractedAudioPath;
  bool _isExtracting = false;
  AudioFormat _selectedFormat = AudioFormat.mp3;
  final String _taskId = 'AudioExtractionTaskId';

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // Audio track check states
  bool? _hasAudioTrack;
  bool? _mutedVideoHasAudio;
  bool _isCheckingAudio = false;

  @override
  void initState() {
    super.initState();
    _setupAudioPlayer();

    // Set default format based on platform
    if (!_isFormatSupported(_selectedFormat)) {
      // Find first supported format
      _selectedFormat = AudioFormat.values.firstWhere(
        _isFormatSupported,
        orElse: () => AudioFormat.m4a, // Fallback to M4A
      );
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void _setupAudioPlayer() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });

    _audioPlayer.onDurationChanged.listen((duration) {
      setState(() {
        _duration = duration;
      });
    });

    _audioPlayer.onPositionChanged.listen((position) {
      setState(() {
        _position = position;
      });
    });
  }

  Future<void> _extractAudio() async {
    setState(() {
      _isExtracting = true;
      _extractedAudioPath = null;
    });

    try {
      // Get output directory
      final directory = await getTemporaryDirectory();
      final outputPath = '${directory.path}/extracted_audio_'
          '${DateTime.now().millisecondsSinceEpoch}.'
          '${_selectedFormat.extension}';

      // Create extraction config
      final config = AudioExtractConfigs(
        video: EditorVideo.asset(kVideoEditorExampleAssetPath),
        format: _selectedFormat,
        // Optional: Add trimming
        // startTime: Duration(seconds: 5),
        // endTime: Duration(seconds: 15),
      );

      // Extract audio
      await ProVideoEditor.instance.extractAudioToFile(
        outputPath,
        config,
      );

      setState(() {
        _extractedAudioPath = outputPath;
        _isExtracting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio extracted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isExtracting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error extracting audio: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _playAudio() async {
    if (_extractedAudioPath == null) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play(DeviceFileSource(_extractedAudioPath!));
    }
  }

  Future<void> _deleteAudio() async {
    if (_extractedAudioPath == null) return;

    await _audioPlayer.stop();

    final file = File(_extractedAudioPath!);
    if (await file.exists()) {
      await file.delete();
    }

    setState(() {
      _extractedAudioPath = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
  }

  Future<void> _checkAudioTrack() async {
    setState(() {
      _isCheckingAudio = true;
      _hasAudioTrack = null;
      _mutedVideoHasAudio = null;
    });

    try {
      // Check if the demo video has audio
      final videoWithAudio = EditorVideo.asset(kVideoEditorExampleAssetPath);
      final hasAudio =
          await ProVideoEditor.instance.hasAudioTrack(videoWithAudio);

      // Check if the muted video has audio
      final mutedVideo = EditorVideo.asset('assets/demo_muted.mp4');
      final mutedHasAudio =
          await ProVideoEditor.instance.hasAudioTrack(mutedVideo);

      setState(() {
        _hasAudioTrack = hasAudio;
        _mutedVideoHasAudio = mutedHasAudio;
        _isCheckingAudio = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Demo video has audio: $hasAudio\nMuted video has audio: '
              '$mutedHasAudio',
            ),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isCheckingAudio = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error checking audio track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  /// Checks if an audio format is supported on the current platform.
  bool _isFormatSupported(AudioFormat format) {
    if (kIsWeb) return false; // Web not supported yet

    switch (format) {
      case AudioFormat.mp3:
        // MP3 only supported on Android
        return Platform.isAndroid;
      case AudioFormat.aac:
      case AudioFormat.m4a:
        // AAC and M4A supported on all platforms
        return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
      case AudioFormat.caf:
        // CAF only supported on Apple platforms
        return Platform.isIOS || Platform.isMacOS;
    }
  }

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Extraction')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        children: [
          // Format Selection
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio Format',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: AudioFormat.values.map((format) {
                      final isSupported = _isFormatSupported(format);
                      return Tooltip(
                        message: isSupported
                            ? 'Supported on this platform'
                            : 'Not supported on ${Platform.operatingSystem}',
                        child: ChoiceChip(
                          label: Text(format.name.toUpperCase()),
                          selected: _selectedFormat == format,
                          onSelected: isSupported
                              ? (selected) {
                                  if (selected) {
                                    setState(() {
                                      _selectedFormat = format;
                                    });
                                  }
                                }
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Audio Track Check Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio Track Detection',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Check if videos have audio tracks before extraction',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),

                  // Check Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isCheckingAudio ? null : _checkAudioTrack,
                      icon: _isCheckingAudio
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.music_note),
                      label: Text(
                        _isCheckingAudio ? 'Checking...' : 'Check Audio Tracks',
                      ),
                    ),
                  ),

                  // Results
                  if (_hasAudioTrack != null ||
                      _mutedVideoHasAudio != null) ...[
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),
                    if (_hasAudioTrack != null) ...[
                      Row(
                        children: [
                          Icon(
                            _hasAudioTrack! ? Icons.check_circle : Icons.cancel,
                            color: _hasAudioTrack! ? Colors.green : Colors.red,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('Demo video (with audio):'),
                          ),
                          Text(
                            _hasAudioTrack! ? 'Has audio' : 'No audio',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color:
                                  _hasAudioTrack! ? Colors.green : Colors.red,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_mutedVideoHasAudio != null) ...[
                      Row(
                        children: [
                          Icon(
                            _mutedVideoHasAudio!
                                ? Icons.check_circle
                                : Icons.cancel,
                            color: _mutedVideoHasAudio!
                                ? Colors.green
                                : Colors.red,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('Muted video (no audio):'),
                          ),
                          Text(
                            _mutedVideoHasAudio! ? 'Has audio' : 'No audio',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _mutedVideoHasAudio!
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Extract Button with Progress
          ListTile(
            onTap: _isExtracting ? null : _extractAudio,
            leading: _isExtracting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.audiotrack),
            title:
                Text(_isExtracting ? 'Extracting Audio...' : 'Extract Audio'),
            trailing: _buildProgress(),
            tileColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 16),

          // Audio Player Section
          if (_extractedAudioPath != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Extracted Audio',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),

                    // Play/Pause Button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon:
                              Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                          iconSize: 48,
                          onPressed: _playAudio,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Progress Slider
                    Slider(
                      value: _position.inSeconds.toDouble(),
                      max: _duration.inSeconds.toDouble() > 0
                          ? _duration.inSeconds.toDouble()
                          : 1,
                      onChanged: (value) async {
                        await _audioPlayer
                            .seek(Duration(seconds: value.toInt()));
                      },
                    ),

                    // Time Display
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatDuration(_position)),
                          Text(_formatDuration(_duration)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // File Info
                    Text(
                      'File: ${_extractedAudioPath!.split('/').last}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),

                    // Delete Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _deleteAudio,
                        icon: const Icon(Icons.delete),
                        label: const Text('Delete Audio'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return StreamBuilder<ProgressModel>(
      stream: ProVideoEditor.instance.progressStreamById(_taskId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !_isExtracting) {
          return const SizedBox.shrink();
        }

        final progress = snapshot.data!.progress;
        return SizedBox(
          width: 50,
          child: Text(
            '${(progress * 100).toStringAsFixed(0)}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      },
    );
  }
}
