// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "MediaServerKit",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    .library(name: "MediaServerKit", targets: ["MediaServerKit"]),
  ],
  targets: [
    .target(name: "MediaServerKit"),
    .testTarget(name: "MediaServerKitTests", dependencies: ["MediaServerKit"]),
  ]
)
