import Combine
import Foundation
import SwiftUI

/// Everything between "send this to the TV" and a picture on the TV.
///
/// That gap used to be silent. A local video had to be read out of the photo
/// library, sometimes copied, sometimes converted from Dolby Vision — which can
/// take minutes — and then handed to one of two receivers, and none of it was
/// visible: the phone simply sat there. Worse, each screen that could start a
/// cast grew its own spinner, so the browser and the Videos tab told the same
/// story differently, and neither could be reopened once dismissed.
///
/// So the whole lifecycle lives here, in one place both cast paths report
/// through, and `CastSessionView` is the one screen that renders it. The stage
/// is deliberately plain data: a view should never have to ask a manager what
/// is going on, and a stage that can be described in a sentence can be shown in
/// one.
/// One thing waiting to go to the TV.
///
/// It holds an *identifier*, never a resolved file. A queue outlives the screen
/// that built it — the Videos tab can be closed, the app backgrounded — and a
/// temporary export URL resolved half an hour ago may be gone by the time its
/// turn comes. Resolving at the moment of playing also means an iCloud video is
/// fetched when it is needed rather than all of them at once.
struct CastQueueItem: Identifiable, Equatable {
    let id: String
    let title: String
    let payload: Payload
    /// The page's poster, for a stream. Fetched where it is shown.
    var posterURL: URL?
    /// Already in memory, for a video in the library: the Videos tab has its
    /// thumbnail by the time anything can be queued, and re-reading it from
    /// Photos to draw a 54-point picture would be work for nothing.
    var posterImage: UIImage?

    /// The two kinds of thing that can be cast, which reach the TV by
    /// completely different routes: a stream is a URL the TV fetches for
    /// itself, while a video in the library only exists on this phone and has
    /// to be served from it.
    enum Payload: Equatable {
        case stream(MediaItem)
        case photo(localIdentifier: String)
    }

    var isStream: Bool { if case .stream = payload { return true }; return false }
}

@MainActor
final class CastFlow: ObservableObject {
    static let shared = CastFlow()

    /// Where a cast has got to. Ordered as it happens.
    enum Stage: Equatable {
        /// Nothing being sent. The screen still opens from the cast bar, and
        /// shows the controls for whatever is already playing.
        case idle
        /// Reading the video out of the library — quick, unless iCloud has to
        /// fetch it first, which is exactly when saying so matters.
        case reading(title: String)
        /// Making a copy the TV can decode. Carries why, because "converting"
        /// alone invites the reasonable question of why it wasn't just sent.
        /// `overridable` is the difference between a judgement and a fact. A
        /// TV that renders Dolby Vision correctly makes that conversion
        /// pointless, and only the viewer can tell — so it can be waved off.
        /// A Chromecast that cannot decode HEVC cannot be talked round, and
        /// offering to send the original there would only promise a black
        /// screen.
        case converting(title: String, explanation: String, progress: Float, overridable: Bool)
        /// A file with several languages, waiting for one to be chosen. A
        /// Chromecast plays a single track, so this is asked before anything
        /// is prepared.
        case choosingAudio(title: String, options: [CastLocalMedia.AudioOption])
        /// The file needs converting before the TV can play it, and the
        /// person decides whether to: the conversion is the reward of a
        /// rewarded ad, so it is offered rather than started.
        case offerConversion(title: String, explanation: String, overridable: Bool)
        /// Handed over; waiting for the TV to pick it up.
        case sending(title: String, device: String)
        /// The TV has it. From here the controls take over.
        case playing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .reading, .converting, .choosingAudio, .offerConversion, .sending: return true
            default: return false
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    /// Whether the screen is up. Separate from the stage: a cast can be running
    /// with the screen dismissed, and the screen can be open with nothing
    /// casting at all.
    @Published var showing = false

    /// What is waiting, in order. The video currently on the TV is not in it.
    @Published private(set) var queue: [CastQueueItem] = []
    /// What the TV has now, so the screen can name it while the queue shows
    /// what follows.
    @Published private(set) var nowPlaying: CastQueueItem?
    /// Something was chosen while the TV is busy, and the question of what to do
    /// about it has not been answered yet. It lives here rather than on the
    /// screen that asked, because the dialog belongs to the cast bar — the
    /// screen that started it is often gone by the time the question is put.
    @Published var pendingQueue: CastQueueItem?

    private var work: Task<Void, Never>?
    private var watchers: Set<AnyCancellable> = []
    /// What the current attempt is about, so "Send original" can carry on with
    /// the same video after abandoning its conversion.
    private var pending: (file: URL, title: String, id: String)?
    /// The answer to `choosingAudio`, while it is being asked.
    private var audioChoice: CheckedContinuation<CastLocalMedia.AudioOption?, Never>?

    enum ConversionAnswer { case convert, original, cancel }
    private var conversionAnswer: CheckedContinuation<ConversionAnswer, Never>?
    /// The conversion running under a rewarded ad. Its own task, so Cancel
    /// reaches it as well as the attempt that started it.
    private var conversionJob: Task<URL, Error>?

    private init() {
        // Both receivers say the same thing in different words when a video
        // ends: Panura's stops reporting a cast, and the Cast SDK drops the
        // title it was playing. Either is the cue to start whatever is next.
        //
        // `dropFirst` because both start out in the "nothing playing" state,
        // and that is not a video finishing.
        PanuraCastManager.shared.$isCasting
            .removeDuplicates()
            .dropFirst()
            // Hopped onto the main actor explicitly. A `sink` closure carries
            // no actor isolation of its own, so calling straight into this
            // main-actor class from inside one does not compile.
            .sink { casting in
                guard !casting else { return }
                Task { @MainActor [weak self] in self?.finished() }
            }
            .store(in: &watchers)

        CastManager.shared.$castingTitle
            .removeDuplicates()
            .dropFirst()
            .sink { title in
                guard title == nil else { return }
                Task { @MainActor [weak self] in self?.finished() }
            }
            .store(in: &watchers)
    }

    // MARK: the queue

    /// Adds to the end of the queue, and starts straight away if the TV is idle.
    ///
    /// Queueing several at once is the point of it: picking twenty videos and
    /// being asked twenty questions would be worse than no queue at all.
    func enqueue(_ items: [CastQueueItem], startIfIdle: Bool = true) {
        guard !items.isEmpty else { return }
        queue.append(contentsOf: items)
        showing = true
        let idle = !PanuraCastManager.shared.isCasting && !CastManager.shared.isCasting
        if startIfIdle, idle, !stage.isBusy { advance(auto: false) }
    }

    /// Replaces what is on the TV with `items`, dropping anything still queued.
    func replace(with items: [CastQueueItem]) {
        queue = items
        advance(auto: false)
    }

    func remove(_ item: CastQueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    func clearQueue() {
        queue.removeAll()
    }

    /// Stops what is playing on the television and abandons the queue.
    ///
    /// The order matters. `finished()` watches for a cast ending and starts
    /// whatever is next, and stopping by hand looks exactly like a video
    /// finishing — so the stage is cleared first, which is what tells it this
    /// was deliberate. Without that, pressing stop played the next thing.
    ///
    /// The TV stays connected. Stopping a video is not leaving the television.
    func stopCasting() {
        queue.removeAll()
        nowPlaying = nil
        audio = nil
        muxed = nil
        sent = nil
        canMux = false
        PanuraCastManager.shared.clearRemux()
        stage = .idle
        work?.cancel()
        work = nil
        if PanuraCastManager.shared.isCasting { PanuraCastManager.shared.stopStream() }
        if CastManager.shared.isCasting { CastManager.shared.stopRemote() }
    }

    /// Starts the next item, if there is one.
    ///
    /// `auto` marks the queue moving on by itself rather than somebody asking
    /// for it, which is what decides whether an ad may follow.
    func advance(auto: Bool = false) {
        guard !queue.isEmpty else {
            nowPlaying = nil
            stage = .idle
            return
        }
        let next = queue.removeFirst()
        nowPlaying = next
        showing = true
        work?.cancel()
        work = Task { await play(next, auto: auto) }
    }

    /// The TV finished something. Only acts while this flow believes a video is
    /// on it, so stopping a cast by hand does not start the queue up again.
    private func finished() {
        guard case .playing = stage else { return }
        nowPlaying = nil
        // The next thing in the queue is a different stream with different
        // tracks; `play` sets this again if it has any.
        audio = nil
        muxed = nil
        sent = nil
        canMux = false
        PanuraCastManager.shared.clearRemux()
        if queue.isEmpty {
            stage = .idle
        } else {
            advance(auto: true)
        }
    }

    /// The multi-audio stream on a Chromecast, if that is what is playing.
    ///
    /// Lives here rather than in `CastAudioMaster` — which is deliberately
    /// stateless string work — because this object already owns everything
    /// between "send this" and a picture, and the cast screen already watches
    /// it. Nil for a single-audio stream, for Panura's own receiver, and for
    /// anything that is not HLS.
    @Published private(set) var audio: CastAudioMaster.Prepared?

    /// The stream this phone is folding audio into, if that is what is
    /// happening instead. See `CastRemux`.
    ///
    /// Never set at the same time as `audio`: they are two answers to one
    /// question. Filtering the master hands the television a playlist and gets
    /// out of the way; muxing stays in the path of every segment for the
    /// length of the film.
    @Published private(set) var muxed: CastRemux.Session?

    /// True while a strategy is being prepared.
    ///
    /// Worth showing. Switching reads two playlists and an audio segment
    /// before anything is sent, and until it lands the television is still
    /// playing the old way — so without this the screen says nothing happened.
    @Published private(set) var reloading = false

    /// Whether muxing is worth offering: an HLS master with its audio declared
    /// separately. Anything else it cannot help, so the option is not shown.
    @Published private(set) var canMux = false

    /// Set when muxing was asked for and could not be done.
    ///
    /// Without this the switch sits on while nothing changes, which is the
    /// worst of the three states: the film still stops, the setting says it is
    /// being handled, and there is nothing to read. The reasons are real and
    /// worth naming — a live channel has no fixed segment list to renumber,
    /// encrypted segments cannot be opened, and fragmented MP4 is a different
    /// container.
    @Published private(set) var muxUnavailable = false

    /// The stream as the page gave it to us, whichever path it took. Kept so a
    /// change of strategy or of track can start again from the original rather
    /// than from whatever local address is currently on the television.
    private var sent: MediaItem?

    /// The audio tracks the television could be given, whichever path is in
    /// use — so the picker needs to know about neither.
    var tracks: [HLSAudioRendition] { muxed?.tracks ?? audio?.tracks ?? [] }
    var chosenTrack: Int? { muxed?.chosen ?? audio?.chosen }
    /// Whether this phone is in the path of the film *right now*.
    var isMuxing: Bool { muxed != nil }

    /// What the switch shows: the answer for this television, which is yes
    /// until somebody says otherwise.
    ///
    /// **The setting, not the live state.** They differ on a film muxing
    /// cannot be done to — live, encrypted, already muxed — and showing the
    /// live state there makes the switch look as though it flipped itself off.
    /// The caption carries what is actually happening.
    var muxWanted: Bool {
        CastPreferences.muxingChoice(on: deviceName ?? "") ?? true
    }

    /// Turns phone-side muxing on or off for this television, and starts the
    /// film again the new way.
    ///
    /// The answer is remembered against the TV's name, so somebody with one
    /// old set in the bedroom neither re-answers it per film nor makes their
    /// good television pay for it. See `CastPreferences.muxingChoice`.
    func setMuxing(_ on: Bool) {
        guard let device = deviceName, let media = sent else { return }
        CastPreferences.setMuxing(on, on: device)
        Task { await resend(media, track: chosenTrack) }
    }

    /// Sends the same video again with a different audio track.
    ///
    /// **It reloads on the television, and there is no way around that.** The
    /// receiver is playing a stream that carries one audio track; another
    /// track is another stream, and Cast has no notion of swapping one
    /// underneath a running load. So the position is read back and handed to
    /// the new one — the picture jumps, the film does not.
    ///
    /// No ad, deliberately: this is not a new cast, it is the same one being
    /// corrected, and an interstitial in the middle of a task is the pattern
    /// the whole ad design avoids.
    func changeAudio(to id: Int) {
        guard chosenTrack != id, let media = sent else { return }
        Task { await resend(media, track: id) }
    }

    /// Re-sends the current film from where the television had got to, after
    /// the receiver lost it. Returns false when there is nothing to re-send.
    ///
    /// Prepared from scratch, not reloaded: the phone's server is rebuilt when
    /// the app returns from suspension, and a muxing session made before that
    /// is serving nobody.
    func resumeAfterStall() -> Bool {
        guard let media = sent, CastManager.shared.isConnected else { return false }
        Task { await resend(media, track: chosenTrack) }
        return true
    }

    /// Prepares `media` again and replaces what the television is playing,
    /// from where it had got to.
    private func resend(_ media: MediaItem, track: Int?) async {
        reloading = true
        let at = CastManager.shared.remotePosition
        let payload = await chromecastPayload(media, track: track)
        let subtitles = await Self.subtitles(for: media)
        reloading = false
        CastManager.shared.cast(payload, advertise: false, startAt: at, subtitles: subtitles)
    }

    private static func subtitles(for media: MediaItem) async -> [(track: SubtitleTrack, url: URL)] {
        await PanuraCastManager.shared.serveSubtitles(
            media.subtitles,
            headers: media.headers.isEmpty ? media.castHeaders : media.headers
        )
    }

    /// What a Chromecast should actually be sent.
    ///
    /// Three outcomes, in the order they are tried:
    ///
    /// - **Muxed on the phone**, for a master that declares its audio
    ///   separately. Tried first and tried *by default*, because that shape is
    ///   precisely what a Chromecast of this vintage cannot play — so waiting
    ///   to be asked means the first attempt always fails. Costs the most:
    ///   every byte of the film passes through here.
    /// - **Proxied through the phone**, for a stream gated by a header no
    ///   television can send. Also everything through the phone, but nothing
    ///   rebuilt — it is forwarded.
    /// - **One audio rendition**, when the master declares several, several
    ///   groups, or a codec the hardware cannot decode, and muxing was
    ///   declined or impossible. A kilobyte, once.
    /// - **Untouched**, which is most streams and the cheapest by far: the
    ///   television streams from the CDN and the phone can leave the network.
    ///
    /// So the question is not "should this be proxied" but "is there anything
    /// wrong with handing the television the address" — and only the answers
    /// to that put the phone in the path.
    ///
    /// Falling through is deliberate at every step: a stream that cannot be
    /// read here may still play on the television, and refusing to cast it
    /// because an optimisation failed would be worse than the fault being
    /// worked around.
    private func chromecastPayload(_ media: MediaItem, track: Int?) async -> MediaItem {
        audio = nil
        muxed = nil
        muxUnavailable = false
        PanuraCastManager.shared.clearRemux()

        // nil means nobody has said, and the default is yes — see
        // `CastPreferences.muxingChoice`.
        let wanted = CastPreferences.muxingChoice(on: deviceName ?? "") ?? true
        if wanted,
           let session = await CastRemux.prepare(media, track: track),
           PanuraCastManager.shared.startServerForRemux(session),
           let address = PanuraCastServer.proxyURL(for: media.url),
           // **The track is in the address on purpose.** Changing it serves a
           // different stream at the same path, and a receiver holding the
           // previous playlist would answer the next load out of its own cache.
           let local = URL(string: address + "?a=\(session.chosen)") {
            muxed = session
            canMux = true
            var copy = media
            copy.url = local
            // The address ends `.m3u8` before the query, but say it anyway:
            // the Cast MIME type is chosen from this first and a wrong guess
            // is a refused load.
            copy.contentType = "hls"
            return copy
        }

        // Not muxing. Whether it was even *possible* is a different
        // question, and the switch needs the answer to both: offer it where it
        // could help, and say so where it was asked for and could not be done.
        canMux = await CastRemux.looksMuxable(media)
        muxUnavailable = wanted && canMux

        // **A stream the television cannot fetch at all.**
        //
        // `castHeaders` is deliberately narrower than `headers`: a session
        // cookie is bound to the address and user agent that obtained it, so
        // replaying it from a second device is worse than sending none — proven
        // by a TV getting HTTP 200 with a body reading "security error". Which
        // means a stream that *needs* one is a stream no television can open,
        // and forwarding it from here is the only way it reaches a Chromecast.
        // The phone is the device that holds the cookie.
        if needsPhoneHeaders(media),
           PanuraCastManager.shared.startServerForProxy(media),
           let address = PanuraCastServer.proxyURL(for: media.url),
           let local = URL(string: address) {
            var copy = media
            copy.url = local
            if CastAudioMaster.looksLikeHLS(media) { copy.contentType = "hls" }
            return copy
        }

        var prepared = await CastAudioMaster.prepare(media)
        if let track, let current = prepared, current.chosen != track {
            prepared = CastAudioMaster.reselect(current, to: track) ?? prepared
        }
        audio = prepared
        return prepared?.send ?? media
    }

    /// Whether this stream is gated by something a television cannot send.
    ///
    /// Any header the app would use itself but keeps off a second device —
    /// `Origin`, a `Cookie`. When the two sets are equal, which is the ordinary
    /// case, nothing is being withheld and the television can fetch for itself.
    private func needsPhoneHeaders(_ media: MediaItem) -> Bool {
        guard !media.headers.isEmpty else { return false }
        let forTV = Set(media.castHeaders.keys.map { $0.lowercased() })
        return media.headers.keys.contains { !forTV.contains($0.lowercased()) }
    }

    private func play(_ item: CastQueueItem, auto: Bool) async {
        switch item.payload {
        case let .stream(media):
            stage = .sending(title: item.title, device: deviceName ?? "the TV")
            if PanuraCastManager.shared.isTVConnected {
                PanuraCastManager.shared.cast(media)
            } else {
                // Chromecast only. A multi-audio HLS master is rewritten to a
                // single audio track first, because the Cast hardware this is
                // aimed at — a Chromecast built into an Android 6 or 7
                // television — cannot play alternate audio renditions at all.
                // Panura's own receiver can, and is handed the original above.
                // nil means there was nothing to change. See `CastAudioMaster`.
                sent = media
                let payload = await chromecastPayload(media, track: nil)
                let subtitles = await Self.subtitles(for: media)
                // A Cast session that has gone between the tap and here is
                // the one case worth reporting: the old code said "playing"
                // over a load that never left the phone.
                guard CastManager.shared.cast(payload, advertise: !auto, subtitles: subtitles) else {
                    stage = .failed("Lost the connection to \(deviceName ?? "the TV").")
                    return
                }
            }
            stage = .playing
        case let .photo(identifier):
            stage = .reading(title: item.title)
            guard let file = await LocalVideosModel.resolveURL(localIdentifier: identifier) else {
                stage = .failed("Could not read \(item.title).")
                return
            }
            pending = (file, item.title, item.id)
            await run(file: file, title: item.title, id: item.id, forceOriginal: false, auto: auto)
        }
    }

    /// Sends a file from this phone to whichever TV is connected.
    ///
    /// The caller has already resolved the file — reading it out of the photo
    /// library is the library's job, not this one's.
    func send(file: URL, title: String, id: String) {
        work?.cancel()
        pending = (file, title, id)
        showing = true
        work = Task { await run(file: file, title: title, id: id, forceOriginal: false) }
    }

    /// Announces that a video is being fetched before there is a file to send.
    /// Separate call because iCloud can make that step the long one.
    func beginReading(title: String) {
        stage = .reading(title: title)
        showing = true
    }

    /// Abandons a conversion and sends the file as it is.
    ///
    /// Some televisions do handle Dolby Vision correctly and there is no way to
    /// ask which: a set that renders it as noise still reports a perfectly
    /// successful playback. The person watching is the only reliable judge, so
    /// their answer is taken and remembered for that TV.
    func sendOriginal() {
        guard let pending else { return }
        if let tv = deviceName { CastPreferences.allowOriginal(on: tv) }
        work?.cancel()
        work = Task {
            await run(file: pending.file, title: pending.title, id: pending.id, forceOriginal: true)
        }
    }

    /// The language picked for a local file, or nil to give up.
    func pickAudio(_ option: CastLocalMedia.AudioOption?) {
        audioChoice?.resume(returning: option)
        audioChoice = nil
    }

    private func chooseAudio(
        title: String, options: [CastLocalMedia.AudioOption]
    ) async -> CastLocalMedia.AudioOption? {
        stage = .choosingAudio(title: title, options: options)
        return await withCheckedContinuation { audioChoice = $0 }
    }

    func answerConversion(_ answer: ConversionAnswer) {
        conversionAnswer?.resume(returning: answer)
        conversionAnswer = nil
    }

    func cancel() {
        pickAudio(nil)
        answerConversion(.cancel)
        conversionJob?.cancel()
        conversionJob = nil
        work?.cancel()
        work = nil
        pending = nil
        stage = .idle
        showing = false
    }

    /// Clears a finished or failed attempt without closing anything that is
    /// actually playing.
    func settle() {
        if case .failed = stage { stage = .idle }
    }

    private var deviceName: String? {
        let panura = PanuraCastManager.shared
        if panura.isTVConnected, !panura.connectedTVName.isEmpty { return panura.connectedTVName }
        return CastManager.shared.connectedDeviceName
    }

    private func run(
        file: URL, title: String, id: String, forceOriginal: Bool, auto: Bool = false
    ) async {
        let panura = PanuraCastManager.shared
        let toPanura = panura.isTVConnected
        let device = deviceName ?? "the TV"
        var url = file

        // Trusted TVs, and anything the file proves is safe, skip straight past
        // conversion. An H.264 clip never waits.
        let target: CastTranscoder.Target = toPanura ? .panura : .chromecast

        // Some things cannot be sent at all and cannot be fixed here either.
        // Saying so beats letting the TV go black, and the message names the
        // path that does work.
        if let blocker = CastTranscoder.blocker(for: file, target: target) {
            stage = .failed(blocker)
            return
        }

        // **Sound and subtitles, for a Chromecast only.** Panura on Android TV
        // plays the file as it is — languages, surround and embedded
        // subtitles included. A Chromecast plays the first audio track, cannot
        // decode Dolby or more than two channels on the older sets, and reads
        // no subtitles out of a file. See `CastLocalMedia`.
        var subtitles: [(track: SubtitleTrack, url: URL)] = []
        var audioFix: CastLocalMedia.AudioOption?
        var audioReason: String?
        if !toPanura {
            let options = await CastLocalMedia.audioOptions(of: file)
            var chosen = options.first
            if options.count > 1 {
                guard let picked = await chooseAudio(title: title, options: options) else {
                    stage = .idle
                    return
                }
                chosen = picked
            }
            guard !Task.isCancelled else { return }
            if let chosen, CastLocalMedia.needsAudioFix(options, chosen: chosen) {
                audioFix = chosen
                audioReason = CastLocalMedia.explanation(options, chosen: chosen)
            }
            let embedded = await CastLocalMedia.embeddedSubtitles(of: file)
            subtitles = PanuraCastManager.shared.serveSubtitles(cues: embedded.map {
                (track: SubtitleTrack(url: file, label: $0.label, language: $0.language), cues: $0.cues)
            })
        }

        let trusted = forceOriginal || (deviceName.map(CastPreferences.allowsOriginal(on:)) ?? false)
        var videoReason = trusted ? nil : await CastTranscoder.reason(for: file, target: target)
        // The sound copy is an MP4 already, so a wrapper that was only wrong
        // for being QuickTime is fixed along the way.
        if audioFix != nil, videoReason == .containerForChromecast { videoReason = nil }

        let audioID = audioFix.map { id + "-a\($0.id)" }
        let videoID = audioID.map { $0 + "-v" } ?? id
        let finalID = videoReason != nil ? videoID : audioID

        if let finalID {
            let explanation = [audioReason, videoReason?.explanation].compactMap { $0 }.joined(separator: " ")
            let job: () -> Task<URL, Error> = { [audioFix, videoReason] in
                Task { [weak self] in
                    guard let self else { throw CastTranscoder.Failure.cancelled }
                    return try await self.prepare(
                        file: file, id: id, audioFix: audioFix,
                        videoReason: videoReason, videoID: videoID
                    )
                }
            }

            // Converted before: nothing to do, so nothing to ask.
            if CastTranscoder.isCached(finalID) {
                guard let ready = try? await job().value else {
                    stage = .failed("Could not convert that video for the TV.")
                    return
                }
                url = ready
            } else {
                // Offered, then converted under a rewarded ad. The work starts
                // with the ad rather than after it, so the wait and the ad are
                // the same minute; closing the ad early abandons both and puts
                // the offer back.
                while true {
                    stage = .offerConversion(
                        title: title, explanation: explanation,
                        overridable: videoReason?.isDisplayJudgement ?? false
                    )
                    let answer = await withCheckedContinuation { conversionAnswer = $0 }
                    switch answer {
                    case .cancel:
                        stage = .idle
                        return
                    case .original:
                        if let tv = deviceName { CastPreferences.allowOriginal(on: tv) }
                        await run(file: file, title: title, id: id, forceOriginal: true, auto: auto)
                        return
                    case .convert:
                        break
                    }

                    stage = .converting(title: title, explanation: explanation, progress: 0, overridable: false)
                    let running = job()
                    conversionJob = running
                    let earned = await withCheckedContinuation { done in
                        AdManager.shared.showRewarded(for: .conversion) { done.resume(returning: $0) }
                    }
                    guard earned else {
                        running.cancel()
                        _ = try? await running.value
                        conversionJob = nil
                        continue
                    }
                    do {
                        url = try await running.value
                        conversionJob = nil
                    } catch CastTranscoder.Failure.cancelled {
                        conversionJob = nil
                        stage = .idle
                        return
                    } catch {
                        conversionJob = nil
                        stage = .failed("Could not convert that video for the TV.")
                        return
                    }
                    break
                }
            }
        }
        guard !Task.isCancelled else { return }

        stage = .sending(title: title, device: device)
        if toPanura {
            panura.castLocal(file: url, title: title)
        } else {
            CastManager.shared.castLocalFile(url, title: title, advertise: !auto, subtitles: subtitles)
        }
        stage = .playing
    }

    /// Every conversion a file needs, in order: the sound first, because the
    /// picture's conversion then works from a file that already has the
    /// right track and nothing else.
    private func prepare(
        file: URL, id: String, audioFix: CastLocalMedia.AudioOption?,
        videoReason: CastTranscoder.Reason?, videoID: String
    ) async throws -> URL {
        var url = file
        if let audioFix {
            url = try await CastLocalMedia.stereoCopy(file, audio: audioFix.id, id: id) { [weak self] value in
                Task { @MainActor in self?.advance(progress: value) }
            }
        }
        if let videoReason {
            url = try await CastTranscoder.convert(
                url, id: videoID, repackageOnly: videoReason.isRepackageOnly
            ) { [weak self] value in
                Task { @MainActor in self?.advance(progress: value) }
            }
        }
        return url
    }

    /// Only touches the progress of a conversion still in flight — a late
    /// callback must not drag a finished cast back to "converting".
    private func advance(progress: Float) {
        guard case let .converting(title, explanation, _, overridable) = stage else { return }
        stage = .converting(
            title: title, explanation: explanation, progress: progress, overridable: overridable
        )
    }
}

extension CastFlow {
    /// Wraps a detected stream for the queue.
    ///
    /// The `MediaItem` is carried whole, headers included, because the TV is
    /// deliberately not told anything in advance: it is a receiver, and every
    /// decision about what plays next — the URL, the referer, which user agent
    /// to claim — is made on this phone at the moment it hands the next one
    /// over. A queue the TV knew about would be a queue that needed the TV's
    /// agreement to change.
    static func item(for media: MediaItem) -> CastQueueItem {
        CastQueueItem(
            id: media.id, title: media.title, payload: .stream(media),
            posterURL: media.thumbnailURL
        )
    }
}
