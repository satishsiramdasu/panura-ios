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

    /// Where the surface waits while PiP has the picture: a view in the app's
    /// own window, not in any SwiftUI hierarchy.
    ///
    /// It was a SwiftUI overlay, and that is what broke PiP. Re-parenting could
    /// then only happen inside `updateUIView`, which SwiftUI runs *after* the
    /// cover has finished animating away — so the surface spent the whole
    /// dismissal with no window, and a layer with no window is a layer AVKit
    /// can drop. Parking is now a plain `addSubview` we can do in the same
    /// turn of the run loop that takes the screen down.
    private var parking: UIView?

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
        videoView?.removeFromSuperview()
        videoView = nil
        parking?.removeFromSuperview()
        parking = nil
        minimized = nil
        presented = nil
    }

    /// Bring the full-screen player back — the bar tapped, or PiP asking to
    /// restore.
    func restore() {
        guard let minimized else { return }
        self.minimized = nil
        presented = minimized
    }

    // MARK: PiP hand-off

    /// Picture in Picture has the picture: get the screen out of the way.
    ///
    /// **Call this on *did* start, never on *will*.** AVKit animates the PiP
    /// window out of the source layer's on-screen frame, so pulling that layer
    /// out of the window while the animation is still running aborts the start
    /// — PiP closes the instant it opens, which is exactly what shipped.
    ///
    /// The order inside matters as much: park the surface first, *then* take
    /// the cover down. The surface never stops having a window, so there is no
    /// window for AVKit to find missing.
    func beginPictureInPicture() {
        guard let playing = presented else { return }
        park()
        minimized = playing
        presented = nil
    }

    /// Moves the video surface into the window, out of the screen that is
    /// about to be destroyed.
    private func park() {
        guard let surface = videoView, let host = parkingView() else { return }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = host.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(surface)
    }

    /// A small view at the very back of the app's window. Behind every other
    /// view, so it is never seen, and in the window, so its layer is real.
    private func parkingView() -> UIView? {
        if let parking, parking.window != nil { return parking }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState != .background }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        host.isUserInteractionEnabled = false
        window.addSubview(host)
        window.sendSubviewToBack(host)
        parking = host
        return host
    }

    /// Called by the player screen as it disappears.
    ///
    /// By the time this runs a PiP hand-off has already moved the video into
    /// the background — `minimized` is how it says so. Anything else is a real
    /// dismissal and ends playback.
    func screenDismissed() {
        guard minimized == nil else { return }
        stop()
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
