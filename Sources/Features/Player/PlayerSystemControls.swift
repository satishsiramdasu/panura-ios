import UIKit
import SwiftUI
import AVFoundation
import MediaPlayer

/// System volume control for the right-side vertical drag.
///
/// iOS exposes no public setter for the hardware volume, but an `MPVolumeView`
/// in the hierarchy carries a `UISlider` whose `value` *is* the system volume —
/// and mutating it changes volume without the OS HUD popping (having the view
/// mounted also suppresses the default HUD when the physical buttons are used).
/// The view is parked off-screen; it must stay un-hidden and attached to work.
@MainActor
final class SystemVolume {
    static let shared = SystemVolume()

    let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    private init() {
        volumeView.showsVolumeSlider = true
        volumeView.showsRouteButton = false
        volumeView.alpha = 0.001
    }

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    /// Current output volume (0…1).
    var level: Float { AVAudioSession.sharedInstance().outputVolume }

    func set(_ value: Float) {
        let v = max(0, min(1, value))
        // Defer a hair so the slider exists after the view is first mounted.
        DispatchQueue.main.async { [weak self] in self?.slider?.value = v }
    }
}

/// Screen brightness for the left-side vertical drag. Trivial wrapper that also
/// restores the user's original brightness when the player closes.
@MainActor
enum ScreenBrightness {
    private static var saved: CGFloat?

    static var level: CGFloat { UIScreen.main.brightness }

    static func set(_ value: CGFloat) {
        if saved == nil { saved = UIScreen.main.brightness }
        UIScreen.main.brightness = max(0, min(1, value))
    }

    static func restore() {
        if let s = saved { UIScreen.main.brightness = s; saved = nil }
    }
}

/// Mounts the off-screen `MPVolumeView` so `SystemVolume` can drive it. Placed
/// once inside the player; renders nothing visible.
struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { SystemVolume.shared.volumeView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
