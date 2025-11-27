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
- ⏩ **Playback Speed**: Adjust the playback speed of the video.
- 🔇 **Mute Audio**: Remove or mute the audio track from the video.

#### 🔧 **Transformations**
- ✂️ Crop by `x`, `y`, `width`, and `height`
- 🔁 Flip horizontally and/or vertically
- 🔄 Rotate by 90deg turns
- 🔍 Scale to a custom size

#### 🎨 **Visual Effects**
- 🖼️ **Layers**: Overlay a image like a text or drawings on the video.
- 🧮 **Color Matrix**: Apply one or multiple 4x5 color matrices (e.g., for filters).
- 💧 **Blur**: Add a blur effect to the video.
- 📡 **Bitrate**: Set a custom video bitrate. If constant bitrate (CBR) isn't supported, it will gracefully fall back to the next available mode.

#### 📱 **Runtime Features**
- 📊 **Progress**: Track the progress of one or multiple running tasks.
- 🧵 **Multi-Tasking**: Execute multiple video processing tasks concurrently.


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
| `Multiple ColorMatrix 4x5` | ✅      | ✅  | ✅     | ❌      | ❌     | 🚫   |
| `Blur background`          | 🧪      | 🧪  | 🧪     | ❌      | ❌     | 🚫   |
| `Custom Audio Tracks`      | ❌      | ❌  | ❌     | ❌      | ❌     | 🚫   |
| `Merge Videos`             | ❌      | ❌  | ❌     | ❌      | ❌     | 🚫   |
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
var data = RenderVideoModel(
    video: EditorVideo.asset('assets/my-video.mp4'),
    // video: EditorVideo.file(File('/path/to/video.mp4')),
    // video: EditorVideo.network('https://example.com/video.mp4'),
    // video: EditorVideo.memory(videoBytes),
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

var data = RenderVideoModel.withQualityPreset(
    video: EditorVideo.asset('assets/my-video.mp4'),
    qualityPreset: VideoQualityPreset.p1080,  // 1080p at 8 Mbps
    startTime: const Duration(seconds: 5),
    endTime: const Duration(seconds: 20),
);

Uint8List result = await ProVideoEditor.instance.renderVideo(data);

/// Override the preset's bitrate if needed
var customData = RenderVideoModel.withQualityPreset(
    video: EditorVideo.asset('assets/my-video.mp4'),
    qualityPreset: VideoQualityPreset.p720,
    bitrateOverride: 5000000,  // 5 Mbps instead of default 3 Mbps
);
```

#### Cancel an active render

```dart
final renderModel = RenderVideoModel(
  video: EditorVideo.asset('assets/sample.mp4'),
);

final outputPath = '${(await getTemporaryDirectory()).path}/video.mp4';

// Start the render. Keep the model.id so you can cancel it later.
unawaited(
  ProVideoEditor.instance.renderVideoToFile(outputPath, renderModel),
);

// ...from a UI callback
await ProVideoEditor.instance.cancel(renderModel.id);
```


#### Advanced Example
```dart
/// Every option except videoBytes is optional.
var task = RenderVideoModel(
    id: 'my-special-task'
    video: EditorVideo.asset('assets/my-video.mp4'),
    imageBytes: imageBytes, /// A image "Layer" which will overlay the video.
    outputFormat: VideoOutputFormat.mp4,
    enableAudio: false,
    playbackSpeed: 2,
    startTime: const Duration(seconds: 5),
    endTime: const Duration(seconds: 20),
    blur: 10,
    bitrate: 5000000,
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
    colorMatrixList: [
         [ 1.0, 0.0, 0.0, 0.0, 50.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 ],
         [ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 ],
    ],
);

Uint8List result = await ProVideoEditor.instance.renderVideo(task);

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
