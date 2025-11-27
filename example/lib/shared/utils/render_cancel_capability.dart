import 'dart:io';

import 'package:flutter/foundation.dart';

/// Signature for determining whether the current platform can cancel renders.
typedef CancelCapabilityResolver = bool Function();

CancelCapabilityResolver _cancelCapabilityResolver = _defaultResolver;

/// Returns `true` when the current platform exposes a cancel implementation.
bool canCancelOnCurrentPlatform() => _cancelCapabilityResolver();

bool _defaultResolver() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Overrides the capability resolver. Intended for widget tests only.
@visibleForTesting
void overrideRenderCancelCapability(CancelCapabilityResolver resolver) {
  _cancelCapabilityResolver = resolver;
}

/// Restores the default capability resolver.
@visibleForTesting
void resetRenderCancelCapability() {
  _cancelCapabilityResolver = _defaultResolver;
}
