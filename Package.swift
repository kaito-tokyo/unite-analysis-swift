// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "unite-analysis-swift",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "record-vision-tool", targets: ["RecordVisionTool"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
  ],
  targets: [
    .target(name: "LDTXRecordingSupport"),
    .target(
      name: "ResultScannerSupport",
      path: "Sources/ResultScanner"
    ),
    .target(name: "RecordVisionSupport", dependencies: ["LDTXRecordingSupport"]),
    .executableTarget(
      name: "RecordVisionTool",
      dependencies: [
        "LDTXRecordingSupport",
        "RecordVisionSupport",
        "ResultScannerSupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "LDTXRecordingSupportTests",
      dependencies: ["LDTXRecordingSupport", "RecordVisionSupport"]),
  ]
)
