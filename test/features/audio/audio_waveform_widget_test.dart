import 'dart:typed_data';

import 'package:flutter/material.dart';
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
}
