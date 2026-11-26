import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

WaveformData buildWaveform({bool stereo = false}) {
  final left = Float32List(120);
  for (var i = 0; i < left.length; i++) {
    left[i] = (i % 10) / 10;
  }
  Float32List? right;
  if (stereo) {
    right = Float32List(120);
    for (var i = 0; i < right.length; i++) {
      right[i] = (i % 7) / 7;
    }
  }
  return WaveformData(
    leftChannel: left,
    rightChannel: right,
    sampleRate: 44100,
    duration: const Duration(seconds: 2),
    samplesPerSecond: 60,
  );
}

void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('renders mono waveform without error', (tester) async {
    await pump(tester, AudioWaveform(waveform: buildWaveform()));

    expect(tester.takeException(), isNull);
    expect(find.byType(AudioWaveform), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('renders stereo waveform without error', (tester) async {
    await pump(tester, AudioWaveform(waveform: buildWaveform(stereo: true)));

    expect(tester.takeException(), isNull);
    expect(find.byType(AudioWaveform), findsOneWidget);
  });

  testWidgets('interactive tap reports a seek position', (tester) async {
    Duration? seeked;

    await pump(
      tester,
      SizedBox(
        width: 300,
        child: AudioWaveform.interactive(
          waveform: buildWaveform(),
          currentPosition: Duration.zero,
          onSeek: (position) => seeked = position,
        ),
      ),
    );

    await tester.tap(find.byType(AudioWaveform));
    await tester.pump();

    expect(seeked, isNotNull, reason: 'tap should trigger an onSeek callback');
    expect(seeked!.inMilliseconds, greaterThan(0));
  });

  testWidgets('non-interactive waveform tolerates taps', (tester) async {
    await pump(
      tester,
      SizedBox(width: 300, child: AudioWaveform(waveform: buildWaveform())),
    );

    await tester.tap(find.byType(AudioWaveform));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
  testWidgets('streaming waveform reports a stream error to onError', (
    tester,
  ) async {
    const methodChannel = MethodChannel('pro_video_editor');
    const streamChannel = EventChannel('pro_video_editor_waveform_stream');
    final messenger = tester.binding.defaultBinaryMessenger;
    MockStreamHandlerEventSink? sink;
    messenger
      ..setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'startWaveformStream') {
          sink?.success({
            'id': 'silent',
            'error': 'No audio track',
            'errorCode': 'NO_AUDIO',
          });
        }
        return null;
      })
      ..setMockStreamHandler(
        streamChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            sink = events;
          },
        ),
      );
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(methodChannel, null)
        ..setMockStreamHandler(streamChannel, null);
    });
    final errors = <Object>[];

    await pump(
      tester,
      SizedBox(
        width: 300,
        child: AudioWaveform.streaming(
          config: WaveformConfigs(
            id: 'silent',
            video: EditorVideo.file('/tmp/silent.mp4'),
          ),
          onError: errors.add,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(errors, [isA<AudioNoTrackException>()]);
    expect(tester.takeException(), isNull);
  });
}
