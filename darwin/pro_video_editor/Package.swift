// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
  name: "pro_video_editor",
  platforms: [
    .iOS(.v13),
    .macOS(.v12),
  ],
  products: [
    .library(
      name: "pro-video-editor", targets: ["pro_video_editor"]
    )
  ],
  dependencies: [
    .package(path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "pro_video_editor",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      path: ".",
      resources: [],
      linkerSettings: [
        .linkedFramework("Flutter", .when(platforms: [.iOS])),
        .linkedFramework("FlutterMacOS", .when(platforms: [.macOS])),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Foundation"),
      ],
    )
  ]
)
