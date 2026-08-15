#!/bin/sh
#
# Runs the Darwin unit tests — example/ios/RunnerTests, example/macos/RunnerTests
# and the shared cases in example/shared_tests.
#
#   tool/darwin_unit_tests.sh macos
#   tool/darwin_unit_tests.sh ios ["iPhone 17"]
#
# The `flutter build` in front is not optional, and not there to compile the app.
# Flutter generates
#
#   {ios,macos}/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage
#
# at its own default minimum OS (iOS 13.0 / macOS 10.15) and only raises it to
# the Xcode project's deployment target from inside `flutter build`. Several
# packages in the example app need more than that default — file_picker wants
# iOS 14, pro_image_editor macOS 11, pro_video_editor itself macOS 12 — so on a
# fresh checkout, or after `flutter clean`, plain `xcodebuild` fails to resolve
# the package instead of running a single test:
#
#   error: The package product 'file-picker' requires minimum platform version
#   14.0 for the iOS platform, but this target supports 13.0
#
# `--config-only` is enough: the deployment target is written before the build
# proper would start, so this costs a build-settings read, not a compile. The
# value then survives, so later `xcodebuild` runs need nothing.
#
# Unrelated, but you will meet it: the first link after the packages are
# re-resolved sometimes fails inside the prebuilt `fvp` plugin. It is flaky, not
# a real breakage — run the script again.
set -eu

cd "$(dirname "$0")/.."

case "${1:-}" in
  macos)
    flutter build macos --debug --config-only
    exec xcodebuild test \
      -workspace macos/Runner.xcworkspace \
      -scheme Runner \
      -destination 'platform=macOS'
    ;;
  ios)
    flutter build ios --debug --simulator --config-only
    exec xcodebuild test \
      -workspace ios/Runner.xcworkspace \
      -scheme Runner \
      -destination "platform=iOS Simulator,name=${2:-iPhone 17}"
    ;;
  *)
    echo "usage: $(basename "$0") {ios|macos} [simulator name]" >&2
    exit 64
    ;;
esac
