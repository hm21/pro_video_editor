# R8's optimization of Media3's effect classes breaks the GL pipeline on
# Android 9-11 (API 28-30): every export that re-encodes fails with "Video
# frame processing error", caused by "A 4x4 transformation matrix must have 16
# elements". The same minified build works on Android 12+. Keeping the classes
# unoptimized fixes it; renaming stays allowed.
-keep,allowobfuscation class androidx.media3.effect.** { *; }
