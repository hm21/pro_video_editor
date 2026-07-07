# Manual Bitrate-Cap Verification (ffprobe)

The render `bitrate` is a guaranteed **maximum**: sources above
`cap × 1.2` are re-encoded down to the cap, sources within it are exported
losslessly over the fast path (Android transmux / Darwin passthrough).

The automated coverage lives in `integration_test/bitrate_cap_test.dart`
(plus the native decision logic in the Android unit test
`BitrateCapPolicyTest.kt`). The steps below verify the same behavior by
hand with `ffprobe` on real output files.

## 1. Render test files

Export two files from the example app (or a small `renderVideoToFile`
snippet) with `bitrate: 8000000` and no edits:

- **Over-cap source:** `assets/hevc.mp4` (~12.5 Mbit/s)
- **Compliant source:** `assets/demo.mp4` (~1.03 Mbit/s)

On Android, pull the outputs with `adb pull`; on macOS they can be written
straight to a local path (note the app sandbox — use the app container or
a user-selected directory).

## 2. Check the video bitrate

```sh
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,bit_rate \
  -show_entries format=bit_rate,duration \
  -of default=noprint_wrappers=1 <output.mp4>
```

Expected:

- **Over-cap output:** `bit_rate` ≤ 9,600,000 (cap × 1.2). Reference run on
  macOS 26: 12.5 Mbit/s HEVC in → 6.8 Mbit/s H.264 out.
- **Compliant output:** `bit_rate` identical to the source video track
  (lossless copy — e.g. `1032960` in and out for `demo.mp4`), and the file
  size stays within a few percent of the source.

## 3. Confirm the fast path was taken (no re-encode)

Android logs the decision per render (`adb logcat -s ProVideoEditor-Renderer`):

```text
Bitrate cap 8000 kbps: source bitrate(s) 12713 kbps exceed cap × 1.2 — forcing video re-encode
Bitrate cap 8000 kbps: source bitrate(s) 1421 kbps within cap × 1.2 — transmux fast path allowed
```

Darwin logs the equivalent (visible in Xcode/Console via `PluginLog`):

```text
🚀 Bitrate cap: source (1421 kbps) within cap — lossless passthrough export
📊 Bitrate cap 8000 kbps: rendering via AVAssetWriter (AVVideoAverageBitRateKey)
```

A byte-identical video-track bitrate (step 2) is the strongest signal that
no re-encode happened.

## 4. Check streamability (`shouldOptimizeForNetworkUse`)

With `shouldOptimizeForNetworkUse: true` the `moov` box must precede
`mdat` on every path (fast path and re-encode):

```sh
ffprobe -v trace <output.mp4> 2>&1 | grep -o "type:'[a-z]*'" | head -5
```

Expected order: `ftyp`, `moov`, `mdat` (with the flag off: `ftyp`,
`mdat`, `moov`).

## 5. Multichannel (5.1) audio

`assets/surround_5_1.mp4` is a committed 5.1 source; the two "5.1 surround
source" cases in `bitrate_cap_test.dart` assert it renders under a cap on
every platform. On Darwin the capped `AVAssetWriter` path downmixes it to
stereo — confirm the encoded audio track:

```sh
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,channel_layout \
  -of default=noprint_wrappers=1 <capped-output.mp4>
```

Expected: `channels=2`, `channel_layout=stereo`. (AVFoundation also
downmixes implicitly, but the reader is given an explicit stereo channel
layout so the behavior is deterministic across OS versions.)
