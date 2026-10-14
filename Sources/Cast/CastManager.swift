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

    /// What is on the TV, for the Now Playing bar.
    ///
    /// The session tells us a device is connected and nothing else; whether
    /// anything is actually playing on it, and what, lives on the remote media
    /// client. Without these the bar could say "connected to" but never
    /// "playing on", which is the fact worth a strip across the screen.
    @Published private(set) var castingTitle: String?
    @Published private(set) var isRemotePlaying = false
    /// Time left on the TV, pre-formatted; empty when live or unknown.
    @Published private(set) var remoteTimeLeft = ""
    /// Where the television is in the video, as it last reported. Read when a
    /// cast has to be re-sent — changing the audio track is a fresh load, and
    /// starting it from zero would be a new viewing of the same film.
    @Published private(set) var remotePosition: TimeInterval = 0
    /// Why the last cast failed, in the receiver's own words.
    ///
    /// **Everything about a failed cast happens on the television.** The phone
    /// hands over a URL and a content type and is told nothing; the receiver
    /// fetches, parses, demuxes and decodes, and when any of that goes wrong
    /// the only symptom here was a title that quietly cleared itself. Three
    /// completely different faults — a manifest the receiver was refused, a
    /// codec it cannot decode, a playlist it cannot parse — looked identical
    /// from the sofa, which is how a week went by on guesses.
    ///
    /// Cast's error codes are specific enough to end that: 3116403 is a
    /// manifest the server refused (CORS or auth), the 3115xxx range is
    /// media that could not be played. Both are worth reading out loud.
    @Published private(set) var lastCastError: String?

    /// Subtitles handed to the receiver with the current video, and which one
    /// is showing (nil is off). Ids are the Cast track ids.
    @Published private(set) var remoteSubtitles: [RemoteSubtitle] = []
    @Published private(set) var activeSubtitle: Int?
    /// A connection that got no answer. Said out loud, because the alternative
    /// was a spinner that never stopped and an app that had to be killed.
    @Published private(set) var connectFailure: String?
    /// The receiver has been loading for more than half a minute.
    @Published private(set) var slowToStart = false
    fileprivate var loadingSince: Date?

    struct RemoteSubtitle: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    /// A cast interstitial waiting on the receiver's confirmation. See
    /// `armCastAd`.
    fileprivate var castAdPending = false
    fileprivate var castAdTimeout: Task<Void, Never>?
    /// When the receiver first reported frames. The exit ad's qualifier reads
    /// it — stopping a cast that never really started is not an exit, it is a
    /// failure, and failures do not carry ads.
    fileprivate var castPlayingSince: Date?

    /// True when a video is loaded on the receiver, not merely connected to it.
    var isCasting: Bool { isConnected && castingTitle != nil }

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
        // Every exit from the cast screen calls this, including the ones where
        // Chromecast was never picked and no scan was ever started.
        guard isScanning else { return }
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
            connectFailure = nil
            GCKCastContext.sharedInstance().sessionManager.startSession(with: manager.device(at: index))
            // Some televisions' Cast service stops answering until restarted,
            // and the SDK then reports neither success nor failure.
            let name = device.name
            let id = device.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.connecting == id else { return }
                self.cancelConnect()
                self.connectFailure = "\(name) didn't answer. Its Cast service sometimes gets stuck; restarting the TV usually fixes it."
            }
            return
        }
    }

    /// Gives up on a connection that has not come back.
    func cancelConnect() {
        connecting = nil
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
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
        noteCastExit()
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        // Disconnect is pressed in the television dialog, which is a plain
        // overlay rather than a sheet — nothing is being dismissed by UIKit,
        // so a turn of the run loop is all the wait this needs.
        Task { @MainActor in AdManager.shared.flushQueued() }
    }

    /// Load a media item onto the connected receiver.
    /// `advertise` is false when the queue moves on by itself.
    ///
    /// The rule this class already keeps is that an ad follows a *successful
    /// action* — someone's action. A queue advancing is nobody's: the phone may
    /// be in a pocket while the television plays, and throwing an interstitial
    /// up then is both a poor surprise and an impression AdMob has every reason
    /// to treat as unsolicited.
    /// Returns whether the receiver was actually handed anything. False means
    /// there was no session — which the caller has to know, because reporting
    /// "playing" over a load that never happened is the shape of bug that
    /// makes a television look broken.
    @discardableResult
    func cast(
        _ item: MediaItem,
        advertise: Bool = true,
        startAt: TimeInterval = 0,
        subtitles: [(track: SubtitleTrack, url: URL)] = []
    ) -> Bool {
        guard let session = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession else { return false }
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

        let active = attachSubtitles(subtitles, to: builder)

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.activeTrackIDs = active
        // Non-zero only when this load is replacing one already playing — an
        // audio change. `startTime` is in seconds from the beginning.
        if startAt > 0 { request.startTime = startAt }
        lastCastError = nil
        // The returned request is the only thing that ever reports why a load
        // was rejected. Discarding it, which is what this did, threw away the
        // one error message in the whole path.
        let load = session.remoteMediaClient?.loadMedia(with: request.build())
        load?.delegate = self
        castingTitle = item.title
        session.remoteMediaClient?.add(self)
        if advertise { armCastAd() }
        return true
    }
}

extension CastManager {
    /// Sends a video out of this phone's library to a Chromecast.
    ///
    /// A Chromecast cannot open a file on this device, so the same HTTP server
    /// PanuraCast uses serves it and the receiver is handed that address. The
    /// phone stays in the loop for the whole video.
    ///
    /// **This is the weaker of the two paths, and the container is why.** A
    /// Chromecast plays MP4 and WebM; an iPhone records QuickTime, often in
    /// HEVC, which most Chromecasts cannot decode at all. Panura on Android TV
    /// has no such limit — it runs the same player this app does. The receiver
    /// is told the real type rather than a hopeful one, so a refusal is a clean
    /// failure instead of a black screen.
    /// Side-loaded text tracks, served as WebVTT by this phone — see
    /// `PanuraCastManager.serveSubtitles`. Returns the tracks to switch on:
    /// the first, as it would be in the player.
    fileprivate func attachSubtitles(
        _ subtitles: [(track: SubtitleTrack, url: URL)],
        to builder: GCKMediaInformationBuilder
    ) -> [NSNumber]? {
        var tracks: [GCKMediaTrack] = []
        for (index, sub) in subtitles.enumerated() {
            let language = sub.track.language
            guard let track = GCKMediaTrack(
                identifier: index + 1,
                contentIdentifier: sub.url.absoluteString,
                contentType: "text/vtt",
                type: .text,
                textSubtype: .subtitles,
                name: sub.track.displayName,
                languageCode: (2...3).contains(language.count) ? language : nil,
                customData: nil
            ) else { continue }
            tracks.append(track)
        }
        remoteSubtitles = subtitles.enumerated().map {
            RemoteSubtitle(id: $0.offset + 1, name: $0.element.track.displayName)
        }
        activeSubtitle = tracks.isEmpty ? nil : 1
        guard !tracks.isEmpty else { return nil }
        builder.mediaTracks = tracks
        return [NSNumber(value: 1)]
    }

    /// Sends a file this phone is serving as HLS, segment by segment. See
    /// `LocalStream`.
    func castLocalStream(
        _ playlist: URL,
        title: String,
        duration: Double,
        advertise: Bool = true,
        subtitles: [(track: SubtitleTrack, url: URL)] = []
    ) {
        guard let session = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession else { return }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: playlist)
        builder.streamType = .buffered
        builder.contentType = "application/x-mpegURL"
        builder.metadata = metadata
        if duration.isFinite, duration > 0 { builder.streamDuration = duration }
        let active = attachSubtitles(subtitles, to: builder)

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.activeTrackIDs = active
        lastCastError = nil
        let load = session.remoteMediaClient?.loadMedia(with: request.build())
        load?.delegate = self
        castingTitle = title
        session.remoteMediaClient?.add(self)
        if advertise { armCastAd() }
    }

    func castLocalFile(
        _ file: URL,
        title: String,
        advertise: Bool = true,
        subtitles: [(track: SubtitleTrack, url: URL)] = []
    ) {
        guard let session = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession else { return }
        guard PanuraCastManager.shared.startServerForLocalFile(file),
              let address = PanuraCastServer.proxyURL(for: file) else { return }

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)

        let builder = GCKMediaInformationBuilder(contentURL: URL(string: address) ?? file)
        builder.streamType = .buffered
        builder.contentType = PanuraCastServer.mimeType(for: file)
        builder.metadata = metadata
        let active = attachSubtitles(subtitles, to: builder)

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.activeTrackIDs = active
        session.remoteMediaClient?.loadMedia(with: request.build())
        castingTitle = title
        session.remoteMediaClient?.add(self)
        if advertise { armCastAd() }
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
            castingTitle = nil
            isRemotePlaying = false
            remoteTimeLeft = ""
            // Deliberately no exit ad here. This fires for a television
            // switched off, a network dropped and a session errored as well
            // as for Disconnect — and the two paths that ARE deliberate have
            // already asked by the time it runs. An ad after an unplanned
            // disconnection is an ad for a failure.
            //
            // Both clocks are cleared, so a cast that ends while an entry ad
            // is still armed cannot have it fire against the next one.
            self.castPlayingSince = nil
            self.disarmCastAd()
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


// MARK: - the ad that waits for the TV

extension CastManager {
    /// Arms the cast interstitial. It fires when the receiver reports the
    /// video actually playing — not now.
    ///
    /// It used to fire here, the instant after `loadMedia`, which means it
    /// fired before anything had been confirmed by anybody. `castLocalFile` is
    /// the weak path for exactly this reason: an iPhone records HEVC
    /// QuickTime and most Chromecasts cannot decode it at all, so a rejected
    /// cast showed an ad and *then* failed. The user was looking at the TV,
    /// waiting, and got an advert for the trouble.
    ///
    /// So the signal is `GCKMediaStatus.playerState == .playing`, which the
    /// media-status listener below already computes for the cast bar. The
    /// receiver has the media, has fetched it, and is showing frames.
    func armCastAd() {
        castAdPending = true
        castAdTimeout?.cancel()
        // If nothing confirms, nothing fires. Fifteen seconds is long enough
        // for a receiver on a slow network to start, and short enough that a
        // stalled cast cannot arm an ad for a video played minutes later.
        castAdTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.castAdPending = false
        }
    }

    /// Cancels an armed ad. For a cast that failed, was refused, or was
    /// stopped before it ever played.
    func disarmCastAd() {
        castAdPending = false
        castAdTimeout?.cancel()
        castAdTimeout = nil
    }

    /// Asks for an ad on the way out of a cast.
    ///
    /// **Queued, not shown.** The Stop button on the cast screen calls
    /// `stopRemote()` and then `dismiss()`, so presenting here would put a
    /// modal up into a sheet that is already going down — the trap that made
    /// Library rows open a player only after the sheet was closed by hand.
    /// `RootTabView` flushes it from that sheet's `onDismiss`.
    ///
    /// **Only a deliberate stop.** `sessionManager(_:didEnd:)` is not a way in
    /// here: that fires when the television is switched off, the network drops
    /// or the session errors, and an ad after an unplanned disconnection is an
    /// ad for a failure. The same rule the player's interstitial keeps.
    ///
    /// **And only a cast that ran.** A minute of confirmed playback, matching
    /// the player's qualifier, so casting something that is refused or
    /// abandoned after ten seconds costs nothing.
    ///
    /// It shares `.cast`'s own clock with the entry ad rather than taking one
    /// of its own, which is what keeps a short cast down to a single ad:
    /// fifteen minutes after arriving, leaving is free. A long film earns
    /// both; a two-minute test earns one.
    fileprivate func noteCastExit() {
        defer { castPlayingSince = nil }
        guard let since = castPlayingSince,
              Date().timeIntervalSince(since) >= 60
        else { return }
        AdManager.shared.queue(.cast)
    }

    /// The receiver is playing: show the ad.
    ///
    /// Presented over the cast screen, which is already open — it is raised on
    /// cast *start* so the wait is never silent, since a Dolby Vision
    /// conversion can take minutes. So the sequence the user sees is: cast,
    /// progress, confirmed, ad, controls showing a playing video.
    fileprivate func castConfirmed() {
        guard castAdPending else { return }
        disarmCastAd()
        AdManager.shared.showInterstitial(.cast)
    }
}

// MARK: - Why a load was refused

extension CastManager: GCKRequestDelegate {
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        // `error.code` is the Cast error code, which is the part worth having:
        // 3116403 is "the server refused the manifest", the 3115xxx range is
        // media that could not be played. Carried through verbatim rather than
        // translated, because the number is what a search engine answers.
        let message = "Cast error \(error.code): \(error.localizedDescription)"
        Task { @MainActor in self.lastCastError = message }
    }
}

// MARK: - What is on the TV

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(
        _ client: GCKRemoteMediaClient,
        didUpdate mediaStatus: GCKMediaStatus?
    ) {
        let playing = mediaStatus?.playerState == .playing
        let title = mediaStatus?.mediaInformation?.metadata?
            .string(forKey: kGCKMetadataKeyTitle)
        // A live stream reports no duration; so does a video the receiver has
        // not finished loading. Both mean "no time to show", not "0:00 left".
        let duration = mediaStatus?.mediaInformation?.streamDuration ?? 0
        let elapsed = mediaStatus?.streamPosition ?? 0
        let left = duration.isFinite && duration > 0 ? max(0, duration - elapsed) : 0
        let idle = mediaStatus?.playerState == .idle
        // `idle` alone was treated as "the video ended", which is three
        // different events wearing one name: a video that finished, one the
        // user cancelled, and one the receiver refused. The last is the
        // interesting one — it is how a cast fails — and it was clearing the
        // title as though everything had gone fine.
        let reason = mediaStatus?.idleReason
        // `interrupted` is the old video giving way to a new load — an audio
        // change, a resumed stall. Not an ending: reading it as one cleared
        // the title, and the queue's "video finished" cleanup then tore down
        // the stream the new load was about to play.
        let replaced = idle && reason == .interrupted
        let failed = idle && reason == .error
        let ended = idle && !failed && !replaced
        let loading = mediaStatus?.playerState == .loading || mediaStatus?.playerState == .buffering

        Task { @MainActor in
            self.trackLoading(loading)
            self.isRemotePlaying = playing
            self.remoteTimeLeft = left > 0 ? PlayerClock.format(left) + " left" : ""
            // Kept even while idle: an audio change reloads, and the position
            // read a moment before that is the one worth resuming from.
            if elapsed.isFinite, elapsed > 0 { self.remotePosition = elapsed }
            if idle, !replaced {
                self.castingTitle = nil
            } else if !idle, let title, !title.isEmpty {
                self.castingTitle = title
            }
            // The receiver is showing frames: this is the only moment a cast
            // is known to have worked, and so the only moment an ad is owed.
            if playing {
                if self.castPlayingSince == nil { self.castPlayingSince = Date() }
                self.castConfirmed()
            }
            // Nothing played, so nothing is owed. `ended` covers a normal
            // finish, which also means the armed ad has missed its moment.
            if failed || ended { self.disarmCastAd() }
            // A receiver that started and then stopped — the splash, a moment
            // of nothing, and back to the home screen. It reports no code of
            // its own here, so say which of the two it was.
            if failed {
                self.lastCastError = "The television could not play this video."
            }
        }
    }

    // MARK: transport, for the bar

    func toggleRemotePlay() {
        guard let client = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession?.remoteMediaClient else { return }
        if isRemotePlaying { client.pause(); return }
        // Nothing loaded on the television any more, so `play()` has nothing
        // to play. This is what a cast served from this phone looks like after
        // the phone was locked: iOS suspended the server, the receiver ran dry
        // and fell back to its splash, and the controls here still read
        // "paused". Send it again from where it got to instead.
        let state = client.mediaStatus?.playerState
        if state == nil || state == .idle || state == .unknown,
           CastFlow.shared.resumeAfterStall() {
            return
        }
        client.play()
    }

    /// Shows one subtitle on the television, or none.
    func selectSubtitle(_ id: Int?) {
        guard let client = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession?.remoteMediaClient else { return }
        client.setActiveTrackIDs(id.map { [NSNumber(value: $0)] } ?? [])
        activeSubtitle = id
    }

    func stopRemote() {
        noteCastExit()
        GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession?.remoteMediaClient?.stop()
        castingTitle = nil
        isRemotePlaying = false
        remoteTimeLeft = ""
    }
}

extension CastManager {
    /// Starts or clears the half-minute watch on a receiver that is loading.
    ///
    /// Some televisions' Cast service gets stuck taking a request — seen on
    /// Android senders too — and then sits on its spinner indefinitely. Nothing
    /// here can unstick it; saying so, and what does, is the useful part.
    fileprivate func trackLoading(_ loading: Bool) {
        guard loading else {
            loadingSince = nil
            slowToStart = false
            return
        }
        guard loadingSince == nil else { return }
        let started = Date()
        loadingSince = started
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.loadingSince == started else { return }
            self.slowToStart = true
        }
    }
}
