## 1.2.1
- **CHORE**: Adjusted code style to comply with lint rules.

## 1.2.0
- **FEAT**(android, iOS, macOS): Add `hasAudioTrack` method to check if a video contains an audio track before attempting extraction.
- **FEAT**(android, iOS, macOS): Add `NO_AUDIO` error code and `AudioNoTrackException` for better error handling when videos have no audio track during extraction.

## 1.1.0
- **FEAT**(android, iOS, macOS): Add audio extraction feature with `extractAudio` and `extractAudioToFile` methods. Supports MP3, AAC, and M4A formats with optional trimming and bitrate configuration.

## 1.0.0
- **FEAT**(android, iOS, macOS): Add video concatenation with `videoClips` parameter for merging multiple videos.
- **FEAT**(android, iOS, macOS): Add audio mixing with `customAudioPath`, `originalAudioVolume`, and `customAudioVolume` parameters for enhanced audio control.
- **FEAT**(android, iOS, macOS): Add `jpegQuality` parameter to `ThumbnailConfigs` which allows setting the JPEG quality for thumbnails.
- **BREAKING** refactor(video_model): Rename `RenderVideoModel` to `VideoRenderData`.

## 0.4.0
- **FEAT**(android, iOS, macOS): Add `ProVideoEditor.instance.cancel(taskId)` for cancelling started export tasks.

## 0.3.0
- **FEAT**(presets): Add video quality presets for simplified export configuration. Details in PR [#55](https://github.com/hm21/pro_video_editor/pull/55).

## 0.2.4
- **CHORE**(android): Update Media3 dependencies to version 1.8.0.

## 0.2.3
- **FIX**(windows): Resolve issue of crashing when reading metadata on Windows.

## 0.2.2
- **FEAT**(metadata): Add `originalResolution` to metadata and auto-correct `resolution` based on video orientation.

## 0.2.1
- **FIX**(android): Resolved issue where metadata returned incorrect resolution for rotated videos. This resolves issue [#42](https://github.com/hm21/pro_video_editor/issues/42).

## 0.2.0
- **FEAT**: Add `renderVideoToFile` to return the file path instead of a Uint8List, preventing RAM overload on older devices or when handling larger videos.

## 0.1.8
- **FIX**(android): Fixed crash during video export when applying overlay effects. The issue was caused by using `ImmutableList.of(bitmapOverlay)` instead of a Kotlin-compatible list. This has been resolved by using `listOf(bitmapOverlay)` instead.
- **CHORE**(android): Updated `media3` dependencies to the latest stable versions for better compatibility and stability.

## 0.1.7
- **FIX**(iOS, macOS): Resolved a crash that occurred when setting playback speed below 1x. This resolves issue [#29](https://github.com/hm21/pro_video_editor/issues/29).

## 0.1.6
- **FIX**(iOS, macOS): Fixed rotation transforms not properly swapping render dimensions for 90°/270° rotations, resolving squeezed video output with black bars.

## 0.1.5
- **FIX**(window, linux, iOS, macOS): Correct bitrate extraction from metadata. 
- **FIX**(android): Remove unsupported WebM output format; Android only supports MP4 generation. 
- **TEST**: Add integration tests for all core functionalities.

## 0.1.4
- **FIX**(iOS, macOS): Fixed AVFoundation -11841 "Operation Stopped" errors when exporting videos selected via image_picker package
- **FIX**(iOS, macOS): Fixed video rotation metadata not being properly handled, causing incorrect orientation in exported videos
- **FIX**(iOS, macOS): Fixed random video loading failures from image_picker package due to complex transform metadata
- **FIX**(iOS, macOS): Enhanced video composition pipeline to properly process iPhone camera orientation transforms

## 0.1.3
- **FIX**(iOS, macOS): Resolved multiple issue where, in some Swift versions, a trailing comma in the constructor caused an error.

## 0.1.2
- **FIX**(iOS, macOS): Resolved an issue where, in some Swift versions, a trailing comma in the constructor caused an error.

## 0.1.1
- **DOCS**: Updated README with new examples and images.

## 0.1.0* 
- **FEAT**(iOS): Added render functions for iOS.
- **FEAT**(macOS): Added render functions for macOS.

## 0.0.14
- **FIX**: Resolve various crop and rotation issues.
- **REFACTOR**(android): Improve code quality.
- **FEAT**(example): Add video-editor example.

## 0.0.13
- **FIX**(crop): Resolve issues that crop not working.

## 0.0.12
- **FIX**(layer): Fixed incorrect layer scaling caused by misinterpreted video dimensions.

## 0.0.11
- **FIX**(rotation): Resolve various issues when video is rotated.

## 0.0.10
- **FEAT**(native-code): Remove the ffmpeg package and start implementing native code.

## 0.0.9
- **REFACTOR**(encoding): Export encoding models for easier import from main package

## 0.0.8
- **FEAT**(audio): Add enable audio parameter

## 0.0.7
- **FEAT**(iOS, macOS): Add video generation support for macOS and iOS

## 0.0.6
- **FIX**(crop): Ensure crop dimensions are even to avoid libx264 errors

## 0.0.5
- **FEAT**: Add support for color 4x5 matrices

## 0.0.4
- **FEAT**: Add video parser functions for android

## 0.0.3
- **FIX**: Resolve thumbnail generation on web.

## 0.0.2
- **FEAT**: Add `getVideoInformation` and `createVideoThumbnails` for all platforms.

## 0.0.1

- **CHORE**: Initial release.
