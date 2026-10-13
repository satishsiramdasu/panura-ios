import SwiftUI
import GoogleMobileAds

/// The banner, as the app's bottom edge.
///
/// Attached **outermost**, below everything, as the shell's own bottom inset.
/// `safeAreaInset` composes, so an inset applied on the outside sits lowest on
/// screen and every inset applied inside stacks above it — which means the
/// browser's found-video bar and the cast bar end up above this one for free,
/// with no change to either. They are pushed up by it; it is never pushed down
/// or drawn over.
///
/// That order is the whole point. The found-video bar is Play, Cast and Watch
/// Later at the exact moment the app has done its job; an ad covering it is
/// what turns a detection app into an ad app.
///
/// **Nothing is needed for the player.** It arrives as a `fullScreenCover`
/// presented above the shell entirely, so the banner is absent during playback
/// without a single conditional — which matters, because a banner under
/// full-screen video is both a policy problem and the fastest route to an
/// uninstall.
struct BannerStrip: View {
    @State private var height: CGFloat = 0

    var body: some View {
        Group {
            if AdPolicy.allowsBanner {
                GeometryReader { geo in
                    BannerHost(width: geo.size.width) { measured in
                        // Only grow. A banner that reports zero mid-refresh
                        // would otherwise collapse the strip and shove every
                        // screen's content down and back up again.
                        guard measured > height else { return }
                        // On the next turn of the run loop, not now: this is
                        // called from `makeUIView`/`updateUIView`, and writing
                        // `@State` while SwiftUI is updating the view that owns
                        // it is undefined — at best a purple warning, at worst
                        // a layout loop between the height and the geometry
                        // that produced it.
                        DispatchQueue.main.async { height = measured }
                    }
                }
                .frame(height: height)
                // The banner is pinned to the top of a container that is zero
                // points tall for the first frame, before a height is known.
                // Clipped so it cannot draw over the screen above it in the
                // meantime.
                .clipped()
            }
        }
    }
}

/// Hosts the one long-lived `BannerView` without ever rebuilding it.
///
/// `AdManager` owns the view for the life of the process; this only puts it on
/// screen. Making a new one per appearance would fire an ad request on every
/// tab switch — inside the 30-second floor for repeat requests on a unit,
/// which is invalid-traffic territory — and a view that short-lived never
/// survives to the refresh cycle where banner revenue accumulates.
private struct BannerHost: UIViewRepresentable {
    let width: CGFloat
    let onHeight: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        guard let banner = AdManager.shared.bannerView(
            width: width,
            root: container.window?.rootViewController
        ) else { return }
        if banner.superview !== container {
            banner.removeFromSuperview()
            banner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                banner.topAnchor.constraint(equalTo: container.topAnchor),
            ])
        }
        let measured = banner.adSize.size.height
        if measured > 0 { onHeight(measured) }
    }
}
