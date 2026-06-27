<img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/logo.jpg?raw=true" alt="Logo" />

<p>
    <a href="https://pub.dartlang.org/packages/pro_video_editor">
        <img src="https://img.shields.io/pub/v/pro_video_editor.svg" alt="pub package">
    </a>
    <a href="https://github.com/sponsors/hm21">
        <img src="https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23f5372a" alt="Sponsor">
    </a>
    <a href="https://img.shields.io/github/license/hm21/pro_video_editor">
        <img src="https://img.shields.io/github/license/hm21/pro_video_editor" alt="License">
    </a>
    <a href="https://github.com/hm21/pro_video_editor/issues">
        <img src="https://img.shields.io/github/issues/hm21/pro_video_editor" alt="GitHub issues">
    </a> 
</p>

The ProVideoEditor is a Flutter widget designed for video editing within your application. It provides a flexible and convenient way to integrate video editing capabilities into your Flutter project.


## Table of contents

- **[📷 Preview](#preview)**
- **[✨ Features](#features)**
- **[🔧 Setup](#setup)**
- **[❓ Usage](#usage)**
- **[💖 Sponsors](#sponsors)**
- **[📦 Included Packages](#included-packages)**
- **[🤝 Contributors](#contributors)**
- **[📜 License](LICENSE)**
- **[📜 Notices](NOTICES)**

## Preview
<table>
  <thead>
    <tr>
      <th align="center">Basic-Editor</th>
      <th align="center">Grounded-Design</th>
      <th align="center">Paint-Editor</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Main-Editor.jpg?raw=true" alt="Main-Editor" />
      </td>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Grounded-Editor.jpg?raw=true" alt="Grounded-Editor" />
      </td>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Paint-Editor.jpg?raw=true" alt="Paint-Editor" />
      </td>
    </tr>
  </tbody>
</table>
<table>
  <thead>
    <tr>
      <th align="center">Crop-Rotate-Editor</th>
      <th align="center">Tune-Editor</th>
      <th align="center">Filter-Editor</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Crop-Rotate-Editor.jpg?raw=true" alt="Crop-Rotate-Editor" />
      </td>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Tune-Editor.jpg?raw=true" alt="Tune-Editor" />
      </td>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Filter-Editor.jpg?raw=true" alt="Filter-Editor" />
      </td>
    </tr>
  </tbody>
</table>
<table>
  <thead>
    <tr>
      <th align="center">Paint-Editor-Grounded</th>
      <th align="center">Emoji-Editor</th>
      <th align="center"></th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Paint-Editor-Grounded.jpg?raw=true" alt="Paint-Editor-Grounded" />
      </td>
      <td align="center" width="33.3%">
        <img src="https://github.com/hm21/pro_video_editor/blob/stable/assets/preview/Emoji-Editor.jpg?raw=true" alt="Emoji-Editor" />
      </td>
      <td align="center" width="33.3%">
      </td>
    </tr>
  </tbody>
</table>


## Features

#### 🎥 Video Editing Capabilities

- 📈 **Metadata**: Extract detailed metadata from the video file.
- 🖼️ **Thumbnails**: Generate one or multiple thumbnails from the video.
- 🎞️ **Keyframes**: Retrieve keyframe information from the video.
- ✂️ **Trim**: Cut the video to a specified start and end time.
- 🔗 **Merge Videos**: Concatenate multiple video clips into a single output.
- 🎬 **Stop-Motion**: Turn a sequence of still images into a video, each frame held for a configurable duration.
- ⏩ **Playback Speed**: Adjust the playback speed of the video.
- ⏪ **Reverse Video**: Play a video segment backwards.
- 🔇 **Mute Audio**: Remove or mute the audio track from the video.
- 📊 **Waveform**: Generate audio waveform data for visualization, with support for streaming mode.

#### 🔧 **Transformations**
- ✂️ Crop by `x`, `y`, `width`, and `height`
- 🔁 Flip horizontally and/or vertically
- 🔄 Rotate by 90deg turns
- 🔍 Scale to a custom size

#### 🎨 **Visual Effects**
- 🖼️ **Layers**: Overlay a image like a text or drawings on the video.
- 🕐 **Timed Image Layers**: Position image overlays at specific coordinates with optional start/end times.
- 📐 **Layer Size**: Scale image layers to custom dimensions via the `size` property.
- 🎬 **Layer Animations**: Animate image layers with fade, slide, and scale effects, configurable easing curves, and in/out/inOut phases.
- 🎞️ **Clip Transitions**: Add transitions between adjacent clips — `dissolve`, `fadeToBlack`, `fadeToWhite`, `slide`, `push`, and `wipe` — with configurable duration, easing curve, and direction.
- 🧮 **Color Matrix**: Apply one or multiple 4x5 color matrices (e.g., for filters).
- 💧 **Blur**: Add a blur effect to the video.
- 📡 **Bitrate**: Set a custom video bitrate. If constant bitrate (CBR) isn't supported, it will gracefully fall back to the next available mode.
- 🌐 **Streaming Optimization**: Optimize video for progressive playback by placing metadata (moov atom) at the start of the file.

#### 📱 **Runtime Features**
- 📊 **Progress**: Track the progress of one or multiple running tasks.
- 🧵 **Multi-Tasking**: Execute multiple video processing tasks concurrently.
- 🔇 **Native Log Level**: Control native log verbosity per API call with `NativeLogLevel` (`none`, `error`, `warning`, `info`, `debug`, `verbose`).
- 🪵 **Native Log Stream**: Receive native logs (including renderer diagnostics) back in Dart via `logStream` to pipe into your own logger and export.


### Platform Support
| Method                     | Android | iOS  | macOS  | Windows  | Linux  | Web   |
|----------------------------|---------|------|--------|----------|--------|-------|
| `Metadata`                 | ✅      | ✅  | ✅     | ✅      | ⚠️     | ✅   |
| `Thumbnails`               | ✅      | ✅  | ✅     | ❌      | ❌     | ✅   |
| `KeyFrames`                | ✅      | ✅  | ✅     | ❌      | ❌     | ✅   |
| `Rotate`                   | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Flip`                     | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Crop`                     | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Scale`                    | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Trim`                     | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Playback-Speed`           | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Remove-Audio`             | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Overlay Layers`           | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Timed Image Layers`       | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Layer Animations`          | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Clip Transitions`          | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Layer Size`                | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Multiple ColorMatrix 4x5` | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Cancel export task`       | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Blur background`          | 🧪      | 🧪  | 🧪     | ❌      | ❌     | 🚫   |
| `Custom Audio Tracks`      | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Merge Videos`             | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Stop-Motion (Images→Video)`| ✅     | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Extract Audio`            | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Waveform`                 | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Waveform Streaming`       | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Streaming Optimization`   | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Censor-Layers "Pixelate"` | ❌      | ❌  | ❌     | ❌      | ❌     | 🚫   |



#### Legend
- ✅ Supported with Native-Code 
- ⚠️ Supported with Native-Code but not tested
- 🧪 Supported but visual output can differs from Flutter
- ❌ Not supported but planned
- 🚫 Not supported and not planned

## Setup

#### Android, iOS, macOS, Linux, Windows, Web

No additional setup required.

## Usage

#### Basic Example
```dart
var data = VideoRenderData(
    videoSegments: [
        VideoSegment(
            video: EditorVideo.asset('assets/my-video.mp4'),
            // video: EditorVideo.file(File('/path/to/video.mp4')),
            // video: EditorVideo.network('https://example.com/video.mp4'),
            // video: EditorVideo.memory(videoBytes),
        ),
    ],
    enableAudio: false,
    startTime: const Duration(seconds: 5),
    endTime: const Duration(seconds: 20),
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// If you're rendering larger videos, it's better to write them directly to a file
/// instead of returning them as a Uint8List, as this can overload your RAM.
///
/// final directory = await getTemporaryDirectory();
/// String outputPath = '${directory.path}/my_video.mp4';
///
/// await ProVideoEditor.instance.renderVideoToFile('${directory.path}/my_video.mp4', data);

/// Listen progress
StreamBuilder<ProgressModel>(
    stream: ProVideoEditor.instance.progressStream,
    builder: (context, snapshot) {
      var progress = snapshot.data?.progress ?? 0;
      return CircularProgressIndicator(value: animatedValue);
    }
)
```

#### Quality Preset Example
```dart
/// Use quality presets for simplified video export configuration
/// Available presets: ultra4K, k4, p1080High, p1080, p720High, p720, p480, low, custom
var data = VideoRenderData.withQualityPreset(
    videoSegments: [
        VideoSegment(video: EditorVideo.asset('assets/my-video.mp4')),
    ],
    qualityPreset: VideoQualityPreset.p1080,  // 1080p at 8 Mbps
    startTime: const Duration(seconds: 5),
    endTime: const Duration(seconds: 20),
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// Override the preset's bitrate if needed
var customData = VideoRenderData.withQualityPreset(
    videoSegments: [
        VideoSegment(video: EditorVideo.asset('assets/my-video.mp4')),
    ],
    qualityPreset: VideoQualityPreset.p720,
    bitrateOverride: 5000000,  // 5 Mbps instead of default 3 Mbps
);
```

#### Merge Videos Example
```dart
/// Concatenate multiple video clips into a single output video
/// Each clip can have its own trim settings (startTime/endTime)
var data = VideoRenderData(
    videoSegments: [
        VideoSegment(
            video: EditorVideo.file(File('/path/to/video1.mp4')),
            startTime: Duration(seconds: 0),
            endTime: Duration(seconds: 5),
        ),
        VideoSegment(
            video: EditorVideo.file(File('/path/to/video2.mp4')),
            startTime: Duration(seconds: 2),
            endTime: Duration(seconds: 8),
        ),
        VideoSegment(
            video: EditorVideo.asset('assets/video3.mp4'),
            // No trim - uses full video duration
        ),
    ],
    outputFormat: VideoOutputFormat.mp4,
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// Note: You must use either 'video' (single video) OR 'videoSegments' (multiple videos),
/// but not both. The clips will be joined in the order they appear in the list.
```

#### Stop-Motion Example
```dart
/// Turn a sequence of still images into a video.
/// Each frame is held for 1 / frameRate seconds, unless a per-frame
/// duration is provided.
var data = StopMotionRenderData(
    frames: [
        StopMotionFrame(image: EditorLayerImage.file(File('/path/to/frame1.png'))),
        StopMotionFrame(image: EditorLayerImage.file(File('/path/to/frame2.png'))),
        StopMotionFrame(
            image: EditorLayerImage.memory(frame3Bytes),
            duration: const Duration(milliseconds: 500), // hold this frame longer
        ),
    ],
    frameRate: 12,                  // default frame duration = 1/12s
    fit: StopMotionFit.contain,     // contain | cover | stretch
    // resolution: Size(1080, 1920), // optional, defaults to the first frame size
);

Uint8List result = await ProVideoEditor.instance.renderStopMotion(data);

/// For long sequences, write directly to a file to avoid high memory usage:
/// await ProVideoEditor.instance.renderStopMotionToFile(outputPath, data);

/// The stop-motion output is silent. To add background music, pass the result
/// through renderVideo with `audioTracks`.
```

#### Reverse Video Example
```dart
/// Render a segment backwards by setting reverseVideo to true.
/// Other segments keep their original direction.
var data = VideoRenderData(
    videoSegments: [
        VideoSegment(
            video: EditorVideo.file(File('/path/to/clip.mp4')),
            reverseVideo: true,
        ),
    ],
    outputFormat: VideoOutputFormat.mp4,
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);
```

#### Clip Transitions Example
```dart
/// Add a transition between adjacent clips via `VideoSegment.transition`.
/// The transition describes how a clip moves into the NEXT clip and is
/// ignored on the last segment.
///
/// Overlap transitions (dissolve, slide, push, wipe) blend the two clips and
/// shorten the total output by the transition duration. Dip transitions
/// (fadeToBlack, fadeToWhite) dip through a color and keep the duration.
var data = VideoRenderData(
    videoSegments: [
        VideoSegment(
            video: EditorVideo.asset('assets/clip-a.mp4'),
            endTime: const Duration(seconds: 5),
            transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: Duration(milliseconds: 800),
                curve: AnimationCurve.easeInOut,
            ),
        ),
        VideoSegment(
            video: EditorVideo.asset('assets/clip-b.mp4'),
            // A directional transition (slide / push / wipe) uses `direction`.
            transition: const ClipTransition(
                type: ClipTransitionType.wipe,
                duration: Duration(milliseconds: 700),
                direction: ClipTransitionDirection.right,
            ),
        ),
        VideoSegment(video: EditorVideo.asset('assets/clip-c.mp4')),
    ],
    outputFormat: VideoOutputFormat.mp4,
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// Note: overlap transitions require the neighbouring clips to share the same
/// dimensions (split clips from one source always do); otherwise the boundary
/// falls back to a hard cut.
```

#### Composition (Layers) Example
```dart
/// While `videoSegments` concatenates clips into ONE track, a `VideoComposition`
/// stacks several tracks (layers) on a fixed canvas so they overlap in time and
/// space — picture-in-picture, side-by-side, grids, etc.
///
/// Layers are composited bottom-to-top (the last layer is drawn on top). Each
/// layer is placed via `transform` (or per-clip `VideoSegment.transform`) and
/// can have its own `opacity`. Uncovered areas show `backgroundColor`.
var data = VideoRenderData(
    composition: VideoComposition(
        canvasSize: const Size(1080, 1920),
        backgroundColor: const Color(0xFF000000),
        layers: [
            // Bottom layer: full-canvas background video.
            VideoLayer(
                clips: [VideoSegment(video: EditorVideo.asset('assets/main.mp4'))],
            ),
            // Top layer: a picture-in-picture overlay, muted, top-right.
            VideoLayer(
                opacity: 1.0,
                transform: const SegmentTransform(
                    offset: Offset(700, 60),
                    size: Size(320, 568),
                    fit: SegmentFit.cover,
                ),
                clips: [
                    VideoSegment(
                        video: EditorVideo.asset('assets/pip.mp4'),
                        volume: 0,
                        timelineStart: const Duration(seconds: 2), // appears at +2s
                    ),
                ],
            ),
        ],
    ),
    outputFormat: VideoOutputFormat.mp4,
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// Note: provide exactly one of `video`, `videoSegments` or `composition`.
/// Per-clip `transition`, `playbackSpeed` and `reverseVideo` are not applied
/// inside a composition — use `videoSegments` if you need those.
```

#### Extract Audio Example

Extract audio track from a video.
Supports MP3, AAC, and M4A formats with optional trimming.
```dart
/// Check if video has audio before extraction (recommended)
final video = EditorVideo.asset('assets/video.mp4');
bool hasAudio = await ProVideoEditor.instance.hasAudioTrack(video);

if (!hasAudio) {
    print('Video has no audio track');
    return;
}

/// Extract with trimming
var config = AudioExtractConfigs(
    video: video,
    format: AudioFormat.aac,
    startTime: Duration(seconds: 10),
    endTime: Duration(seconds: 30),
);

/// Save to file instead of returning as Uint8List
final directory = await getTemporaryDirectory();
String outputPath = '${directory.path}/extracted_audio.mp3';

try {
    await ProVideoEditor.instance.extractAudioToFile(outputPath, config);
} on AudioNoTrackException {
    print('Video has no audio track');
}
/// Alternative read the Uint8List directly like below.
/// Uint8List audioData = await ProVideoEditor.instance.extractAudio(audioConfig);

/// Listen to progress
StreamBuilder<ProgressModel>(
    stream: ProVideoEditor.instance.progressStreamById(config.id),
    builder: (context, snapshot) {
      var progress = snapshot.data?.progress ?? 0;
      return CircularProgressIndicator(value: progress);
    }
)
```

#### Waveform Example

Generate audio waveform data for visualization. Supports multiple resolutions and optional streaming mode for progressive UI updates.

```dart
/// Basic waveform generation
var config = WaveformConfigs(
    video: EditorVideo.asset('assets/video.mp4'),
    resolution: WaveformResolution.medium, // low, medium, high, ultra
);

WaveformData waveform = await ProVideoEditor.instance.getWaveform(config);

print('Samples: ${waveform.sampleCount}');
print('Duration: ${waveform.duration}ms');
print('Stereo: ${waveform.isStereo}');

/// Use the built-in AudioWaveform widget for display
AudioWaveform(
    waveform: waveform,
    style: WaveformStyle(
        height: 100,
        waveColor: Colors.blue,
        backgroundColor: Colors.grey.shade900,
    ),
)

/// Interactive waveform with seek support
AudioWaveform.interactive(
    waveform: waveform,
    currentPosition: currentPosition,
    onSeek: (position) => print('Seek to: $position'),
    style: WaveformStyle(
        height: 120,
    ),
)
```

**Streaming Waveform:**

For long videos, use streaming mode to get progressive updates with animated bars:

```dart
/// The streaming widget handles everything internally - 
/// just provide the config and it manages the stream subscription,
/// chunk accumulation, and animated bar rendering automatically.
AudioWaveform.streaming(
    config: WaveformConfigs(
        video: EditorVideo.asset('assets/long-video.mp4'),
        resolution: WaveformResolution.high,
    ),
    style: WaveformStyle(
        height: 80,
        waveColor: Colors.greenAccent,
        backgroundColor: Colors.black,
    ),
    onComplete: () {
        print('Waveform generation complete!');
    },
)

/// For manual stream handling (advanced usage):
var config = WaveformConfigs(
    video: EditorVideo.asset('assets/long-video.mp4'),
    resolution: WaveformResolution.high,
    chunkSize: 100, // Emit every 100 samples
);

await for (var chunk in ProVideoEditor.instance.getWaveformStream(config)) {
    print('Progress: ${(chunk.progress * 100).toStringAsFixed(0)}%');
    
    if (chunk.isComplete) {
        print('Waveform generation complete!');
    }
}
```

#### Cancel an active render

The cancel API is currently implemented only on **Android, iOS, and macOS**.
On **Windows, Linux, and Web**, `cancel` is not wired up yet, so callers should either:

* gate by platform before calling `cancel`, or
* be prepared to handle a `PlatformException` / `UnimplementedError`.

When you cancel a render started with `renderVideoToFile`, the returned `Future` completes with a **`RenderCanceledException`**. If your UI is awaiting that future directly (instead of using `unawaited`), make sure to catch this exception so you can reset any loading state cleanly rather than treating it as an error.

```dart
final renderModel = VideoRenderData(
  videoSegments: [
    VideoSegment(video: EditorVideo.asset('assets/sample.mp4')),
  ],
);

final outputPath = '${(await getTemporaryDirectory()).path}/video.mp4';

// Start the render. Keep the model.id so you can cancel it later.
final renderFuture = ProVideoEditor.instance.renderVideoToFile(
  outputPath,
  renderModel,
);

// Option 1: fire-and-forget (example app pattern).
unawaited(renderFuture);

// Option 2: if you await directly, handle cancellation:
try {
  await renderFuture;
} on RenderCanceledException {
  // User canceled: reset UI state, do not treat as an error.
}

// ...from a UI callback (Android/iOS/macOS only)
if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
  await ProVideoEditor.instance.cancel(renderModel.id);
}
```

#### Advanced Example
```dart
/// Every option except videoSegments is optional.
var task = VideoRenderData(
    id: 'my-special-task',
    videoSegments: [
        VideoSegment(
            video: EditorVideo.asset('assets/my-video.mp4'),
            volume: 0.7, // Original audio at 70%
            playbackSpeed: 2, // Double speed
        ),
    ],
    imageLayers: [
      ImageLayer(
        image: EditorLayerImage.memory(layerBytes),
        offset: const Offset(100, 50),
        rotation: 45 * pi / 180, // clockwise, in radians (like Transform.rotate)
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 8),
      ),
    ],
    outputFormat: VideoOutputFormat.mp4,
    startTime: const Duration(seconds: 5),
    endTime: const Duration(seconds: 20),
    blur: 10,
    bitrate: 5000000,
    maxFrameRate: 30, // cap output at 30 fps (drops surplus frames)
    enableAudio: false,
    audioTracks: [
      VideoAudioTrack(
        path: customAudioPath,
        volume: 0.3, // Background music at 30%
      ),
    ],
    transform: const ExportTransform(
        flipX: true,
        flipY: true,
        x: 10,
        y: 20,
        width: 300,
        height: 400,
        rotateTurns: 3,
        scaleX: .5,
        scaleY: .5,
    ),
    colorFilters: [
         ColorFilter(matrix: [ 1.0, 0.0, 0.0, 0.0, 50.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 ]),
         ColorFilter(matrix: [ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 ]),
    ],
);

Uint8List result = await ProVideoEditor.instance.renderVideo(task);

/// Note: Blur is an experimental feature (🧪 in platform matrix)
/// The blur effect may render differently than in Flutter's preview.

/// Listen progress
StreamBuilder<ProgressModel>(
    stream: ProVideoEditor.instance.progressStreamById(task.id),
    builder: (context, snapshot) {
      var progress = snapshot.data?.progress ?? 0;
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: progress),
        duration: const Duration(milliseconds: 300),
        builder: (context, animatedValue, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.start,
            spacing: 10,
            children: [
              CircularProgressIndicator(value: animatedValue),
              Text(
                '${(animatedValue * 100).toStringAsFixed(1)} / 100',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              )
            ],
          );
        });
    }
)
```

#### Editor Example
The video editor requires the use of the [pro_image_editor](https://github.com/hm21/pro_image_editor). You can find the basic video editor example [here](https://github.com/hm21/pro_video_editor/blob/stable/example/lib/features/editor/pages/video_editor_basic_example_page.dart) and the "grounded" design example [here](https://github.com/hm21/pro_video_editor/blob/stable/example/lib/features/editor/pages/video_editor_grounded_example_page.dart).

You can also use other prebuilt designs from pro_image_editor, such as the WhatsApp or Frosted Glass design. Just check the examples in pro_image_editor to see how it's done.

---

### API Reference

#### VideoSegment
Represents a video clip segment for merging multiple videos.

```dart
VideoSegment({
  required EditorVideo video,    // Video source (file, asset, network, memory)
  Duration? startTime,           // Optional: Start time for trimming
  Duration? endTime,             // Optional: End time for trimming
  double? volume,                // Optional: Per-clip volume multiplier
  double? playbackSpeed,         // Optional: Per-clip playback speed
  bool reverseVideo = false,     // Optional: Play this clip backwards
  ClipTransition? transition,    // Optional: Transition into the NEXT clip
})
```

**Parameters:**
- `video` (required): The video source using `EditorVideo.file()`, `EditorVideo.asset()`, `EditorVideo.network()`, or `EditorVideo.memory()`.
- `startTime` (optional): The starting point for this clip. If omitted, starts from the beginning (0:00).
- `endTime` (optional): The ending point for this clip. If omitted, uses the full video duration.
- `volume` (optional): Per-clip audio volume multiplier (`0.0` = mute, `1.0` = original).
- `playbackSpeed` (optional): Per-clip playback speed (e.g. `0.5` = half, `2.0` = double).
- `reverseVideo` (optional): Renders this clip backwards when `true`.
- `transition` (optional): A `ClipTransition` describing how this clip transitions into the **next** clip (dissolve, fade-to-black, slide, etc.). Ignored on the last segment.

**Usage Example:**
```dart
// Full video
VideoSegment(video: EditorVideo.asset('video.mp4'))

// Trimmed video (5s to 10s)
VideoSegment(
  video: EditorVideo.file(File('video.mp4')),
  startTime: Duration(seconds: 5),
  endTime: Duration(seconds: 10),
)
```

---

#### Metadata Example
```dart
VideoMetadata result = await ProVideoEditor.instance.getMetadata(
    video: EditorVideo.asset('assets/my-video.mp4'),
);
```

#### Thumbnails Example

```dart
List<Uint8List> result = await ProVideoEditor.instance.getThumbnails(
    ThumbnailConfigs(
        video: EditorVideo.asset('assets/my-video.mp4'),
        outputFormat: ThumbnailFormat.jpeg,
        timestamps: const [
            Duration(seconds: 10),
            Duration(seconds: 15),
            Duration(seconds: 22),
        ],
        outputSize: const Size(200, 200),
        boxFit: ThumbnailBoxFit.cover,
    ),
);
```

#### Keyframes Example

```dart
List<Uint8List> result = await ProVideoEditor.instance.getKeyFrames(
    KeyFramesConfigs(
        video: EditorVideo.asset('assets/my-video.mp4'),
        outputFormat: ThumbnailFormat.jpeg,
        maxOutputFrames: 20,
        outputSize: const Size(200, 200),
        boxFit: ThumbnailBoxFit.cover,
    ),
);
```

#### Native Log Level Example

Control native log verbosity per API call on Android, iOS, and macOS.

```dart
/// Silence all native logs for this call
List<Uint8List> thumbnails = await ProVideoEditor.instance.getThumbnails(
    ThumbnailConfigs(
        video: EditorVideo.asset('assets/my-video.mp4'),
        outputSize: const Size(200, 200),
        timestamps: const [Duration(seconds: 5)],
    ),
    nativeLogLevel: NativeLogLevel.none,
);

/// Show only errors
VideoMetadata metadata = await ProVideoEditor.instance.getMetadata(
    video: EditorVideo.asset('assets/my-video.mp4'),
    nativeLogLevel: NativeLogLevel.error,
);

/// Available levels: none, error, warning, info, debug, verbose
```

#### Native Log Stream Example

Capture native logs (including the renderer diagnostics) in Dart so you can
forward them to your own logger and let users export them. The stream emits a
`NativeLogEntry` for every native log on Android, iOS, and macOS, gated by the
`nativeLogLevel` you pass to the operation. On Web, Windows, and Linux the
stream stays empty.

```dart
final subscription = ProVideoEditor.instance.logStream.listen((entry) {
    // entry: level, tag, message, timestamp, optional stackTrace
    myLogger.log(entry.level.name, entry.message,
        tag: entry.tag, stackTrace: entry.stackTrace);
});

// Emit the rich renderer logs by raising the level for the call.
await ProVideoEditor.instance.renderVideoToFile(
    outputPath,
    renderData,
    nativeLogLevel: NativeLogLevel.debug,
);

// Cancel when no longer needed.
await subscription.cancel();
```


## Sponsors 
<p align="center">
  <a href="https://github.com/sponsors/hm21">
    <img src='https://raw.githubusercontent.com/hm21/sponsors/main/sponsorkit/sponsors.svg'/>
  </a>
</p>

## Included Packages

A big thanks to the authors of these amazing packages.

- Packages created by the Dart team:
  - [http](https://pub.dev/packages/http)
  - [mime](https://pub.dev/packages/mime)
  - [plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface)
  - [web](https://pub.dev/packages/web)


## Contributors
<a href="https://github.com/hm21/pro_video_editor/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=hm21/pro_video_editor" />
</a>

Made with [contrib.rocks](https://contrib.rocks).
