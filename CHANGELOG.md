## 2.7.0
- **PERF**(iOS, macOS): Splitting without an explicit `bitrate` now stream-copies both halves (passthrough export, frame-accurate via a container edit list) instead of re-encoding them. Measured on an M-series Mac: 29.5s 720p H.264 404ms → 32ms, 5s 10-bit HEVC 793ms → 13ms, 32s 4K60 14.3s → 0.12s. This also fixes two quality losses of the old re-encode: 60fps sources no longer drop to 30fps, and HEVC/HDR sources are no longer converted to 8-bit H.264. An explicit `bitrate`/`qualityConfig` re-encodes as before; a source that cannot be stream-copied falls back to the re-encode automatically.
- **PERF**(android): A split without an explicit `bitrate` now transmuxes both halves losslessly (Media3 edit-list trim: the mid-GOP half keeps samples from the preceding keyframe and an MP4 edit list gates playback at the exact cut — frame-accuracy verified pixel-exact against the plugin's own thumbnail/metadata pipelines). Measured on a Galaxy S26: 32s 4K60 8.6s → 1.2s, 5s 10-bit HEVC 724ms → 290ms, 29.5s 720p H.264 1.4s → 1.0s. The halves no longer lose quality and HEVC/HDR no longer converts to 8-bit H.264. An out-of-range split position is now validated explicitly up front (same `PlatformException` as before, since a transmux — unlike the old transcode — would not fail on its own).
- **FIX**(iOS, macOS): The export watchdog now fires reliably for bounds tighter than its 250ms poll interval, and a stall/timeout is no longer misreported as a cancellation when the force-cancelled export happens to finish the race first.

## 2.6.0
- **FIX**(android, iOS, macOS): Concurrent split and render re-encodes no longer contend for the hardware encoder. They share a process-wide gate so only one runs at a time; previously they starved each other on the shared encoder pool — measured, three concurrent 4K re-encodes each took ~43s versus ~19s alone — and on a throttled device a starved session could sit at 0% until the watchdog (the reported split freeze). Each encode now runs at its solo speed, and the wait is queued *before* the watchdog starts, so it never counts as a stall. Passthrough/stream-copy exports (no encoder) stay ungated.
- **FEAT**(android, iOS, macOS): Split and render exports are guarded by a stall watchdog: an encode that makes no forward progress for `stallTimeout` (split default 12s) is force-cancelled with a diagnostic reason instead of hanging — e.g. `Split export stalled after 12s with no progress [half=end progress=0.00 segment=0.52s split=0.53s total=1.05s preset=… audio=false]` (`preset` on iOS/macOS, `mime` on Android). A wedged encode therefore releases its gate slot instead of deadlocking later exports. `exportTimeout` (hard bound) and `stallTimeout` (inner bound) are tunable on `SplitVideoModel` (`stallTimeout` must be `< exportTimeout`); successful exports are unaffected.

## 2.5.1
- **FIX**(iOS, macOS): Loading many clips no longer freezes the editor. A thumbnail decoder race (out-of-order callbacks seen on iOS 26.5) could hang `getThumbnails` forever or map frames to the wrong timestamps; frames now stay index-aligned with their requested timestamps and the call always completes.

## 2.5.0
- **FEAT**(android, iOS, macOS): A `ClipTransition` on the **last (or only)** `VideoSegment` now wraps back into the first segment, so a single-track render loops seamlessly — e.g. a `dissolve` on one segment cross-dissolves on restart. Overlap types (dissolve/slide/push/wipe) shorten the output by the transition duration and require a single clip longer than 2× the duration (otherwise the wrap is skipped); dip types (fadeToBlack/fadeToWhite) keep the length and dip through the color at the seam. Previously a transition on the last segment was silently ignored.

## 2.4.0
- **FIX**(android, iOS, macOS): The render `bitrate` is now enforced as a real maximum instead of being silently ignored (Android transmuxed the source untouched; iOS/macOS picked an `AVAssetExportSession` preset with its own bitrate). A source above the cap is re-encoded down to it, a source already within it keeps a lossless fast path (transmux / passthrough), and a `null` bitrate is unchanged. Note: an over-cap source that used to export losslessly is now re-encoded.

## 2.3.0
- **CHORE**(android): Migrate the Android module to Flutter's built-in Kotlin (drop the manual Kotlin Gradle Plugin apply) so the plugin no longer triggers the KGP deprecation warning and stays AGP 9+ compatible. Now requires Flutter 3.44+.

## 2.2.4
- **FIX**(android, iOS, macOS): Stop-motion render progress now advances smoothly instead of sitting near 0% and snapping to 100% at the end. Media3's image-to-video export reports no intra-export progress on Android, so the encode phase is now driven by a smooth, monotonic time-based estimate (using the real value when available); Darwin reports 100% only after the writer finishes so the finalize step stays visible.

## 2.2.3
- **PERF**(android): Timestamp thumbnails (`getThumbnails`) are now extracted with up to three parallel hardware decoders that each decode forward through a contiguous timeline chunk (every GOP decoded at most once), with frames GPU-scaled straight to the thumbnail size — instead of one software `MediaMetadataRetriever` per timestamp. Measured on a Galaxy S26: 20 timeline thumbnails from a 720p H.264 video 2.8s → 0.64s (~4x), 10 from a 1080p 10-bit HEVC video 6.2s → 0.3s (~20x), 14 from a 6s 4K60 HEVC clip 3.6s → 1.3s (~3x), with roughly 3-4x less CPU overall. Extraction keeps its speed while the UI is actively rendering (batch-mode decoder hints, non-blocking pump at display priority). Frame positions are unchanged (still the closest frame) and HDR10/rotation are handled by the GPU. Falls back to Media3 `FrameExtractor`, then to the previous retriever path when a video can't be decoded in hardware.

## 2.2.2
- **FIX**(android, iOS, macOS): Layer `animateOut` / `animateInOut` animations now play for layers that run until the end of the video (`endTime` unset). An open-ended layer's end previously resolved to "infinity", so the out-phase never triggered and the layer popped off at the last frame; it now resolves to the composition length, so the layer animates out. Only layers carrying an out-phase animation are affected.
- **FIX**(iOS, macOS): Smoother clip transitions. The pre-rendered transition clip is now authored at the composition's frame rate (`max(30, source fps)`) instead of only the outgoing clip's, so a 25 fps source no longer stutters at the transition seams; directional `slide` / `push` transitions also use one easing ramp per output frame, removing velocity kinks with `bounce` / `elastic` curves.

## 2.2.1
- **FIX**(iOS, macOS): Fix a layer sliding in from an edge briefly shifting and shrinking the video (e.g. a black bar at the top) when a custom output resolution is set. Off-frame overlay content is now clipped to the video frame before letterboxing, so the frame no longer inflates during the animation.

## 2.2.0
- **FEAT**(android, iOS, macOS): Add `ProVideoEditor.splitVideo` — a frame-accurate split that cuts one video into two files (`SplitVideoModel`). Each half is re-encoded from the exact cut frame without the render compositor/effects, making it far faster and more stall-resistant than splitting via `renderVideoToFile`; every export is guarded by a watchdog timeout. Cancellable and progress-reporting via the task `id`. Web/Windows/Linux throw `UnimplementedError`.

## 2.1.3
- **FIX**(iOS, macOS): Make FlutterEngine detach terminal for method-channel result delivery. After detach, a late render/audio/waveform/metadata/thumbnail callback no longer calls a captured `FlutterResult` against a torn-down engine, closing the remaining `NSInternalInconsistencyException: Sending a message before the FlutterEngine has been run` path from 2.1.2.

## 2.1.2
- **FIX**(iOS, macOS): Cancel active tasks and clear event sinks when the FlutterEngine is torn down. In-flight render/audio/waveform callbacks no longer message a stopped engine, fixing `NSInternalInconsistencyException: Sending a message before the FlutterEngine has been run` crashes on app termination or surface recreation.

## 2.1.1
- **FIX**(android): The global output trim now respects per-clip and global `playbackSpeed`. A sped-up composition capped by `endTime` was trimmed against the source timeline, cutting the output far shorter than the preview; the cap now limits the post-speed output length, matching iOS.

## 2.1.0
- **FIX**(android, iOS, macOS): `VideoQualityConfig.custom(resolution: …)` now renders to exactly that resolution. The video is scaled to fit (preserving aspect ratio), centered, and padded with black instead of producing an aspect-scaled size (e.g. a 720x720 source with a 1080x1920 resolution previously exported 1080x1080, now 1080x1920 letterboxed). Android letterboxes with a `Presentation` effect; Darwin composites the frame onto a black canvas. Quality presets keep their aspect-preserving scale. A `qualityConfig`'s `bitrate` is now also applied when used without an explicit `bitrate`.
- **FEAT**(android, iOS, macOS): Animated GIF image layers. `ImageLayer` now detects animated GIFs automatically and plays them back frame by frame; the new `loop` flag (default `true`) repeats the animation for the layer's time range or holds the last frame when `false`. All existing layer properties (position, size, rotation, timing, animations) apply unchanged. Android decodes frames via `Movie` and swaps them per overlay frame; Darwin decodes via `CGImageSource` and selects the frame per composition time. Web/Windows/Linux ignore the field.
- **FEAT**(android, iOS, macOS): Add an output frame-rate cap via a new `maxFrameRate` field on `VideoRenderData`. It is an upper limit, not a target: a faster source is reduced to it (e.g. 60→30 fps) while a slower source is left untouched, lowering encoding cost and output file size. Android drops surplus frames with Media3's `FrameDropEffect`; Darwin caps the composition `frameDuration`. Web/Windows/Linux ignore the field.
- **FEAT**(android, iOS, macOS): Add per-layer rotation to image overlays via a new `rotation` field on `ImageLayer` (radians, clockwise around the layer center — matches Flutter's `Transform.rotate`, so a `pro_image_editor` layer rotation can be forwarded directly). `offset`/`size` keep describing the layout box before rotation. Web/Windows/Linux ignore the field.

## 2.0.0
- **BREAKING**: Remove the previously deprecated APIs. Migrate as follows:
  - `VideoRenderData.video` → `videoSegments: [VideoSegment(video: …)]`
  - `VideoRenderData.imageBytes` → `imageLayers`
  - `VideoRenderData.playbackSpeed` → `VideoSegment.playbackSpeed`
  - `VideoRenderData.colorMatrixList` → `colorFilters` (`ColorFilter`)
  - `VideoRenderData.customAudioPath` / `customAudioStartTime` / `customAudioVolume` / `loopCustomAudio` → `audioTracks` (`VideoAudioTrack`)
  - `VideoRenderData.originalAudioVolume` → `VideoSegment.volume`
  - `VideoMetadata.originalResolution` → `rawResolution`

## 1.22.0
- **FEAT**(android, iOS, macOS): Add multi-layer video compositions via a new `composition` field on `VideoRenderData` (`VideoComposition`). A composition stacks several `VideoLayer`s on a fixed-size canvas, each layer being a time-ordered track of `VideoSegment`s composited bottom-to-top with its own `opacity` and placement (`SegmentTransform`: `offset`, `size`, `fit` = `fill`/`contain`/`cover`). Clips gain `timelineStart` (delayed entry on a layer) and `transform` (per-clip placement), enabling picture-in-picture, side-by-side and grid layouts over a configurable `backgroundColor`. Android composites layered Media3 sequences with a per-clip GL transform (cover overflow is scissored to its rect); Darwin uses a custom `AVVideoCompositing` compositor. Per-clip `transition`, `playbackSpeed` and `reverseVideo` are not applied inside a composition. Web/Windows/Linux ignore the field.

## 1.21.5
- **FIX**(android): Fix video export failing with a codec exception on Qualcomm `c2.qti.*` encoders. The encoder is now retried through a fallback chain (operating-rate cap → unset → Main/Baseline profile → software) before surfacing a typed `RenderEncoderException`; working devices keep their original export speed.
- **FIX**(android, iOS, macOS): Fix a render/cancel race where cancelling right after starting an export failed with `TASK_NOT_FOUND`. An early cancel is now handled in the Dart layer before the native task starts, so the render resolves as canceled.

## 1.21.4
- **FIX**(android, iOS, macOS): Fix layer `slide` animations only moving the layer by its own size, leaving it partly visible at the animation's start/end. Slides are now edge-aware and carry the layer fully off-screen in the slide direction. Requires the matching `pro_image_editor` release so the in-editor preview matches the export.

## 1.21.3
- **FIX**(android): Fix `OutOfMemoryError` when pre-rendering longer overlap clip transitions (dissolve/slide/push/wipe). Both sides previously decoded every I420 frame into memory at once (~370 MB for a 2 s 1080p30 transition); frames are now spilled to a temp file and streamed back one at a time during encoding, so heap use stays constant regardless of duration/fps/resolution — at full quality.

## 1.21.2
- **FIX**(android, iOS, macOS): Fix per-segment `playbackSpeed` being ignored on clips that take part in an overlap clip transition (dissolve/slide/push/wipe). The transition pre-render now resolves the blend in output (post-speed) time and replays each side at its own speed, so footage inside the transition plays at the requested speed instead of falling back to 1×. Independent per-side speeds are supported; dip transitions (`fadeToBlack`/`fadeToWhite`) already honored speed.

## 1.21.1
- **FIX**(android): Fix overlap clip transitions (dissolve/slide/push/wipe) appearing rotated 90°/180° when a clip carries container rotation metadata (e.g. portrait phone videos). The transition pre-render decodes coded (un-rotated) frames, so it now re-applies the source rotation via `MediaMuxer.setOrientationHint` and maps geometric directions into coded space.

## 1.21.0
- **FEAT**(android, iOS, macOS): Add clip transitions between adjacent `VideoSegment`s via a new `transition` field (`ClipTransition` with `type`, `duration`, `curve`, `direction`). Supports `dissolve`, `slide`, `push` and `wipe` (overlap and shorten the output) plus `fadeToBlack` and `fadeToWhite` (dip through a color, duration unchanged). Web/Windows/Linux ignore the field.

## 1.20.0
- **FEAT**(android, iOS, macOS): Add stop-motion support to turn a sequence of still images into a video via `ProVideoEditor.instance.renderStopMotion` / `renderStopMotionToFile`. Each `StopMotionFrame` is held for `1 / frameRate` seconds (or a per-frame `duration` override) and encoded into a single silent video. The output size defaults to the first frame and frames are mapped onto it via `StopMotionFit` (`contain` / `cover` / `stretch`). Darwin encodes with `AVAssetWriter` + a pixel-buffer adaptor; Android uses Media3 Transformer image input with a `Presentation` effect. Progress and cancellation reuse the existing render task infrastructure. Audio is not mixed in — pass the result through `renderVideo` with `audioTracks` to add music. Web/Windows/Linux are not supported.

## 1.19.1
- **FIX**(iOS, macOS): Fix custom audio tracks being silently dropped when the source asset's duration fails to resolve. `AudioPreRenderer` previously fell back to a zero duration on `asset.load(.duration)` failure, which collapsed an open-ended trim (`audioEndTime == nil`) into a zero-length range and discarded the track with a misleading `invalid trim range … end=0.0s` log. The renderer now loads the audio track first and falls back to its `timeRange` duration (the real audio length), only aborting when neither source resolves. Android already decodes to the real end-of-stream for an open-ended trim, so no change was needed there.

## 1.19.0
- **FEAT**(android, iOS, macOS): Forward native plugin logs back to Dart via `ProVideoEditor.instance.logStream`. Every entry written through the shared native logger (including the full renderer diagnostics) is now emitted as a `NativeLogEntry` (`level`, `tag`, `message`, `timestamp`, optional `stackTrace`), so host apps can pipe these into their own Dart logger and export them. Forwarding is gated by the same `nativeLogLevel` as the native console output. Web/Windows/Linux keep an empty stream.

## 1.18.0
- **FEAT**(android, iOS, macOS): Add `speed` to `AudioExtractConfigs` for pitch-preserving playback-speed changes during audio extraction (e.g. `2.0` for double speed, `0.5` for half). WAV applies the time-stretch directly on the decoded PCM (Android `SonicAudioProcessor`; AVFoundation `AVAssetReaderAudioMixOutput` with the spectral time-pitch algorithm), while compressed formats are re-encoded — Android via a Media3 `Transformer`, Darwin via `AVAssetExportPresetAppleM4A` with a scaled time range. Note: on Apple platforms a non-`1.0` speed re-encodes to AAC/M4A, so `caf` output falls back to M4A content.

## 1.17.6
- **FIX**(iOS, macOS): Fix unstable/glitchy audio on reversed clips inside multi-clip timelines. `AudioReverser` now preserves the source audio format (sample rate and channel count) instead of forcing 44.1 kHz stereo, so a reversed clip's audio matches its untouched neighbours and AVFoundation no longer has to reconcile mixed formats within a single composition audio track during looped playback. The reversed segment is also written as an AVFoundation-authored CAF/PCM file (replacing the hand-authored WAV) and inserted at its decoded duration without padding, avoiding encoder priming artifacts and audio-timing drift in the exported video.

## 1.17.5
- **FIX**(android): Fix custom audio tracks extending sped-up renders to the original source duration. Custom audio is now constrained to the rendered video timeline after global and per-clip playback speed, preventing the final video frame from freezing after the sped-up video content ends.

## 1.17.4
- **FIX**(web, wasm): Fix pub.dev platform compatibility score. Replace direct `dart:io` and `package:path_provider` imports in the package's public import chain with conditional platform shims, eliminating the "Package does not support platform Web" and "Not compatible with runtime wasm" warnings.

## 1.17.3
- **FEAT**(darwin): Add Swift Package Manager (SPM) support for iOS and macOS. The darwin implementation is now distributed as a local SPM package, replacing the previous CocoaPods-only setup.

## 1.17.2
- **FIX**(android): Prevent `RENDER_ERROR` codec exceptions on hardware encoders (e.g. Qualcomm AVC `c2.qti.avc.encoder`) by enabling encoder fallback in the main render path, clamping the requested bitrate into the codec's supported range, and preferring VBR over CBR at high bitrates.
- **FIX**(android): Harden the reverse-video pre-render against crashes. The all-intra encoder is now configured with a clamped bitrate and progressive fallback to avoid `MediaCodec.CodecException`, and the in-memory remux is guarded against `OutOfMemoryError` by checking the temp file size against available heap before loading frames. On failure the clip gracefully degrades to forward playback.

## 1.17.1
- **FIX**(android): Fix reversed HEVC videos ignoring the rotation metadata tag, causing sideways/upside-down output.
- **FIX**(iOS, macOS): Fix `AVErrorInvalidVideoComposition` (Code -11841) during reverse playback. `AudioReverser` produces PCM frames at 44 100 Hz, so the reversed WAV duration (`PCMFrameCount / 44100`) is a few microseconds longer than the video clip duration. This extended `composition.duration` beyond the `AVVideoComposition` instruction coverage. Fixed by clamping the inserted WAV range to `clipDuration` via `CMTimeMinimum`.

## 1.17.0
- **FEAT**(android, iOS, macOS): Add `reverseVideo` flag to `VideoSegment` to play a clip backwards. When `true`, the segment renders from its trimmed end back to its trimmed start while other segments keep their own direction.

## 1.16.3
- **FIX**(linux): Fix Linux build by replacing the unavailable C++ Flutter embedder API (`flutter::EncodableValue`) with the GLib-based `FlValue` API. Update CMakeLists to use GStreamer (`gstreamer-1.0`, `gstreamer-pbutils-1.0`) instead of the unused libavformat/libavcodec/libavutil pkg-config targets. Fix source file extensions (`.cc` instead of `.cpp`).

## 1.16.2
- **FIX**(android, iOS, macOS): Eliminate audible clicks/gaps at custom audio loop boundaries and clip transitions. Each custom audio track is now pre-rendered to a single gap-less PCM WAV file before being inserted into the composition, avoiding AAC encoder frame realignment (Android Media3) and codec priming/padding artifacts (AVFoundation `insertTimeRange` per loop iteration on iOS/macOS). Volume control remains in the mixer layer for post-hoc adjustments without re-decoding.

## 1.16.1
- **FIX**(iOS, macOS): Fix crash `No source tracks available for compositing` when rendering H.264 MP4 files whose container duration slightly exceeds the video track's actual frame duration. The compositor time range is now clamped to the video track's real `timeRange` before inserting into the composition, preventing AVFoundation from requesting frames that have no pixel buffer. A black-frame fallback was also added as a safety net.

## 1.16.0
- **FEAT**(android, iOS, macOS): Add per-clip `playbackSpeed` to `VideoSegment`, allowing each segment in a multi-clip composition to have its own playback speed (e.g. `2.0` for fast-forward, `0.5` for slow-motion).
- **DEPRECATED**: `VideoRenderData.playbackSpeed` is deprecated. Use `VideoSegment.playbackSpeed` instead.

## 1.15.2
- **FIX**(example): Replace deprecated `CompleteParameters.customAudioTrack` usage with `CompleteParameters.audioTracks` in the basic video editor example.

## 1.15.1
- **FIX**(iOS, macOS): Refactor audio extraction to use synchronous file writing for improved stability.

## 1.15.0
- **FEAT**(android, iOS, macOS): Add `NativeLogLevel` parameter to all API methods for controlling native log verbosity per call. Supported levels: `none`, `error`, `warning`, `info`, `debug`, `verbose`.

## 1.14.4
- **FIX**(android): Fix image layers crash on Android by recycling intermediate thumbnail bitmaps.
- **FIX**(android, iOS, macOS): Additional fixes for audio extraction.
- **CHORE**(android): Bump Android `compileSdk` to 36.

## 1.14.3
- **FIX**(iOS, macOS): Resolve crash in `extractToWav()` caused by starting the writer session at `.zero` instead of the actual sample time.

## 1.14.2
- **FIX**(android, iOS, macOS): Correct audio extraction to WAV format in `extractAudioToFile`.

## 1.14.1
- **FIX**(android): Fix compatibility with media3 1.10.0 by replacing removed `ChannelMixingMatrix.create` with `ChannelMixingMatrix.createForConstantGain`.

## 1.14.0
- **FEAT**(android, iOS, macOS, web): Add `getSingleThumbnail` method with `SingleThumbnailConfigs` to extract the first or last frame of a video via `ThumbnailPosition.first` / `ThumbnailPosition.last`.

## 1.13.2
- **FIX**(android): Fix image layer distortion when `imageBytesWithCropping` is enabled with a crop transform and qualityConfigs.

## 1.13.1
- **FIX**: Fix `VideoQualityConfig` stretching video when target resolution has a different aspect ratio. Now uses uniform scaling (BoxFit.contain) to preserve the original aspect ratio.


## 1.13.0
- **FEAT**(android, iOS, macOS): Add optional `size` field on `ImageLayer` to scale overlay images to specific dimensions before rendering.

## 1.12.0
- **FEAT**(android, iOS, macOS): Add layer animations with `LayerAnimation` on `ImageLayer`. Supports fade, slide, and scale animations with `animateIn`, `animateOut`, and `animateInOut` phases. Includes 13 easing curves: linear, easeIn, easeOut, easeInOut, easeInCubic, easeOutCubic, easeInOutCubic, bounceIn, bounceOut, bounceInOut, elasticIn, elasticOut, elasticInOut.
- **FIX**(iOS, macOS): Replace deprecated `AVMutableVideoCompositionLayerInstruction` with `AVVideoCompositionLayerInstruction.Configuration` on macOS 26+ / iOS 26+, with backward-compatible fallback.

## 1.11.0
- **FEAT**(android, iOS, macOS): Add timeline-based color filters via `ColorFilter` with optional `startTime`/`endTime` for applying different filters to specific time ranges.
- **FEAT**(android, iOS, macOS): Add multi-track audio support via `VideoAudioTrack` with per-track volume, loop, and timeline placement (`startTime`, `endTime`, `audioStartTime`, `audioEndTime`).
- **FEAT**(android, iOS, macOS): Add per-clip volume control via `VideoSegment.volume` for adjusting audio levels on individual video segments.
- **FEAT**(android, iOS, macOS): Add `VideoSegment` model replacing single `video` field for concatenating multiple clips with individual trim and volume settings.
- **DEPRECATED**: `video`, `imageBytes`, `colorMatrixList`, `customAudioPath`, `customAudioStartTime`, `customAudioVolume`, `loopCustomAudio`, and `originalAudioVolume` on `VideoRenderData`. Use `videoSegments`, `imageLayers`, `colorFilters`, and `audioTracks` instead.

## 1.10.0
- **FEAT**(android, iOS, macOS): Add time-based image overlay layers. Allows positioning image overlays at specific x/y coordinates with optional start and end times for timed visibility during video rendering.

## 1.9.3
- **FIX**(android, iOS, macOS): Fixed rendering failure with HEVC encoded videos.

## 1.9.2
- **FIX**(all): Fix file write failures when the target directory does not exist. `writeMemoryVideoToFile`, `writeAssetVideoToFile`, and `fetchVideoToFile` now create parent directories recursively before writing.

## 1.9.1
- **FIX**(android): Strip metadata (GPS, title, artist, etc.) from rendered videos. Previously, Android's Media3 Transformer copied all source metadata to the output, while iOS/macOS correctly removed them to protect the privacy from users.

## 1.9.0
- **FEAT**(android, iOS, macOS): Add `gpsCoordinates` to `VideoMetadata` for extracting GPS location from videos.
- **FEAT**(android, iOS, macOS): Add `frameRate` to `VideoMetadata` for extracting video frame rate.
- **FEAT**(iOS, macOS): Add `cameraMake` and `cameraModel` to `VideoMetadata` for extracting camera information.

## 1.8.0
- **FEAT**(android, iOS, macOS): Add `customAudioStartTime` option to `VideoRenderData`. Allows starting the custom audio track from a specific offset instead of from the beginning. Useful for using a specific section of a longer audio file.

## 1.7.0
- **FEAT**(android, iOS, macOS): Add `loopCustomAudio` option to `VideoRenderData`. When `false`, custom audio plays once instead of looping to match the video duration. Defaults to `true` for backward compatibility.

## 1.6.2
- **FIX**(iOS, macOS): Fixed crash when merging multiple MOV video clips on older devices (e.g., iPhone 7, iOS 15). The issue was caused by `AVMutableVideoCompositionInstruction` not properly deriving `requiredSourceTrackIDs` from layer instructions when using a custom video compositor. Introduced `CustomVideoCompositionInstruction` that explicitly provides source track IDs.

## 1.6.1
- **FIX**(iOS, macOS): Fixed video appearing upside down after export due to coordinate system mismatch between AVFoundation (top-left origin) and CIImage (bottom-left origin). The transform is now properly converted between coordinate systems.

## 1.6.0
- **FIX**(iOS, macOS): Fixed portrait mode videos being rotated incorrectly after export. The video rotation was being applied twice (once via layer instruction transform and again via orientation correction), causing portrait videos to appear with incorrect pixel orientation despite correct dimensions.
- **DEPRECATED**(metadata): `originalResolution` is now deprecated. Use `rawResolution` instead.
- **FIX**(android): Video metadata now returns display dimensions (after rotation correction), consistent with iOS/macOS. Previously, Android returned raw dimensions while iOS/macOS returned display dimensions.
- **FEAT**(metadata): Add `rawResolution` getter to retrieve the raw video dimensions before rotation is applied.

## 1.5.2
- **FIX**(iOS, macOS): Fixed color filters (`colorMatrixList`), blur, and flip effects being incorrectly applied to overlay images when `imageBytesWithCropping` is enabled. These effects are now applied only to the video before compositing the overlay.

## 1.5.1
- **FIX**(android): Fixed semi-transparent overlay layers appearing darker than expected during video rendering. The issue was caused by double alpha premultiplication — Android's BitmapFactory produces premultiplied pixels while Media3's overlay shader applies alpha again. Pixel data is now converted to straight alpha before uploading to the GPU.

## 1.5.0
- **FEAT**(android, iOS, macOS): Add `imageBytesWithCropping` option to `VideoRenderData`. When enabled, the image overlay is applied before cropping and gets cropped together with the video instead of being scaled to the final cropped size.

## 1.4.2
- **FIX**(android): Fixed black edges appearing around transparent overlay layers during video rendering by using proper ARGB_8888 bitmap configuration and correct alpha blending.

## 1.4.1
- **FIX**(iOS, macOS): Fix Swift compiler type-check error by breaking up complex bit-shift expression into sub-expressions.

## 1.4.0
- **FEAT**(android, iOS, macOS): Add `shouldOptimizeForNetworkUse` render option to enable progressive streaming by placing moov atom at file start (fast start). Enabled by default.
- **FEAT**(android, iOS, macOS): Add `isOptimizedForStreaming` metadata property to detect if a video has moov before mdat for streaming compatibility.
- **FEAT**(android, iOS, macOS): Add optional `checkStreamingOptimization` parameter to `getMetadata()` for on-demand MP4 atom analysis.

## 1.3.0
- **FEAT**(android, iOS, macOS): Add waveform generation with `getWaveform` method to extract audio peak data for visualization.
- **FEAT**(android, iOS, macOS): Add streaming waveform generation with `getWaveformStream` for progressive real-time waveform display.
- **FEAT**(widgets): Add `AudioWaveform` widget for static waveform visualization with playback position indicator and seek support.
- **FEAT**(widgets): Add `AudioWaveform.streaming` constructor for animated progressive waveform rendering during generation.
- **FEAT**(android, iOS, macOS): Add WAV format support for audio extraction.

## 1.2.3
- **PERF**(android): Improves render performance on Android when mixing with a custom audio track.

## 1.2.2
- **FIX**(trim): Improved global trim precision by adding frame compensation to prevent encoder overshoot.

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
