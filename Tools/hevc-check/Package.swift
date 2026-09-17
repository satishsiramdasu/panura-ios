// swift-tools-version:5.9
import PackageDescription

// Checks the app's HEVCTagPatcher against AVFoundation on a Mac. The patcher's
// source is copied in by .github/workflows/hevc-check.yml, so the file tested is
// the file the app ships.
let package = Package(
    name: "hevc-check",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "hevc-check", path: "Sources/hevc-check"),
    ]
)
