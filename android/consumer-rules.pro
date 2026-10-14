# R8 breaks Media3 exports on Android 11 and older (API 30 and below) in two
# ways. The same minified builds work on Android 12+.

# R8's optimization of Media3's effect classes breaks the GL pipeline: every
# export that re-encodes fails with "Video frame processing error", caused by
# "A 4x4 transformation matrix must have 16 elements". Keeping the classes
# unoptimized fixes it; renaming stays allowed.
-keep,allowobfuscation class androidx.media3.effect.** { *; }

# R8 full mode merges unrelated classes into one and widens their fields to
# Object, casting each read back to the field's type. Media3 keeps nullable
# fields of newer types, such as the Transformer's LogSessionId (API 31), and
# ART before Android 12 resolves a cast's class even when the value is null, so
# the first export crashes the app with NoClassDefFoundError. Keeping the
# classes stops the merging; shrinking, renaming and member optimizations stay
# allowed.
-keep,allowobfuscation,allowshrinking class androidx.media3.**
