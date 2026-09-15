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
    case avPlayer = "av"
    case vlc = "vlc"

    static let defaultsKey = "player_engine"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .avPlayer: return "Apple player"
        case .vlc: return "VLC"
        }
    }
}

/// What every screen presents to play something. Picks the engine, and owns
/// the one-tap fallback to VLC while the two are being compared.
///
/// ⚠️ Testing scaffold. When the Apple player ships alone (phase 6), this
/// collapses to `PlayerView<AVPlayerModel>`, the setting goes, and VLCKit
/// leaves the build — keeping it would keep its size.
struct PlayerScreen: View {
    let item: MediaItem
    var playlist: PlayerPlaylist? = nil

    @AppStorage(PlayerEngineKind.defaultsKey)
    private var engine: String = PlayerEngineKind.avPlayer.rawValue

    /// Set when the Apple player could not open this item and the user asked
    /// VLC to try. Per presentation: the next video starts on the chosen engine
    /// again, so one bad stream does not quietly change what gets tested.
    @State private var fellBackToVLC = false

    var body: some View {
        if fellBackToVLC || engine == PlayerEngineKind.vlc.rawValue {
            PlayerView<VLCPlayerModel>(item: item, playlist: playlist)
        } else {
            PlayerView<AVPlayerModel>(item: item, playlist: playlist, onFallback: { fellBackToVLC = true })
        }
    }
}

// MARK: - Hosting views

/// Hosts whichever surface the engine renders into, and starts playback once
/// it exists.
struct EngineVideoView<Model: PlayerEngine>: UIViewRepresentable {
    @ObservedObject var model: Model
    let item: MediaItem

    func makeUIView(context: Context) -> UIView {
        let view = model.makeVideoView()
        model.start(item: item, into: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
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
