import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// On-device checks for [EditorVideo.content]: every feature that reads a
/// video has to open an Android `content://` URI in place.
///
/// The suite runs against three kinds of source:
/// - MediaStore: the example app's MainActivity publishes the test assets, so
///   the sources are real `content://media/...` URIs like the ones the photo
///   picker hands out. They carry no file extension.
/// - A document provider: the example app's TestMediaProvider serves the
///   files itself, as SAF and cloud providers do.
/// - A pipe: the same provider streams the files through a pipe, which cannot
///   be seeked, like some cloud providers return for remote files.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  const mediaStore = MethodChannel('pro_video_editor_example/media_store');

  /// Content URIs are an Android-only source.
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 1920x1080, 5 s, H.264 with audible stereo AAC.
  const clipAsset = 'assets/tests/test_a.mp4';

  /// Re-encoding can add or drop a frame or two at a cut.
  const toleranceMs = 300;

  void expectCloseMs(Duration actual, int expectedMs, String reason) {
    expect(
      actual.inMilliseconds,
      closeTo(expectedMs, toleranceMs),
      reason: reason,
    );
  }

  /// Runs [body] and returns the native warnings and errors logged meanwhile.
  ///
  /// The render paths fall back silently when they cannot open a source (a
  /// reversed clip plays forward, a transition becomes a hard cut, a custom
  /// track is dropped), so their logs are the only sign of a failure.
  Future<List<String>> problemsDuring(Future<void> Function() body) async {
    final problems = <String>[];
    final sub = pve.logStream.listen((entry) {
      if (entry.level == NativeLogLevel.warning ||
          entry.level == NativeLogLevel.error) {
        problems.add('${entry.level.name}: ${entry.message}');
      }
    });
    try {
      await body();
      // Log entries arrive over their own event channel.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      await sub.cancel();
    }
    return problems;
  }

  /// The number of file descriptors this process holds open. Links are not
  /// followed, since other threads open and close descriptors meanwhile.
  int openFds() =>
      Directory('/proc/self/fd').listSync(followLinks: false).length;

  final insertedUris = <String>[];

  Future<String?> publishToMediaStore(String path, String mimeType) async {
    final uri = await mediaStore.invokeMethod<String>('insert', {
      'path': path,
      'mimeType': mimeType,
    });
    if (uri != null) insertedUris.add(uri);
    return uri;
  }

  tearDownAll(() async {
    for (final uri in insertedUris) {
      await mediaStore.invokeMethod<int>('delete', {'uri': uri});
    }
  });

  /// Runs every check on content URIs that [publish] makes for local files.
  /// [uriPrefix] starts every such URI, and [missingUri] is one that cannot
  /// be opened.
  void contentSuite(
    String name, {
    required Future<String?> Function(String path, String mimeType) publish,
    required String uriPrefix,
    required String missingUri,
  }) {
    final tempFiles = <String>[];

    // Local copies of the assets and their content sources.
    late String demoFile;
    late EditorVideo demo;
    late String clipFile;
    late EditorVideo clip;
    late String songUri;

    /// False when [publish] cannot make a source, e.g. a MediaStore insert
    /// below Android 10, which needs a permission.
    var published = false;

    Future<String> tempPath(String name) async {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final path = '${dir.path}/content_${stamp}_$name';
      tempFiles.add(path);
      return path;
    }

    Future<String> copyAsset(String asset) async {
      final data = await rootBundle.load(asset);
      final path = await tempPath(asset.split('/').last);
      await File(path).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      return path;
    }

    group('EditorVideo.content ($name)', () {
      setUpAll(() async {
        demoFile = await copyAsset(kVideoEditorExampleH264Path);
        clipFile = await copyAsset(clipAsset);
        final songFile = await copyAsset(kVideoEditorExampleAudio1Path);

        final demoUri = await publish(demoFile, 'video/mp4');
        final clipUri = await publish(clipFile, 'video/mp4');
        final song = await publish(songFile, 'audio/mpeg');
        if (demoUri == null || clipUri == null || song == null) return;

        demo = EditorVideo.content(demoUri);
        clip = EditorVideo.content(clipUri);
        songUri = song;
        published = true;
      });

      tearDownAll(() async {
        for (final path in tempFiles) {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        }
      });

      testWidgets('sources are content URIs', (_) async {
        if (!published) return;
        expect(demo.contentUrl, startsWith(uriPrefix));
        expect(demo.type, EditorVideoType.content);
      });

      testWidgets('getMetadata matches the file source', (_) async {
        if (!published) return;
        final fromFile = await pve.getMetadata(
          EditorVideo.file(demoFile),
          checkStreamingOptimization: true,
        );
        final fromContent = await pve.getMetadata(
          demo,
          checkStreamingOptimization: true,
        );

        expect(fromContent.duration, fromFile.duration);
        expect(fromContent.resolution, fromFile.resolution);
        expect(fromContent.rotation, fromFile.rotation);
        expect(fromContent.bitrate, fromFile.bitrate);
        expect(fromContent.audioDuration, fromFile.audioDuration);
        expect(fromContent.fileSize, 5253880);
        expect(fromFile.fileSize, 5253880);
        expect(fromContent.extension, 'mp4');
        expect(fromContent.isOptimizedForStreaming, isNotNull);
        expect(
          fromContent.isOptimizedForStreaming,
          fromFile.isOptimizedForStreaming,
        );
      });

      testWidgets('hasAudioTrack reads the content source', (_) async {
        if (!published) return;
        expect(await pve.hasAudioTrack(demo), isTrue);
      });

      testWidgets('getThumbnails decodes every timestamp', (_) async {
        if (!published) return;
        final thumbnails = await pve.getThumbnails(
          ThumbnailConfigs(
            video: clip,
            outputSize: const Size(160, 90),
            timestamps: [for (var s = 0; s < 5; s++) Duration(seconds: s)],
          ),
        );

        expect(thumbnails, hasLength(5));
        expect(thumbnails.every((bytes) => bytes.isNotEmpty), isTrue);
      });

      testWidgets('getThumbnailStream delivers every timestamp', (_) async {
        if (!published) return;
        final seen = <int>{};
        final stream = pve.getThumbnailStream(
          ThumbnailConfigs(
            video: clip,
            outputSize: const Size(160, 90),
            timestamps: [
              for (var ms = 0; ms < 5000; ms += 250) Duration(milliseconds: ms),
            ],
          ),
        );
        await for (final frame in stream) {
          expect(frame.bytes, isNotEmpty);
          seen.addAll(frame.indices);
        }

        expect(seen, hasLength(20));
      });

      testWidgets('getKeyFrames and getSingleThumbnail', (_) async {
        if (!published) return;
        final keyFrames = await pve.getKeyFrames(
          KeyFramesConfigs(
            video: clip,
            outputSize: const Size(160, 90),
            maxOutputFrames: 3,
          ),
        );
        final last = await pve.getSingleThumbnail(
          SingleThumbnailConfigs(
            video: clip,
            outputSize: const Size(160, 90),
            position: ThumbnailPosition.last,
          ),
        );

        expect(keyFrames, isNotEmpty);
        expect(last, isNotNull);
        expect(last, isNotEmpty);
      });

      testWidgets('extractAudio and extractAudioToFile', (_) async {
        if (!published) return;
        final bytes = await pve.extractAudio(
          AudioExtractConfigs(video: clip, format: AudioFormat.aac),
        );
        final wavPath = await tempPath('extract.wav');
        await pve.extractAudioToFile(
          wavPath,
          AudioExtractConfigs(
            video: clip,
            format: AudioFormat.wav,
            endTime: const Duration(seconds: 2),
          ),
        );
        final pcm = Pcm.parseWav(await File(wavPath).readAsBytes());

        expect(bytes.lengthInBytes, greaterThan(1000));
        expect(pcm.seconds, closeTo(2, 0.3), reason: 'trimmed extract is 2 s');
        expect(pcm.rms(0, 2), greaterThan(0.001), reason: 'audio is silent');
      });

      testWidgets('getWaveform and getWaveformStream', (_) async {
        if (!published) return;
        final waveform = await pve.getWaveform(WaveformConfigs(video: clip));
        final chunks = pve.getWaveformStream(WaveformConfigs(video: clip));
        var chunkSamples = 0;
        await for (final chunk in chunks) {
          chunkSamples += chunk.leftChannel.length;
        }

        expect(waveform.sampleCount, greaterThan(0));
        expectCloseMs(waveform.duration, 5000, 'waveform covers the clip');
        expect(chunkSamples, greaterThan(0));
      });

      testWidgets('renders a trimmed segment', (_) async {
        if (!published) return;
        final result = await pve.renderVideo(
          VideoRenderData(
            videoSegments: [
              VideoSegment(video: clip, endTime: const Duration(seconds: 2)),
            ],
          ),
        );
        final meta = await pve.getMetadata(EditorVideo.memory(result));

        expectCloseMs(meta.duration, 2000, 'rendered trim should be ~2 s');
        expect(meta.resolution, const Size(1920, 1080));
      });

      testWidgets('renders a reversed segment', (_) async {
        if (!published) return;
        late Uint8List result;
        final problems = await problemsDuring(() async {
          result = await pve.renderVideo(
            VideoRenderData(
              videoSegments: [
                VideoSegment(
                  video: clip,
                  endTime: const Duration(seconds: 2),
                  reverseVideo: true,
                ),
              ],
            ),
          );
        });
        final meta = await pve.getMetadata(EditorVideo.memory(result));

        expect(problems, isEmpty, reason: 'reverse fell back: $problems');
        expectCloseMs(meta.duration, 2000, 'reversed clip should be ~2 s');
      });

      testWidgets('renders a dissolve between content clips', (_) async {
        if (!published) return;
        late Uint8List result;
        final problems = await problemsDuring(() async {
          result = await pve.renderVideo(
            VideoRenderData(
              videoSegments: [
                VideoSegment(
                  video: clip,
                  endTime: const Duration(seconds: 2),
                  transition: const ClipTransition(
                    type: ClipTransitionType.dissolve,
                    duration: Duration(milliseconds: 500),
                  ),
                ),
                VideoSegment(
                  video: clip,
                  startTime: const Duration(seconds: 3),
                  endTime: const Duration(seconds: 5),
                ),
              ],
            ),
          );
        });
        final meta = await pve.getMetadata(EditorVideo.memory(result));

        expect(problems, isEmpty, reason: 'transition fell back: $problems');
        // Two 2 s clips overlapping by 500 ms; a hard cut would be 4 s.
        expectCloseMs(meta.duration, 3500, 'the clips should overlap');
      });

      testWidgets('renders one source on two composition layers', (_) async {
        if (!published) return;
        late Uint8List result;
        final problems = await problemsDuring(() async {
          result = await pve.renderVideo(
            VideoRenderData(
              composition: VideoComposition(
                canvasSize: const Size(1280, 720),
                layers: [
                  VideoLayer(clips: [VideoSegment(video: clip)]),
                  VideoLayer(
                    clips: [VideoSegment(video: clip)],
                    transform: const SegmentTransform(
                      offset: Offset(20, 20),
                      size: Size(320, 180),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
        final meta = await pve.getMetadata(EditorVideo.memory(result));

        expect(problems, isEmpty, reason: 'layer source failed: $problems');
        expect(meta.resolution, const Size(1280, 720));
        expectCloseMs(meta.duration, 5000, 'layers keep the clip duration');
      });

      testWidgets('renders a custom audio track from a content URI', (_) async {
        if (!published) return;
        final videoPath = await tempPath('song.mp4');
        final wavPath = await tempPath('song.wav');
        final problems = await problemsDuring(() async {
          await pve.renderVideoToFile(
            videoPath,
            VideoRenderData(
              videoSegments: [
                VideoSegment(
                  video: clip,
                  endTime: const Duration(seconds: 3),
                  volume: 0,
                ),
              ],
              audioTracks: [VideoAudioTrack(path: songUri)],
            ),
          );
        });
        await pve.extractAudioToFile(
          wavPath,
          AudioExtractConfigs(
            video: EditorVideo.file(videoPath),
            format: AudioFormat.wav,
          ),
        );
        final pcm = Pcm.parseWav(await File(wavPath).readAsBytes());

        expect(problems, isEmpty, reason: 'custom track failed: $problems');
        // The segment is muted, so any sound comes from the content track.
        expect(pcm.rms(0.5, 2.5), greaterThan(0.01), reason: 'track dropped');
      });

      testWidgets('splitVideo cuts the content source', (_) async {
        if (!published) return;
        final startPath = await tempPath('start.mp4');
        final endPath = await tempPath('end.mp4');
        await pve.splitVideo(
          SplitVideoModel(
            video: clip,
            splitPosition: const Duration(seconds: 2),
            startOutputPath: startPath,
            endOutputPath: endPath,
          ),
        );
        final start = await pve.getMetadata(EditorVideo.file(startPath));
        final end = await pve.getMetadata(EditorVideo.file(endPath));

        expectCloseMs(start.duration, 2000, 'start half should be ~2 s');
        expectCloseMs(end.duration, 3000, 'end half should be ~3 s');
      });

      testWidgets('mergeAudioToFile reads content segments', (_) async {
        if (!published) return;
        final out = await tempPath('merge.wav');
        final result = await pve.mergeAudioToFile(
          out,
          AudioMergeConfigs(
            segments: [
              AudioMergeSegment(
                video: demo,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 2),
              ),
              AudioMergeSegment(
                video: clip,
                startTime: const Duration(seconds: 1),
                endTime: const Duration(seconds: 2),
              ),
            ],
          ),
        );

        expect(result.segments, hasLength(2));
        expectCloseMs(result.totalDuration, 3000, 'merged audio is 2 s + 1 s');
      });

      testWidgets('repeated calls do not leak file descriptors', (_) async {
        if (!published) return;
        Future<void> round() async {
          await pve.getMetadata(demo, checkStreamingOptimization: true);
          await pve.hasAudioTrack(demo);
          await pve.getThumbnails(
            ThumbnailConfigs(
              video: clip,
              outputSize: const Size(64, 36),
              timestamps: const [Duration.zero, Duration(seconds: 2)],
            ),
          );
          await pve.getWaveform(WaveformConfigs(video: clip));
        }

        // The first round warms up decoder and thread pools.
        await round();
        final before = openFds();
        for (var i = 0; i < 5; i++) {
          await round();
        }
        final after = openFds();

        expect(
          after - before,
          lessThanOrEqualTo(2),
          reason: '$before -> $after',
        );
      });

      testWidgets('safeFilePath copies the content into a file', (_) async {
        if (!published) return;
        final video = EditorVideo.content(demo.contentUrl!);
        final path = await video.safeFilePath();
        tempFiles.add(path);

        expect(path, endsWith('.mp4'));
        expect(File(path).lengthSync(), File(demoFile).lengthSync());
        expect(await video.contentOrSafeFilePath(), path);
      });

      testWidgets('an unreadable content URI fails cleanly', (_) async {
        if (!published) return;
        final missing = EditorVideo.content(missingUri);

        await expectLater(pve.getMetadata(missing), throwsA(anything));
        expect(await pve.hasAudioTrack(demo), isTrue);
      });
    }, skip: !isAndroid);
  }

  /// Serves files from the app's cache directory, which is where the
  /// temporary asset copies live.
  const provider = 'content://com.example.pro_video_editor_example.testmedia';

  contentSuite(
    'MediaStore',
    publish: publishToMediaStore,
    uriPrefix: 'content://media/',
    missingUri: 'content://media/external/video/media/2147483647',
  );
  contentSuite(
    'document provider',
    publish: (path, _) async => '$provider/file/${path.split('/').last}',
    uriPrefix: '$provider/file/',
    missingUri: '$provider/file/missing.mp4',
  );
  contentSuite(
    'pipe',
    publish: (path, _) async => '$provider/pipe/${path.split('/').last}',
    uriPrefix: '$provider/pipe/',
    missingUri: '$provider/pipe/missing.mp4',
  );
}
