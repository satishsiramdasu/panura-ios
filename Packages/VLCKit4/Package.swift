// swift-tools-version: 5.9
//
// VLCKit 4 (libVLC 4), wrapped as a Swift package.
//
// There is no community SPM mirror for 4.x (vlckit-spm stops at 3.6.0), so this
// points straight at the archive VideoLAN publishes for CocoaPods. That zip has
// `VLCKit.xcframework` at its root, which is all a binary target needs; the
// checksum is the SHA-256 from VideoLAN's own podspec for the same version.
//
// To move to a newer alpha: take `source.http` and `source.sha256` from
// https://github.com/CocoaPods/Specs/blob/master/Specs/5/f/4/VLCKit/<version>/VLCKit.podspec.json
// and paste them below. Pin exact builds only — 4.0 is still in alpha and its
// API has moved between tags.
//
// Unlike 3.x this is a DYNAMIC framework, so Xcode embeds it; nothing to link
// by hand beyond the two system libraries the podspec names.

import PackageDescription

let package = Package(
    name: "VLCKit4",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "VLCKit4", targets: ["VLCKit4"]),
    ],
    targets: [
        // 4.0.0a24
        .binaryTarget(
            name: "VLCKit",
            url: "https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260831-1526.zip",
            checksum: "c61a42052ec4c1315325fba81f8893f4ccf639d92bf61dd1b3c37c3a2f26b8e3"
        ),
        .target(
            name: "VLCKit4",
            dependencies: ["VLCKit"],
            path: "Sources/VLCKit4",
            linkerSettings: [
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
