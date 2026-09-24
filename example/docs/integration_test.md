# Video Merge Integration Test Assets

This folder contains a **fixed set of video assets** used for cross-platform
video merging integration tests.

Each video is intentionally designed to stress **one specific dimension**
(resolution, frame rate, audio, codec, metadata) while keeping all other
parameters simple and deterministic.

⚠️ These assets must not be modified or regenerated unless the test
specification itself changes.

---

## Test Assets Overview

| ID | Filename | Primary Purpose |
|----|---------|-----------------|
| A | `test_a.mp4` | Baseline / golden reference |
| B | `test_b.mp4` | Portrait aspect ratio |
| C | `test_c.mp4` | Frame rate conversion |
| D | `test_d.mp4` | Missing audio handling |
| E | `test_e.mp4` | Codec fallback / re-encode |
| F | `test_f.mp4` | Audio codec and bitrate |
| G | `test_g.mp4` | Rotation metadata (display matrix) |
| 4K-A | `test_4k_a.mp4` | Large file / memory stress |
| 4K-B | `test_4k_b.mp4` | Large file / memory stress |

---

## Asset Details

### Test A — Baseline (Golden Reference)

**Purpose**
- Acts as the reference for all merge behavior
- Used to detect regressions and timing drift

**Configuration**
- 1920×1080 (16:9)
- 30 fps (constant)
- H.264 High
- AAC stereo, 48 kHz
- Duration: ~5s
- No rotation metadata

**Tests**
- `A + A` baseline merge
- Deterministic output across platforms
- Passthrough vs re-encode decisions
- Audio/video sync correctness

---

### Test B — Portrait Aspect Ratio

**Purpose**
- Validate handling of non-16:9 (portrait) content

**Configuration**
- 720×1280 (9:16 portrait)
- 30 fps
- H.264 High
- AAC mono, 44.1 kHz
- Duration: ~4s
- Rotation metadata: none. The pixels are stored portrait; for a clip that
  carries a rotation flag, see Test G.

**Tests**
- Correct orientation after merge
- Proper scaling / letterboxing
- Metadata interpretation consistency

---

### Test C — Frame Rate Mismatch

**Purpose**
- Validate timestamp resampling and frame pacing

**Configuration**
- 1920×1080
- 60 fps (constant)
- H.264 High
- AAC stereo
- Duration: ~3s

**Tests**
- `30 → 60 fps` merge
- No dropped or duplicated frames
- Smooth transition at clip boundaries

---

### Test D — No Audio Track

**Purpose**
- Validate robustness when audio is missing

**Configuration**
- 1920×1080
- 30 fps
- H.264 Baseline
- **No audio track**
- Duration: ~2s

**Tests**
- Silent segment handling
- No crashes or invalid containers
- Correct audio track recreation when merging with audio clips

---

### Test E — Codec Compatibility (HEVC)

**Purpose**
- Validate codec support and fallback behavior

**Configuration**
- 1920×1080
- 30 fps
- HEVC / H.265
- AAC stereo
- Duration: ~3s

**Tests**
- Passthrough on supported platforms
- Automatic re-encode on unsupported platforms
- Consistent output duration and sync

---

### Test F — Audio Codec and Bitrate

**Purpose**
- Validate audio codec support and bitrate

**Configuration**
- AC3 Dolby Digital
- 448kbps
- Duration: ~5s

**Tests**
- AAC ↔ AC3 codec transitions
- High bitrate audio handling
- Proper audio re-encoding when mixing codecs
- No audio sync issues with different codecs

---

### Test G — Rotation Metadata

**Purpose**
- Validate that a rotation flag is applied, and in the right direction

**Configuration**
- 640×360 stored, flagged −90° (ffprobe `rotation=-90`, the convention of a
  portrait phone recording), so it shows as 360×640
- 30 fps
- H.264 High
- No audio track
- Duration: 2s (made from `demo.mp4` with `ffmpeg -display_rotation -90`)

**Tests**
- A `VideoComposition` layer shows it upright, not turned or mirrored

---

### Test 4K-A — Large File Handling (Part 1)

**Purpose**
- Validate memory management with large 4K files
- Test performance under high data throughput

**Configuration**
- 3840×2160 (4K UHD)
- 60 fps
- H.264 High
- File size: ~61.4 MB

**Tests**
- Multiple large file merges
- Memory efficiency during processing
- Output file integrity
- No memory leaks or crashes

---

### Test 4K-B — Large File Handling (Part 2)

**Purpose**
- Complement 4K-A for extended stress testing
- Validate consistency across multiple large merges

**Configuration**
- 3840×2160 (4K UHD)
- 30 fps
- H.264 High
- File size: ~49.4 MB

**Tests**
- Combined with 4K-A for ~1GB total output
- Repeated merge operations (10+ loops)
- File-based output for large results
- Duration accuracy at scale

---

## General Assertions (All Tests)

- Total output duration matches sum of inputs (within tolerance)
- No audio gaps or overlaps
- Audio/video remain synchronized
- Frame-accurate transitions
- No unexpected orientation or scaling changes

---

## Notes

- All videos are encoded with **constant frame rate**
- Sources are synthetic or pre-rendered (not camera recordings)
- Assets are committed to ensure deterministic CI results
