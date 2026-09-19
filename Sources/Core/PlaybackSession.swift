import SwiftUI

/// The video that is playing, and whether its screen is on top of the app.
///
/// **Why playback moved out of the player screen.** `PlayerView` used to own its
/// engine (`@StateObject`) and stop it in `onDisappear`, so the screen *was* the
/// playback — dismissing it ended the video. That is why Picture in Picture kept
/// the player up: the moment the screen went away, so did the thing PiP was
/// showing. The result was a PiP window floating over a full-screen player that
/// said the video was in PiP, with nothing to do but close it.
///
/// So the session outlives the screen. Playback starts here, the engine and its
/// video surface belong here, and the player screen becomes one way of looking
/// at it — full screen, or as the bar above the app bar while PiP or a TV has
/// the picture.
///
/// One presenter, in `RootTabView`, for the same reason: the bar has to be able
/// to bring the player back, and a cover owned by whichever screen happened to
/// start the video cannot be reopened once the user has walked away from it.
@MainActor
final class PlaybackSession: ObservableObject {
    static let shared = PlaybackSession()

    /// What is playing, with the list it came from so next/previous still work
    /// after the screen has been dismissed and rebuilt.
    struct Playing: Identifiable {
        let item: MediaItem
        let playlist: PlayerPlaylist?
        /// New for every `play`, so re-presenting the same URL still rebuilds
        /// the screen rather than being treated as the one already showing.
        let id = UUID()
    }

    /// Set to present the player, nil to take it down. The full-screen cover in
    /// `RootTabView` is bound to this.
    @Published var presented: Playing?

    /// What is still playing while `presented` is nil — PiP, or audio in the
    /// background. Drives the bar, and is what tapping it brings back.
    @Published private(set) var minimized: Playing?

    /// True from the moment PiP is asked for until the player screen has gone.
    ///
    /// The screen's `onDisappear` cannot tell a dismissal that means "stop this
    /// video" from one that means "the picture moved to the PiP window", and
    /// getting that wrong either kills PiP instantly or leaves an engine
    /// playing into nothing. This flag is the difference.
    @Published private(set) var handingOffToPiP = false

    /// The live engine, kept here so it survives the screen. Exactly one is
    /// non-nil while something is playing.
    ///
    /// Two properties rather than one `any PlayerEngine`: `PlayerView` is
    /// generic over its model and an existential cannot be handed to it without
    /// a type-eraser that would have to forward every published property.
    @Published private(set) var apple: AVPlayerModel?
    @Published private(set) var vlc: VLCPlayerModel?

    /// The engine's own view, retained across presentations.
    ///
    /// It has to outlive the screen for PiP to survive at all, and the two
    /// engines need it for different reasons. `AVPictureInPictureController`
    /// retains its `AVPlayerLayer`, but the layer belongs to this view and a new
    /// screen would build a second one, leaving the controller pointing at the
    /// old. VLCKit holds its PiP controller *weakly* from the drawable, so
    /// losing this view ends PiP outright.
    private(set) var videoView: UIView?

    private init() {}

    var isPlayingSomething: Bool { presented != nil || minimized != nil }

    /// The item behind the bar, whichever state it is in.
    var currentItem: MediaItem? { (presented ?? minimized)?.item }

    // MARK: starting and stopping

    /// Every screen plays through this rather than presenting its own cover.
    func play(_ item: MediaItem, playlist: PlayerPlaylist? = nil) {
        // A new video replaces whatever was in the background; two engines
        // running at once is two soundtracks.
        if minimized != nil { stop() }
        presented = Playing(item: item, playlist: playlist)
    }

    /// The player screen is going away and the video is going with it.
    func stop() {
        apple?.stop()
        vlc?.stop()
        apple = nil
        vlc = nil
        videoView = nil
        minimized = nil
        presented = nil
        handingOffToPiP = false
    }

    /// Bring the full-screen player back — the bar tapped, or PiP asking to
    /// restore.
    func restore() {
        guard let minimized else { return }
        handingOffToPiP = false
        self.minimized = nil
        presented = minimized
    }

    // MARK: PiP hand-off

    /// PiP is starting: the screen should come down and playback should not.
    func beginPictureInPicture() {
        guard presented != nil else { return }
        handingOffToPiP = true
    }

    /// Called by the player screen as it disappears. Returns true when the
    /// engine must be left alone.
    func screenDismissed() -> Bool {
        guard handingOffToPiP, let presented else {
            stop()
            return false
        }
        minimized = presented
        self.presented = nil
        handingOffToPiP = false
        return true
    }

    // MARK: engines

    /// Vends the engine for this playback, building it once. `makeEngine()` on
    /// each model routes here, so a player screen rebuilt after PiP adopts the
    /// engine that is already playing instead of starting a second one.
    func appleEngine() -> AVPlayerModel {
        if let apple { return apple }
        let model = AVPlayerModel()
        apple = model
        return model
    }

    func vlcEngine() -> VLCPlayerModel {
        if let vlc { return vlc }
        let model = VLCPlayerModel()
        vlc = model
        return model
    }

    /// The engine's view, built on first use and kept afterwards. `started`
    /// says whether playback has already been handed this view — a screen
    /// rebuilt from PiP must adopt it rather than call `start` again, which
    /// would seek the video back to nothing.
    func surface(_ make: () -> UIView, start: (UIView) -> Void) -> UIView {
        if let videoView { return videoView }
        let view = make()
        videoView = view
        start(view)
        return view
    }
}
