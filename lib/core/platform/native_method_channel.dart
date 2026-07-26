import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:pro_video_editor/core/models/exceptions/audio_exceptions.dart';
import 'package:pro_video_editor/core/models/platform/native_log_entry.dart';
import 'package:pro_video_editor/core/models/platform/native_log_level.dart';

import '/core/models/audio/audio_extract_configs_model.dart';
import '/core/models/audio/audio_merge_configs_model.dart';
import '/core/models/audio/audio_merge_result_model.dart';
import '/core/models/audio/waveform_chunk_model.dart';
import '/core/models/audio/waveform_configs_model.dart';
import '/core/models/audio/waveform_data_model.dart';
import '/core/models/exceptions/render_exceptions.dart';
import '/core/models/thumbnail/key_frames_configs_model.dart';
import '/core/models/thumbnail/single_thumbnail_configs_model.dart';
import '/core/models/thumbnail/thumbnail_base_abstract.dart';
import '/core/models/thumbnail/thumbnail_configs_model.dart';
import '/core/models/video/editor_video_model.dart';
import '/core/models/video/progress_model.dart';
import '/core/models/video/split_video_model.dart';
import '/core/models/video/video_metadata_model.dart';
import '/core/platform/io/io_helper.dart';
import '../models/video/stop_motion_render_data_model.dart';
import '../models/video/video_render_data_model.dart';
import 'platform_interface.dart';

/// Native platform implementation using Flutter Method Channels.
///
/// This implementation supports:
/// - **iOS**: Using AVFoundation and VideoToolbox
/// - **Android**: Using MediaExtractor, MediaCodec, and Media3 Transformer
/// - **macOS**: Using AVFoundation
/// - **Windows/Linux**: Limited support (progress streams disabled)
///
/// Communication with native code happens via:
/// - [methodChannel] for request-response operations
/// - [_progressChannel] for streaming progress updates
///
/// All video processing is performed on native threads to avoid blocking
/// the Flutter UI thread.
class MethodChannelProVideoEditor extends ProVideoEditor {
  /// Error code used when a render task is cancelled by the user.
  ///
  /// This is thrown as a [PlatformException] code and converted to
  /// [RenderCanceledException] for cleaner error handling.
  static const String renderCanceledErrorCode = 'CANCELED';

  /// Error code used when the device's video encoder rejected the export
  /// configuration even after the native fallback chain was exhausted.
  ///
  /// This is thrown as a [PlatformException] code and converted to
  /// [RenderEncoderException] for cleaner error handling.
  static const String encoderNotSupportedErrorCode = 'ENCODER_NOT_SUPPORTED';

  /// Error code used when the video encoder could not be acquired because the
  /// device's codec resources were exhausted or the codec session was
  /// reclaimed.
  ///
  /// Unlike [encoderNotSupportedErrorCode] this is transient: it is thrown as a
  /// [PlatformException] code and converted to a [RenderEncoderException] with
  /// `isTransient == true`, which is worth retrying.
  static const String encoderResourceExhaustedErrorCode =
      'ENCODER_RESOURCE_EXHAUSTED';

  /// Error code used when a video has no audio track.
  ///
  /// This is thrown as a [PlatformException] code during audio extraction
  /// operations and converted to [AudioNoTrackException] for cleaner
  /// error handling.
  static const String noAudioErrorCode = 'NO_AUDIO';

  /// Primary method channel for bidirectional communication with native code.
  ///
  /// Handles all request-response operations like metadata extraction,
  /// thumbnail generation, and render requests.
  @visibleForTesting
  final methodChannel = const MethodChannel('pro_video_editor');

  /// Event channel for receiving progress updates from native code.
  ///
  /// Emits [ProgressModel] events during long-running operations like
  /// video rendering and thumbnail generation.
  final _progressChannel = const EventChannel('pro_video_editor_progress');

  /// Event channel for receiving waveform chunk data during streaming.
  ///
  /// Emits [WaveformChunk] events during streaming waveform generation,
  /// allowing progressive UI updates.
  final _waveformStreamChannel = const EventChannel(
    'pro_video_editor_waveform_stream',
  );

  /// Event channel for receiving log entries forwarded from native code.
  ///
  /// Emits [NativeLogEntry] events whenever the native plugin logs something
  /// (gated by the active `nativeLogLevel`), allowing host apps to capture
  /// renderer diagnostics in their own Dart logger.
  final _logChannel = const EventChannel('pro_video_editor_logs');

  /// Task ids whose start request is being prepared on the Dart side but has
  /// not yet been dispatched to the native layer (e.g. while
  /// [VideoRenderData.toAsyncMap] is awaited).
  ///
  /// The Dart layer awaits async work before invoking the native render, so a
  /// quick follow-up [cancel] can run while the task is still in this window.
  /// Tracking the id here lets that cancel abort the pending start instead of
  /// launching an un-cancellable native task. Once the task is dispatched the
  /// id is removed and cancellation is routed to native as usual — so the
  /// native layer keeps returning `TASK_NOT_FOUND` only for genuinely unknown
  /// ids.
  final Set<String> _pendingDispatchTaskIds = <String>{};

  /// Ids from [_pendingDispatchTaskIds] that were cancelled before their native
  /// task was dispatched. Consumed by [_handoffToNative].
  final Set<String> _cancelledBeforeDispatchTaskIds = <String>{};

  /// Marks [id] as a task being prepared on the Dart side, before its native
  /// start request is dispatched. Must be called before the first `await` so a
  /// concurrent [cancel] can observe it.
  void _beginDispatch(String id) {
    if (id.isEmpty) return;
    _pendingDispatchTaskIds.add(id);
  }

  /// Hands [id] off to the native layer: from here a [cancel] is routed to the
  /// native task. Throws [RenderCanceledException] if a [cancel] arrived while
  /// the task was still being prepared, so the native task is never started.
  void _handoffToNative(String id) {
    if (id.isEmpty) return;
    final wasCancelled = _cancelledBeforeDispatchTaskIds.remove(id);
    _pendingDispatchTaskIds.remove(id);
    if (wasCancelled) throw const RenderCanceledException();
  }

  /// Idempotent cleanup of [id]'s pre-dispatch bookkeeping. Safe to call in a
  /// `finally` whether the task was dispatched or aborted.
  void _endDispatch(String id) {
    if (id.isEmpty) return;
    _pendingDispatchTaskIds.remove(id);
    _cancelledBeforeDispatchTaskIds.remove(id);
  }

  /// Maps an encoder failure reported by native to its typed exception, or
  /// returns `null` when [error] is not an encoder failure.
  ///
  /// The two encoder codes differ only in whether a retry can help, which the
  /// caller reads from [RenderEncoderException.isTransient].
  RenderEncoderException? _asEncoderException(PlatformException error) {
    if (error.code == encoderNotSupportedErrorCode) {
      return RenderEncoderException(error.message);
    }
    if (error.code == encoderResourceExhaustedErrorCode) {
      return RenderEncoderException(error.message, true);
    }
    return null;
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<VideoMetadata> getMetadata(
    EditorVideo value, {
    bool checkStreamingOptimization = false,
    NativeLogLevel? nativeLogLevel,
  }) async {
    var inputPath = await value.safeFilePath();

    var extension = _getFileExtension(inputPath);

    final response =
        await methodChannel.invokeMethod<Map<dynamic, dynamic>>('getMetadata', {
          'inputPath': inputPath,
          'extension': extension,
          'checkStreamingOptimization': checkStreamingOptimization,
          'nativeLogLevel': nativeLogLevel?.methodValue,
        }) ??
        {};

    return VideoMetadata.fromMap(response, extension);
  }

  @override
  Future<bool> hasAudioTrack(
    EditorVideo value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    var inputPath = await value.safeFilePath();

    final result = await methodChannel.invokeMethod<bool>('hasAudioTrack', {
      'inputPath': inputPath,
      'extension': _getFileExtension(inputPath),
      'nativeLogLevel': nativeLogLevel?.methodValue,
    });

    return result ?? false;
  }

  Future<List<Uint8List>> _extractThumbnails(
    ThumbnailBase value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    var inputPath = await value.video.safeFilePath();

    final response = await methodChannel
        .invokeMethod<List<dynamic>>('getThumbnails', {
          'inputPath': inputPath,
          'extension': _getFileExtension(inputPath),
          'nativeLogLevel': nativeLogLevel?.methodValue,
          ...value.toMap(),
        });
    final List<Uint8List> result = response?.cast<Uint8List>() ?? [];

    return result;
  }

  @override
  Future<List<Uint8List>> getThumbnails(
    ThumbnailConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    return await _extractThumbnails(value, nativeLogLevel: nativeLogLevel);
  }

  @override
  Future<List<Uint8List>> getKeyFrames(
    KeyFramesConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    return await _extractThumbnails(value, nativeLogLevel: nativeLogLevel);
  }

  @override
  Future<Uint8List?> getSingleThumbnail(
    SingleThumbnailConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    final bool isLastFrame = value.position == ThumbnailPosition.last;
    Duration timestamp;
    if (isLastFrame) {
      final duration =
          value.videoDuration ??
          (await getMetadata(
            value.video,
            nativeLogLevel: nativeLogLevel,
          )).duration;
      timestamp = duration;
    } else {
      timestamp = Duration.zero;
    }

    var inputPath = await value.video.safeFilePath();

    final response = await methodChannel.invokeMethod<List<dynamic>>(
      'getThumbnails',
      {
        'inputPath': inputPath,
        'extension': _getFileExtension(inputPath),
        'nativeLogLevel': nativeLogLevel?.methodValue,
        ...value.toMap(),
        'timestamps': [timestamp.inMicroseconds],
        'lastFrameTolerance': isLastFrame,
      },
    );
    final List<Uint8List> result = response?.cast<Uint8List>() ?? [];
    if (result.isEmpty) return null;
    // A frame that failed or fell out of range comes back as an empty entry;
    // surface that as "no thumbnail" rather than a zero-byte, broken image.
    final Uint8List first = result.first;
    return first.isNotEmpty ? first : null;
  }

  @override
  Future<Uint8List> extractAudio(
    AudioExtractConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    try {
      var inputPath = await value.video.safeFilePath();

      final Uint8List? result = await methodChannel
          .invokeMethod<Uint8List>('extractAudio', {
            'inputPath': inputPath,
            'extension': _getFileExtension(inputPath),
            'nativeLogLevel': nativeLogLevel?.methodValue,
            ...value.toMap(),
          });

      if (result == null) {
        throw ArgumentError('Failed to extract audio from video');
      }

      return result;
    } on PlatformException catch (error) {
      if (error.code == noAudioErrorCode) {
        throw const AudioNoTrackException();
      } else if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    }
  }

  @override
  Future<String> extractAudioToFile(
    String filePath,
    AudioExtractConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    try {
      var inputPath = await value.video.safeFilePath();

      await methodChannel.invokeMethod<String>('extractAudio', {
        'inputPath': inputPath,
        'extension': _getFileExtension(inputPath),
        'nativeLogLevel': nativeLogLevel?.methodValue,
        'outputPath': filePath,
        ...value.toMap(),
      });

      return filePath;
    } on PlatformException catch (error) {
      if (error.code == noAudioErrorCode) {
        throw const AudioNoTrackException();
      } else if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    }
  }

  @override
  Future<AudioMergeResult> mergeAudioToFile(
    String filePath,
    AudioMergeConfigs configs, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    // Validate before touching native so callers get an ArgumentError rather
    // than an opaque PlatformException (asserts are stripped in release).
    if (configs.segments.isEmpty) {
      throw ArgumentError.value(
        configs.segments,
        'segments',
        'must contain at least one segment',
      );
    }
    for (var i = 0; i < configs.segments.length; i++) {
      final segment = configs.segments[i];
      if (segment.endTime <= segment.startTime) {
        throw ArgumentError(
          'segment[$i]: endTime (${segment.endTime}) must be after '
          'startTime (${segment.startTime})',
        );
      }
      if (segment.speed <= 0) {
        throw ArgumentError(
          'segment[$i]: speed (${segment.speed}) must be greater than 0',
        );
      }
    }

    try {
      // Resolve every segment to a local file path, preserving order.
      final inputPaths = <String>[];
      for (final segment in configs.segments) {
        inputPaths.add(await segment.video.safeFilePath());
      }

      final response = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('mergeAudio', {
            'nativeLogLevel': nativeLogLevel?.methodValue,
            'outputPath': filePath,
            ...configs.toMap(inputPaths),
          });

      if (response == null) {
        throw ArgumentError('Failed to merge audio');
      }

      return AudioMergeResult.fromMap(response);
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    }
  }

  @override
  Future<WaveformData> getWaveform(
    WaveformConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    try {
      var inputPath = await value.video.safeFilePath();

      final response = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('getWaveform', {
            'inputPath': inputPath,
            'extension': _getFileExtension(inputPath),
            'nativeLogLevel': nativeLogLevel?.methodValue,
            ...value.toMap(),
          });

      if (response == null) {
        throw ArgumentError('Failed to generate waveform data');
      }

      return WaveformData.fromMap(response);
    } on PlatformException catch (error) {
      if (error.code == noAudioErrorCode) {
        throw const AudioNoTrackException();
      } else if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    }
  }

  @override
  Stream<WaveformChunk> getWaveformStream(
    WaveformConfigs value, {
    NativeLogLevel? nativeLogLevel,
  }) async* {
    // Get the input path before starting the stream
    final inputPath = await value.video.safeFilePath();
    final extension = _getFileExtension(inputPath);

    // Start the streaming waveform generation on native side
    // The native side will start sending chunks via the event channel
    await methodChannel.invokeMethod<void>('startWaveformStream', {
      'inputPath': inputPath,
      'extension': extension,
      'nativeLogLevel': nativeLogLevel?.methodValue,
      ...value.toMap(),
    });

    // Listen to the waveform stream event channel
    final streamController = StreamController<WaveformChunk>();

    StreamSubscription<dynamic>? subscription;

    subscription = _waveformStreamChannel.receiveBroadcastStream().listen(
      (event) {
        try {
          if (event is Map) {
            // Check if this event is for our task
            final eventId = event['id'] as String?;
            if (eventId == value.id) {
              // Check for error
              final error = event['error'] as String?;
              if (error != null) {
                final errorCode = event['errorCode'] as String?;
                if (errorCode == noAudioErrorCode) {
                  streamController.addError(const AudioNoTrackException());
                } else if (errorCode == renderCanceledErrorCode) {
                  streamController.addError(const RenderCanceledException());
                } else {
                  streamController.addError(
                    PlatformException(
                      code: errorCode ?? 'WAVEFORM_ERROR',
                      message: error,
                    ),
                  );
                }
                streamController.close();
                subscription?.cancel();
                return;
              }

              // Parse the chunk data
              final chunk = WaveformChunk.fromMap(event);
              streamController.add(chunk);

              // Close stream if this is the final chunk
              if (chunk.isComplete) {
                streamController.close();
                subscription?.cancel();
              }
            }
          }
        } catch (e, stack) {
          debugPrint('Error parsing waveform chunk: $e\n$stack');
          streamController.addError(e);
        }
      },
      onError: (error) {
        streamController
          ..addError(error)
          ..close();
      },
      onDone: () {
        if (!streamController.isClosed) {
          streamController.close();
        }
      },
    );

    // Clean up when the stream is cancelled
    streamController.onCancel = () {
      subscription?.cancel();
      // Cancel the native task if still running
      cancel(value.id).catchError((_) {});
    };

    yield* streamController.stream;
  }

  @override
  Future<Uint8List> renderVideo(
    VideoRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    _beginDispatch(value.id);
    try {
      final renderData = await value.toAsyncMap();
      _handoffToNative(value.id);

      final Uint8List? result = await methodChannel.invokeMethod<Uint8List>(
        'renderVideo',
        {...renderData, 'nativeLogLevel': nativeLogLevel?.methodValue},
      );

      if (result == null) {
        throw ArgumentError('Failed to export the video');
      }

      return result;
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      final encoderError = _asEncoderException(error);
      if (encoderError != null) throw encoderError;
      rethrow;
    } finally {
      _endDispatch(value.id);
    }
  }

  @override
  Future<String> renderVideoToFile(
    String filePath,
    VideoRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    _beginDispatch(value.id);
    try {
      final renderData = await value.toAsyncMap();
      _handoffToNative(value.id);

      await methodChannel.invokeMethod<String>('renderVideo', {
        ...renderData,
        'outputPath': filePath,
        'nativeLogLevel': nativeLogLevel?.methodValue,
      });

      return filePath;
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      final encoderError = _asEncoderException(error);
      if (encoderError != null) throw encoderError;
      rethrow;
    } finally {
      _endDispatch(value.id);
    }
  }

  @override
  Future<Uint8List> renderStopMotion(
    StopMotionRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    _beginDispatch(value.id);
    try {
      final renderData = await value.toAsyncMap();
      _handoffToNative(value.id);

      final Uint8List? result = await methodChannel.invokeMethod<Uint8List>(
        'renderStopMotion',
        {...renderData, 'nativeLogLevel': nativeLogLevel?.methodValue},
      );

      if (result == null) {
        throw ArgumentError('Failed to export the stop-motion video');
      }

      return result;
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    } finally {
      _endDispatch(value.id);
    }
  }

  @override
  Future<String> renderStopMotionToFile(
    String filePath,
    StopMotionRenderData value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    _beginDispatch(value.id);
    try {
      final renderData = await value.toAsyncMap();
      _handoffToNative(value.id);

      await methodChannel.invokeMethod<String>('renderStopMotion', {
        ...renderData,
        'outputPath': filePath,
        'nativeLogLevel': nativeLogLevel?.methodValue,
      });

      return filePath;
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      rethrow;
    } finally {
      _endDispatch(value.id);
    }
  }

  @override
  Future<List<String>> splitVideo(
    SplitVideoModel value, {
    NativeLogLevel? nativeLogLevel,
  }) async {
    _beginDispatch(value.id);
    try {
      final inputPath = await value.video.safeFilePath();
      _handoffToNative(value.id);

      await methodChannel.invokeMethod<void>('splitVideo', {
        'id': value.id,
        'inputPath': inputPath,
        'extension': _getFileExtension(inputPath),
        'splitUs': value.splitPosition.inMicroseconds,
        'startOutputPath': value.startOutputPath,
        'endOutputPath': value.endOutputPath,
        'outputFormat': value.outputFormat.name,
        'bitrate': value.effectiveBitrate,
        'enableAudio': value.enableAudio,
        'exportTimeoutMs': value.exportTimeout.inMilliseconds,
        'stallTimeoutMs': value.stallTimeout.inMilliseconds,
        'nativeLogLevel': nativeLogLevel?.methodValue,
      });

      return [value.startOutputPath, value.endOutputPath];
    } on PlatformException catch (error) {
      if (error.code == renderCanceledErrorCode) {
        throw const RenderCanceledException();
      }
      final encoderError = _asEncoderException(error);
      if (encoderError != null) throw encoderError;
      rethrow;
    } finally {
      _endDispatch(value.id);
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    if (taskId.isEmpty) {
      throw ArgumentError('taskId cannot be empty');
    }

    // If the task is still being prepared on the Dart side (its start hasn't
    // been dispatched to native yet), cancel it locally so the pending start
    // aborts instead of launching an un-cancellable native task. The native
    // layer never sees this id, so it keeps reporting TASK_NOT_FOUND only for
    // genuinely unknown ids.
    if (_pendingDispatchTaskIds.contains(taskId)) {
      _cancelledBeforeDispatchTaskIds.add(taskId);
      return;
    }

    await methodChannel.invokeMethod<void>('cancelTask', {'id': taskId});
  }

  @override
  void initializeStream() {
    // Windows and Linux don't support EventChannels for progress yet
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return;

    // Subscribe to native progress events
    _progressChannel
        .receiveBroadcastStream()
        .map((event) {
          try {
            return ProgressModel.fromMap(event);
          } catch (e, stack) {
            // Log parsing errors but don't crash - return error progress
            debugPrint('Error parsing progress event: $e\n$stack');
            return const ProgressModel(id: 'error', progress: 0);
          }
        })
        .listen(progressCtrl.add);

    // Subscribe to native log events
    _logChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        try {
          logCtrl.add(NativeLogEntry.fromMap(event));
        } catch (e, stack) {
          // Never let a malformed log entry break the stream.
          debugPrint('Error parsing native log event: $e\n$stack');
        }
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('Native log stream error: $error\n$stack');
      },
    );
  }

  /// Extracts file extension from path using MIME type detection.
  ///
  /// Uses the `mime` package to detect file type from extension, then
  /// extracts the subtype (e.g., 'mp4' from 'video/mp4').
  ///
  /// Falls back to 'mp4' if detection fails.
  ///
  /// [inputPath] File path or URL to analyze.
  ///
  /// Returns file extension without dot (e.g., 'mp4', 'mov', 'webm').
  String _getFileExtension(String inputPath) {
    var mimeType = lookupMimeType(inputPath);
    var mimeSp = mimeType?.split('/') ?? [];
    var extension = mimeSp.length == 2 ? mimeSp[1] : 'mp4';

    return extension;
  }
}
