import SwiftUI
import UIKit

/// Which third of the screen a touch fell in.
enum PlayerZone { case left, center, right }

/// Full-screen transparent touch layer for the player, built on UIKit gesture
/// recognizers because SwiftUI's gesture system can't cleanly express
/// single-vs-double tap, axis-locked pans, and a hold-to-boost long-press all at
/// once. Buttons in the SwiftUI controls sit *above* this view, so their taps are
/// hit-tested first and never reach these recognizers.
struct PlayerGestureSurface: UIViewRepresentable {
    var onSingleTap: () -> Void = {}
    var onDoubleTap: (PlayerZone) -> Void = { _ in }
    var onSeekBegan: () -> Void = {}
    var onSeekChanged: (CGFloat) -> Void = { _ in }   // cumulative dx / width  (-1…1)
    var onSeekEnded: () -> Void = {}
    var onVerticalBegan: (PlayerZone) -> Void = { _ in }  // .left = brightness, .right = volume
    var onVerticalChanged: (CGFloat) -> Void = { _ in }   // cumulative -dy / height
    var onVerticalEnded: () -> Void = {}
    var onLongPressBegan: () -> Void = {}
    var onLongPressEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let c = context.coordinator

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.single(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.double(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)   // a double tap must not also fire the single

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1

        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.long(_:)))
        long.minimumPressDuration = 0.45

        for g in [single, double, pan, long] { g.delegate = c; v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureSurface
        private enum Axis { case undecided, horizontal, vertical }
        private var axis: Axis = .undecided
        private var zone: PlayerZone = .center

        init(_ parent: PlayerGestureSurface) { self.parent = parent }

        @objc func single(_ g: UITapGestureRecognizer) { parent.onSingleTap() }

        @objc func double(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            let x = g.location(in: v).x, w = v.bounds.width
            parent.onDoubleTap(x < w * 0.4 ? .left : (x > w * 0.6 ? .right : .center))
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                axis = .undecided
                zone = g.location(in: v).x < v.bounds.width / 2 ? .left : .right
            case .changed:
                if axis == .undecided {
                    if abs(t.x) > 12, abs(t.x) > abs(t.y) {
                        axis = .horizontal; parent.onSeekBegan()
                    } else if abs(t.y) > 12, abs(t.y) > abs(t.x) {
                        axis = .vertical; parent.onVerticalBegan(zone)
                    }
                }
                switch axis {
                case .horizontal: parent.onSeekChanged(t.x / max(1, v.bounds.width))
                case .vertical:   parent.onVerticalChanged(-t.y / max(1, v.bounds.height))
                case .undecided:  break
                }
            case .ended, .cancelled, .failed:
                switch axis {
                case .horizontal: parent.onSeekEnded()
                case .vertical:   parent.onVerticalEnded()
                case .undecided:  break
                }
                axis = .undecided
            default: break
            }
        }

        @objc func long(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onLongPressBegan()
            case .ended, .cancelled, .failed: parent.onLongPressEnded()
            default: break
            }
        }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
