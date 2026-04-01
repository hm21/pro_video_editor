import 'dart:io';

import 'package:flutter/foundation.dart';

/// Audio output formats supported for audio extraction.
///
/// Different platforms may have different support levels for each format.
enum AudioFormat {
  /// MP3 format - widely supported, good compression.
  /// Supported on: Android only (not supported on iOS/macOS)
  mp3('audio/mpeg'),

  /// AAC format - high quality, modern codec.
  /// Supported on: Android, iOS, macOS
  aac('audio/aac'),

  /// M4A format - Apple's container for AAC.
  /// Supported on: Android, iOS, macOS
  m4a('audio/mp4'),

  /// CAF format - Core Audio Format, Apple's flexible container.
  /// Supported on: iOS, macOS (Apple only)
  caf('audio/x-caf'),

  /// WAV format - uncompressed audio, high quality, large file size.
  /// Supported on: Android, iOS, macOS
  wav('audio/x-wav');

  const AudioFormat(this.mimeType);

  /// The MIME type for this audio format.
  final String mimeType;

  /// Returns the file extension for this audio format.
  ///
  /// Note: AAC returns 'm4a' on iOS/macOS (as they cannot export raw .aac),
  /// but returns 'aac' on Android which supports raw AAC files.
  String get extension {
    switch (this) {
      case AudioFormat.mp3:
        return 'mp3';
      case AudioFormat.aac:
        // iOS/macOS can only export AAC in M4A container
        if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
          return 'm4a';
        }
        return 'aac';
      case AudioFormat.m4a:
        return 'm4a';
      case AudioFormat.caf:
        return 'caf';
      case AudioFormat.wav:
        return 'wav';
    }
  }
}
