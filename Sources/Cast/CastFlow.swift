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
        /// Handed over; waiting for the TV to pick it up.
        case sending(title: String, device: String)
        /// The TV has it. From here the controls take over.
        case playing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .reading, .converting, .sending: return true
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

    private var work: Task<Void, Never>?
    private var watchers: Set<AnyCancellable> = []
    /// What the current attempt is about, so "Send original" can carry on with
    /// the same video after abandoning its conversion.
    private var pending: (file: URL, title: String, id: String)?

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
        if queue.isEmpty {
            stage = .idle
        } else {
            advance(auto: true)
        }
    }

    private func play(_ item: CastQueueItem, auto: Bool) async {
        switch item.payload {
        case let .stream(media):
            stage = .sending(title: item.title, device: deviceName ?? "the TV")
            if PanuraCastManager.shared.isTVConnected {
                PanuraCastManager.shared.cast(media)
            } else {
                CastManager.shared.cast(media, advertise: !auto)
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

    func cancel() {
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

        let trusted = forceOriginal || (deviceName.map(CastPreferences.allowsOriginal(on:)) ?? false)
        if !trusted {
            if let reason = await CastTranscoder.reason(for: file, target: target) {
                stage = .converting(
                    title: title,
                    explanation: reason.explanation,
                    progress: 0,
                    overridable: reason.isDisplayJudgement
                )
                do {
                    url = try await CastTranscoder.convert(
                        file, id: id, repackageOnly: reason.isRepackageOnly
                    ) { [weak self] value in
                        Task { @MainActor in self?.advance(progress: value) }
                    }
                } catch CastTranscoder.Failure.cancelled {
                    stage = .idle
                    return
                } catch {
                    stage = .failed("Could not convert that video for the TV.")
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }

        stage = .sending(title: title, device: device)
        if toPanura {
            panura.castLocal(file: url, title: title)
        } else {
            CastManager.shared.castLocalFile(url, title: title, advertise: !auto)
        }
        stage = .playing
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
        CastQueueItem(id: media.id, title: media.title, payload: .stream(media))
    }
}
