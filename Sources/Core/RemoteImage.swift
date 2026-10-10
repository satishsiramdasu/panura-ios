import SwiftUI

/// `AsyncImage`, with the cache it does not have.
///
/// Deliberately the same shape as the thing it replaces — both initialisers,
/// and a phase enum with the same case names — so a call site changes by one
/// word and the `switch` inside it is untouched. The point is that every
/// remote picture in the app goes through `ImageStore`; making each one think
/// about caching would guarantee that some of them did not.
///
/// What it does differently, beyond the cache:
///
/// - **Draws a cached picture on the first frame.** `AsyncImage` always starts
///   at `.empty` and arrives at the image a frame or two later, so scrolling
///   back over a grid you have already seen flashes placeholders at pictures
///   that are sitting in memory. A synchronous cache read in `init` means a
///   hit is simply already there.
/// - **Keeps nothing of its own.** The image lives in the store, so a tile
///   torn down by a `LazyVGrid` costs nothing to rebuild.
struct RemoteImage<Content: View>: View {
    enum Phase {
        case empty
        case success(Image)
        case failure
    }

    private let url: URL?
    private let content: (Phase) -> Content

    @State private var loaded: UIImage?
    @State private var failed = false

    init(url: URL?, @ViewBuilder content: @escaping (Phase) -> Content) {
        self.url = url
        self.content = content
        // A hit is drawn on frame one rather than after a state change.
        _loaded = State(initialValue: url.flatMap { ImageStore.shared.cached($0) })
    }

    var body: some View {
        content(phase)
            // Keyed on the URL: a recycled row handed a different poster must
            // start again rather than keep showing the last one.
            .task(id: url) { await load() }
    }

    private var phase: Phase {
        if let loaded { return .success(Image(uiImage: loaded)) }
        return failed ? .failure : .empty
    }

    private func load() async {
        guard let url else {
            loaded = nil
            failed = false
            return
        }
        if let hit = ImageStore.shared.cached(url) {
            loaded = hit
            failed = false
            return
        }
        loaded = nil
        failed = false
        let image = await ImageStore.shared.image(for: url)
        // The row may have been handed a different URL while this was in the
        // air; `task(id:)` cancels, but a cancelled task still returns here.
        guard !Task.isCancelled else { return }
        loaded = image
        failed = image == nil
    }
}

extension RemoteImage {
    /// The content/placeholder form, for the call sites that never cared about
    /// the difference between "not yet" and "never".
    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if case let .success(image) = phase {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}
