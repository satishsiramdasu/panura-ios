import Foundation
import GoogleCast

/// Wraps the Google Cast iOS SDK. This covers Chromecast / Google-Cast targets,
/// mirroring the Android Chromecast path.
///
/// NOTE: The Android "PanuraCast" custom receiver + on-device :8888 HTTP server
/// (used to stream local files/downloads to a Panura TV) does NOT port cleanly:
/// iOS suspends arbitrary sockets when backgrounded. Casting *remote* URLs works;
/// casting *local files* while backgrounded needs a different design (see README).
@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()

    /// Panura custom receiver (same ID as Android) — hosted at
    /// panura.pages.dev/cast/receiver.html, re-injects Referer/Cookie/User-Agent
    /// so header-gated streams play. Registered receiver, shared across platforms.
    private let receiverAppID = "BE269497"

    @Published var isConnected = false
    @Published var connectedDeviceName: String?

    func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: receiverAppID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    /// Load a media item onto the connected receiver.
    func cast(_ item: MediaItem) {
        guard let session = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession else { return }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)

        let builder = GCKMediaInformationBuilder(contentURL: item.url)
        builder.streamType = .buffered
        builder.metadata = metadata
        // Prefer the manifest rule's hint: an extensionless manifest
        // (/hls/<token>/<token>) would otherwise be sent as video/mp4 and fail.
        switch item.contentType {
        case "hls":  builder.contentType = "application/x-mpegURL"
        case "dash": builder.contentType = "application/dash+xml"
        case "mp4":  builder.contentType = "video/mp4"
        default:
            let url = item.url.absoluteString
            builder.contentType = (url.contains(".m3u8") || url.contains("/hls/"))
                ? "application/x-mpegURL"
                : (url.contains(".mpd") ? "application/dash+xml" : "video/mp4")
        }
        // Header-gated streams: the BE269497 custom receiver reads
        // customData.headers and re-injects them on every request — same
        // contract as the Android sender (ChromecastManager.loadMedia).
        if !item.headers.isEmpty {
            builder.customData = ["headers": item.headers]
        }

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        session.remoteMediaClient?.loadMedia(with: request.build())
        AdManager.shared.showInterstitial(.cast)
    }
}

extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in
            isConnected = true
            connectedDeviceName = session.device.friendlyName
        }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor in
            isConnected = false
            connectedDeviceName = nil
        }
    }
}
