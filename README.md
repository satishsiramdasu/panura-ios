# Panura Player — iOS

Native SwiftUI port of the Android Panura Player. Authored on Windows, built on macOS CI.

## Why it's structured this way

You have **no Mac**, so the project is designed to build **entirely on a macOS CI runner**:

- **XcodeGen** — the `.xcodeproj` is *generated* from [`project.yml`](project.yml). Never hand-edit a `.pbxproj`. The project file is git-ignored.
- **Swift Package Manager** — all dependencies (Google Cast, Google Mobile Ads, Swifter) are declared in `project.yml`. No CocoaPods.
- **GitHub Actions** — [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) runs `xcodegen generate` + `xcodebuild` on `macos-14`. Push to `main` (or run the workflow manually) to compile-check.

To actually **run on a device or ship**, you still need:
- an **Apple Developer account** ($99/yr),
- signing certs + provisioning profile added as CI secrets (or a real Mac / cloud Mac).

## Layout

| Path | Android counterpart |
|------|---------------------|
| `Sources/App/RootTabView.swift` | `HomeScreen.kt` (6-tab bottom bar) |
| `Sources/Features/Home` | `HomeTab.kt` |
| `Sources/Features/Browser` | in-app browser + WebView extraction |
| `Sources/Features/Player` (AVPlayer) | Media3/ExoPlayer player |
| `Sources/Features/LocalVideos` (PhotoKit) | MediaStore video picker |
| `Sources/Features/Downloads` | offline downloads |
| `Sources/Features/Stream` | paste-URL "Stream" tab |
| `Sources/Cast` (Google Cast SDK) | Chromecast + PanuraCast |
| `Sources/Ads` (Google Mobile Ads) | `AdManager.kt` (4 interstitial slots) |

## Feature-parity status

**Ports cleanly**
- Local video player (AVPlayer plays HLS + MP4 natively).
- In-app browser + generic video sniffer (WKUserScript injection ≈ Android's generic extractor).
- Chromecast of **remote** URLs (Google Cast iOS SDK).
- Interstitial ads on successful cast/download.

**Needs design work / doesn't port 1:1**
- **`shouldInterceptRequest` has no iOS equivalent.** Extraction relies on the injected JS sniffer + navigation-policy sniffing. Some sites that Android catches via request interception will need per-case handling.
- **PanuraCast local HTTP server (`:8888`).** iOS suspends arbitrary sockets in the background, so streaming *local files/downloads* to a TV while backgrounded is not reliable. Remote-URL casting is fine. Options: keep-alive via the `audio` background mode, or restructure around `AVAssetDownloadURLSession` + AirPlay.
- **HLS offline download.** `DownloadManager` handles progressive `.mp4`; `.m3u8` offline needs `AVAssetDownloadTask` (marked TODO).

## Before first real build — fill in
- `GADApplicationIdentifier` in `project.yml` — real **iOS** AdMob app id (the Android one won't work).
- AdMob interstitial unit IDs in `Sources/Ads/AdManager.swift`.
- Cast receiver app id in `CastManager.swift` (or keep the default media receiver).
- `PRODUCT_BUNDLE_IDENTIFIER` / `DEVELOPMENT_TEAM` for signing.
- App icon (1024×1024) in `Resources/Assets.xcassets/AppIcon.appiconset`.

## App Store note
The download-from-arbitrary-sites feature conflicts with App Store Review (Guideline 5.2 / adult content). For App Store submission that piece must be gated/removed; for sideload/AltStore/TestFlight the full feature set can ship.
