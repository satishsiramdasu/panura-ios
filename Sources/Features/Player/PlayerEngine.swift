import SwiftUI
import UIKit
import AVKit

// MARK: - Shared value types
//
// Both engines publish these, so the control overlay never names an engine.
// They began life nested inside VLCPlayerModel; `VLCPlayerModel.Track` and
// friends remain as typealiases, so nothing there had to change.

struct PlayerTrack: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// A selectable HLS rendition. `url == nil` means Auto (adaptive = the master).
struct PlayerQuality: Identifiable, Hashable {
    let id: String
    let label: String
    let url: URL?
    /// Advertised bits/sec, for the size estimate. 0 when unknown or Auto.
    var bandwidth: Int = 0
    /// Vertical resolution from the master playlist; 0 when it names none.
    var height: Int = 0

    static let auto = PlayerQuality(id: "auto", label: "Auto", url: nil)

    /// Rough download size at this bitrate, matching Android's
    /// `HlsVariant.estimatedSize`: bandwidth is an average, so this is an
    /// approximation and is labelled as one. Empty when either input is
    /// unknown — a live stream has no duration, so no estimate is shown.
    func sizeEstimate(durationSeconds: Double) -> String {
        guard durationSeconds > 0, bandwidth > 0 else { return "" }
        let bytes = Double(bandwidth) / 8 * durationSeconds
        switch bytes {
        case 1_000_000_000...:
            return String(format: "~%.1f GB", bytes / 1_000_000_000)
        case 1_000_000...:
            return String(format: "~%.0f MB", bytes / 1_000_000)
        default:
            return String(format: "~%.0f KB", bytes / 1_000)
        }
    }
}

enum PlayerAspectMode: String, CaseIterable {
    case fit, fill, stretch

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var icon: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum PlayerClock {
    /// "4:07" · "1:02:45". Non-finite input — a live stream's duration — reads
    /// as zero rather than crashing the Int conversion.
    static func format(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds)) : 0
        let (h, m, s) = (whole / 3600, (whole % 3600) / 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - The engine contract

/// Everything `PlayerView` asks of a player, and nothing more.
///
/// The control overlay — gestures, sheets, quick actions, the auto-hide — was
/// written against VLCPlayerModel's surface and matches Android's player. This
/// protocol is that surface, lifted out, so the overlay can sit on AVPlayer
/// without being rewritten: `PlayerView` is generic over it, and each engine
/// supplies the same published state.
///
/// The `supports…` flags are how an engine declines a control it cannot honour.
/// The overlay hides that row rather than offering a slider that does nothing.
@MainActor
protocol PlayerEngine: ObservableObject {
    /// A factory rather than an `init()` requirement, which a final NSObject
    /// subclass could only meet through NSObject's inherited initialiser.
    /// Main-actor isolated like the models it builds: `@StateObject`'s initial
    /// value in PlayerView is evaluated on the main actor, and marking this
    /// nonisolated is exactly what the compiler rejects — it would construct a
    /// main-actor model from outside the actor.
    static func makeEngine() -> Self

    // Playback state
    var isPlaying: Bool { get }
    var position: Float { get }
    var displayTitle: String { get }
    var elapsed: String { get }
    var remaining: String { get }
    var total: String { get }
    var buffering: Bool { get }
    var failure: String? { get }
    var resumeEntryRemoved: Bool { get }
    var rate: Float { get }
    var totalSeconds: Double { get }
    var elapsedSeconds: Double { get }
    var skipInterval: Int { get }
    var videoIsPortrait: Bool? { get }

    // Tracks, sync, picture
    var audioTracks: [PlayerTrack] { get }
    var subtitleTracks: [PlayerTrack] { get }
    var currentAudioId: Int { get }
    var currentSubtitleId: Int { get }
    var aspect: PlayerAspectMode { get }
    var subtitleDelayMs: Int { get }
    var audioDelayMs: Int { get }
    var audioBoost: Int { get }
    var qualities: [PlayerQuality] { get }
    var currentQualityId: String { get }
    var sleepRemaining: Int? { get }
    var sleepLabel: String? { get }
    /// Subtitle text for the view to draw itself, or nil. Only an engine that
    /// cannot render a file's subtitles into the picture ever sets it.
    var overlaySubtitle: String? { get }

    // What this engine can do
    var supportsAudioDelay: Bool { get }
    var supportsAudioBoost: Bool { get }
    var supportsSubtitleDelay: Bool { get }
    var supportsPictureInPicture: Bool { get }
    var supportsAirPlay: Bool { get }
    var isPictureInPictureActive: Bool { get }

    // Lifecycle
    func makeVideoView() -> UIView
    func start(item: MediaItem, into view: UIView)
    func play(item: MediaItem)
    func stop()

    // Transport
    func togglePlay()
    func skipForward()
    func skipBackward()
    func seek(to fraction: Float)
    func setRate(_ r: Float)
    func beginSpeedBoost()
    func endSpeedBoost()

    // Tracks, sync, picture
    func selectAudio(_ id: Int)
    func selectSubtitle(_ id: Int)
    func applyPreferredLanguages()
    func selectQuality(_ q: PlayerQuality)
    func cycleAspect()
    func adjustSubtitleDelay(_ deltaMs: Int)
    func adjustAudioDelay(_ deltaMs: Int)
    func setAudioBoost(_ percent: Int)
    /// A subtitle preference changed while playing. VLC has to reopen the media
    /// for its text renderer to read the new style; AVPlayer restyles in place.
    func subtitleStyleChanged()
    func startSleepTimer(minutes: Int)
    func cancelSleepTimer()
    func togglePictureInPicture()
}

// MARK: - Engine choice

enum PlayerEngineKind: String, CaseIterable, Identifiable {
    case auto = "auto"
    case avPlayer = "av"
    case vlc = "vlc"

    /// A new key rather than the testing one: whoever picked a single engine
    /// while the two were compared starts on Auto, not on that old choice.
    static let defaultsKey = "player_engine_mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .avPlayer: return "Apple player"
        case .vlc: return "VLC"
        }
    }

    /// Containers the Apple player never reads, so Auto opens them in VLC at
    /// once instead of waiting for a failure. A hint only — sites disguise
    /// extensions (a playlist as .txt, segments as .css or .woff), which is why
    /// the hand-over also listens to the player itself.
    static func needsVLC(_ item: MediaItem) -> Bool {
        let path = item.url.path.lowercased()
        return ["mkv", "avi", "webm", "flv", "wmv", "rmvb", "ts", "mpg", "mpeg", "vob", "ogv", "divx"]
            .contains { path.hasSuffix("." + $0) }
    }
}

/// What every screen presents to play something, and where the engine is chosen.
///
/// Auto, the default, opens the Apple player — Picture in Picture, AirPlay, HDR,
/// hardware decoding — and hands the video to VLC without asking when the Apple
/// player cannot play it: a container it never reads, a stream it refuses, or
/// one it plays without ever showing a picture (HEVC inside MPEG-TS does that).
/// The user sees the video start, not a choice. Settings can still force
/// either engine; forced, the Apple player shows its error instead.
struct PlayerScreen: View {
    let item: MediaItem
    var playlist: PlayerPlaylist? = nil

    @AppStorage(PlayerEngineKind.defaultsKey)
    private var engine: String = PlayerEngineKind.auto.rawValue

    /// VLC taking over from the Apple player, and what it should open. Per
    /// presentation: the next video starts on the Apple player again.
    @State private var takeover: Takeover?

    private struct Takeover {
        let item: MediaItem
        let playlist: PlayerPlaylist?
        let reason: String
    }

    var body: some View {
        let kind = PlayerEngineKind(rawValue: engine) ?? .auto
        if let takeover {
            PlayerView<VLCPlayerModel>(item: takeover.item, playlist: takeover.playlist, switchReason: takeover.reason)
        } else if kind == .vlc {
            PlayerView<VLCPlayerModel>(item: item, playlist: playlist)
        } else if kind == .auto, PlayerEngineKind.needsVLC(item) {
            PlayerView<VLCPlayerModel>(item: item, playlist: playlist, switchReason: "extension")
        } else {
            PlayerView<AVPlayerModel>(
                item: item,
                playlist: playlist,
                onUnsupported: kind == .auto ? { index, reason in handOver(at: index, reason: reason) } : nil
            )
        }
    }

    /// VLC opens the video the Apple player was on — not necessarily the first,
    /// if the user had moved through a playlist.
    private func handOver(at index: Int, reason: String) {
        guard let playlist, index != playlist.startIndex else {
            takeover = Takeover(item: item, playlist: playlist, reason: reason)
            return
        }
        Task {
            if let current = await playlist.load(index) {
                takeover = Takeover(
                    item: current,
                    playlist: PlayerPlaylist(count: playlist.count, startIndex: index, load: playlist.load),
                    reason: reason
                )
            } else {
                takeover = Takeover(item: item, playlist: playlist, reason: reason)
            }
        }
    }
}

// MARK: - Hosting views

/// Hosts whichever surface the engine renders into, and starts playback once
/// it exists.
struct EngineVideoView<Model: PlayerEngine>: UIViewRepresentable {
    @ObservedObject var model: Model
    let item: MediaItem

    /// A container, with the engine's own view inside it.
    ///
    /// The engine's view belongs to `PlaybackSession` and outlives this screen —
    /// PiP dies with it, for both engines — so it cannot be what SwiftUI
    /// creates and destroys here. This container is; the surface is only
    /// borrowed into it, and re-parented back to the offscreen host when the
    /// player is dismissed with PiP still running.
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // Not while the screen is on its way out. SwiftUI keeps updating a view
        // that is being dismissed, and adopting the surface back into a dying
        // container is how a PiP hand-off undoes itself one frame after making
        // it.
        guard PlaybackSession.shared.presented != nil else { return }
        let surface = PlaybackSession.shared.surface(
            { model.makeVideoView() },
            start: { model.start(item: item, into: $0) }
        )
        guard surface.superview !== container else { return }
        surface.removeFromSuperview()
        // Adding it removes it from wherever it was, which is exactly the
        // hand-off: offscreen host to player, or player back to host.
        container.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// The system AirPlay picker, in the player's own colours. A system control
/// on purpose: it is the only way to list AirPlay receivers, and it is the
/// icon people already know.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(PanuraTheme.accent)
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Subtitle size against the screen, not the picture

/// Keeps a subtitle the same size on screen however big the picture is.
///
/// Both engines size subtitles as a fraction of the video, and both are right
/// to: that is what makes a subtitle look the same on a phone and a television.
/// It is wrong inside this app, because the picture is not the screen. A 16:9
/// video fills a landscape phone and then, rotated upright, becomes a strip
/// about half as tall — and the subtitles shrink with it, which is what was
/// reported. The video got smaller; the reader did not move.
///
/// So the fraction is divided by how tall the picture actually is, against the
/// height it was tuned at — a full-screen landscape video, which is the screen's
/// short side. In that case the factor is 1 and nothing changes, which is the
/// point: the common case must look exactly as it did.
///
/// `AVTextStyleRule` takes a percentage and libVLC takes a multiplier, so both
/// can use this number directly.
enum PlayerSubtitleScale {
    /// Beyond 3x the text stops being a subtitle and starts being a caption
    /// card. A picture that small is a thumbnail, not something being watched.
    static let maxFactor: CGFloat = 3

    static func factor(videoHeight: CGFloat) -> Double {
        let screen = UIScreen.main.bounds
        let reference = min(screen.width, screen.height)
        guard videoHeight > 1, reference > 1 else { return 1 }
        return Double(min(maxFactor, max(1, reference / videoHeight)))
    }
}
