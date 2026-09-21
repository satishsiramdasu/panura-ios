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
        case converting(title: String, explanation: String, progress: Float)
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

    private var work: Task<Void, Never>?
    /// What the current attempt is about, so "Send original" can carry on with
    /// the same video after abandoning its conversion.
    private var pending: (file: URL, title: String, id: String)?

    private init() {}

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

    private func run(file: URL, title: String, id: String, forceOriginal: Bool) async {
        let panura = PanuraCastManager.shared
        let toPanura = panura.isTVConnected
        let device = deviceName ?? "the TV"
        var url = file

        // Trusted TVs, and anything the file proves is safe, skip straight past
        // conversion. An H.264 clip never waits.
        let trusted = forceOriginal || (deviceName.map(CastPreferences.allowsOriginal(on:)) ?? false)
        if !trusted {
            let target: CastTranscoder.Target = toPanura ? .panura : .chromecast
            if let reason = await CastTranscoder.reason(for: file, target: target) {
                stage = .converting(title: title, explanation: reason.explanation, progress: 0)
                do {
                    url = try await CastTranscoder.convert(file, id: id) { [weak self] value in
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
            CastManager.shared.castLocalFile(url, title: title)
        }
        stage = .playing
    }

    /// Only touches the progress of a conversion still in flight — a late
    /// callback must not drag a finished cast back to "converting".
    private func advance(progress: Float) {
        guard case let .converting(title, explanation, _) = stage else { return }
        stage = .converting(title: title, explanation: explanation, progress: progress)
    }
}
