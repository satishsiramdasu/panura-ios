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
    /// Cast targets found on this network, for the app's own list.
    @Published var devices: [CastDevice] = []
    /// True while the discovery scan is running, so the list can say it is
    /// still looking rather than claiming there is nothing out there.
    @Published var isScanning = false
    /// Unique id of the device being connected to.
    @Published var connecting: String?

    /// One discovered target, flattened out of `GCKDevice` so the view layer
    /// never touches the SDK's types.
    struct CastDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let model: String?
    }

    func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: receiverAppID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    /// Start listing Cast targets.
    ///
    /// The SDK's own button opens the SDK's own dialog, which is a third screen
    /// on top of a sheet on top of a screen. The devices are discoverable from
    /// here directly, so the picker lists them itself and one tap connects.
    ///
    /// `passiveScan` off while the list is up: passive scanning is the
    /// battery-saving mode the SDK sits in when nothing is asking, and it can
    /// take many seconds to notice a TV — too slow for a list someone is
    /// watching. It goes back on when the list closes.
    func startDiscovery() {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        manager.add(self)
        manager.passiveScan = false
        manager.startDiscovery()
        isScanning = true
        refreshDevices()
    }

    func stopDiscovery() {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        manager.passiveScan = true
        manager.stopDiscovery()
        manager.remove(self)
        isScanning = false
    }

    /// Connects to one target. The session listener below reports the outcome,
    /// which is what clears `connecting`.
    func connect(_ device: CastDevice) {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        for index in 0..<manager.deviceCount where manager.device(at: index).uniqueID == device.id {
            connecting = device.id
            GCKCastContext.sharedInstance().sessionManager.startSession(with: manager.device(at: index))
            return
        }
    }

    fileprivate func refreshDevices() {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        var found: [CastDevice] = []
        for index in 0..<manager.deviceCount {
            let device = manager.device(at: index)
            found.append(
                CastDevice(
                    id: device.uniqueID,
                    name: device.friendlyName ?? device.deviceID,
                    model: device.modelName
                )
            )
        }
        devices = found
    }

    /// End the Cast session for real.
    ///
    /// The cast dialog's Disconnect used to call PanuraCast's teardown, which
    /// does nothing whatsoever to a Google Cast session — on a Chromecast the
    /// button left the device connected. Only the session manager can end one.
    func endSession() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
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
        // `castHeaders`, not `headers`: the receiver fetches from its own
        // address, so it needs the second-device set — Referer and User-Agent,
        // and none of this device's cookies, which would only be rejected.
        if !item.castHeaders.isEmpty {
            builder.customData = ["headers": item.castHeaders]
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
            connecting = nil
        }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor in
            isConnected = false
            connectedDeviceName = nil
            connecting = nil
        }
    }
    /// Without this a failed connection leaves the row spinning for ever.
    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKCastSession,
        withError error: Error
    ) {
        Task { @MainActor in connecting = nil }
    }
}

extension CastManager: GCKDiscoveryManagerListener {
    /// One callback for every change — insert, update and remove all end here,
    /// and the list is re-read whole rather than patched by index.
    nonisolated func didUpdateDeviceList() {
        Task { @MainActor in refreshDevices() }
    }
}
