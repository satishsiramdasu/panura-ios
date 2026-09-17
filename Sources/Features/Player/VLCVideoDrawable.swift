import Foundation
import UIKit
import VLCKit

/// What libVLC draws into, and how VLCKit 4 offers Picture in Picture.
///
/// In 3.x the drawable was a plain UIView, and the system PiP could not take
/// it: AVKit only floats an `AVPlayerLayer` or an `AVSampleBufferDisplayLayer`,
/// and libVLC exposed neither. VLCKit 4 renders through a sample-buffer display
/// layer itself, and turns PiP on when the drawable is an object that answers
/// the two protocols below — the same shape VLC for iOS uses. So the picture
/// still lands in the player's own view, through `addSubview`, while PiP gets a
/// controller (`pictureInPictureReady`) and a way to drive playback
/// (`mediaController`).
///
/// Not main-actor isolated: libVLC calls these from outside Swift concurrency.
/// VLC for iOS touches the view directly from the same callbacks.
final class VLCVideoDrawable: NSObject {
    /// The player's video view; the vout view is added inside it.
    weak var container: UIView?
    weak var player: VLCMediaPlayer?
    /// The model's corrected length, in milliseconds; 0 when unknown. Kept here
    /// because PiP asks from outside the main actor, and libVLC's own length is
    /// the value that needed correcting.
    var lengthMs: Int64 = 0

    /// Handed the PiP controller once the video output can float, and told
    /// whenever PiP starts or stops.
    var onPictureInPictureReady: ((VLCPictureInPictureWindowControlling) -> Void)?
    var onPictureInPictureChanged: ((Bool) -> Void)?

    init(container: UIView, player: VLCMediaPlayer) {
        self.container = container
        self.player = player
    }
}

extension VLCVideoDrawable: VLCDrawable {
    func addSubview(_ view: UIView!) {
        guard let view, let container else { return }
        view.frame = container.bounds
        // Rotation resizes the container; the picture has to follow it.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }

    func bounds() -> CGRect {
        container?.bounds ?? UIScreen.main.bounds
    }
}

extension VLCVideoDrawable: VLCPictureInPictureDrawable {
    func mediaController() -> VLCPictureInPictureMediaControlling! {
        self
    }

    func pictureInPictureReady() -> ((VLCPictureInPictureWindowControlling?) -> Void)! {
        { [weak self] controller in
            guard let self, let controller else { return }
            controller.stateChangeEventHandler = { [weak self] started in
                self?.onPictureInPictureChanged?(started)
            }
            self.onPictureInPictureReady?(controller)
        }
    }
}

/// The PiP window's own play/pause/skip buttons and its progress bar. Times
/// are milliseconds throughout, as libVLC counts them.
extension VLCVideoDrawable: VLCPictureInPictureMediaControlling {
    func play() { player?.play() }

    func pause() { player?.pause() }

    func seek(by offset: Int64, completion: (() -> Void)!) {
        guard let player else { completion?(); return }
        _ = player.jump(withOffset: Int32(clamping: offset), completion: completion)
    }

    func mediaLength() -> Int64 {
        lengthMs > 0 ? lengthMs : (player?.media?.length.value?.int64Value ?? 0)
    }

    func mediaTime() -> Int64 {
        player?.time.value?.int64Value ?? 0
    }

    func isMediaSeekable() -> Bool {
        player?.isSeekable ?? false
    }

    func isMediaPlaying() -> Bool {
        player?.isPlaying ?? false
    }
}
