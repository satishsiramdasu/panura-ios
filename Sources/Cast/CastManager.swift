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

    /// Replace with the Panura receiver app id (or use the default media receiver).
    private let receiverAppID = kGCKDefaultMediaReceiverApplicationID

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
        builder.contentType = item.url.absoluteString.contains(".m3u8")
            ? "application/x-mpegURL" : "video/mp4"

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
