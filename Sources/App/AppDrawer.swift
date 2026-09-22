import SwiftUI

/// Whether the navigation drawer is open, for the whole app.
///
/// A singleton rather than state passed down, because the control that opens it
/// is in `PanuraHeader` — which every screen builds for itself — while the
/// drawer is drawn once, at the root, beneath everything. Those two are as far
/// apart as two views in this app get.
@MainActor
final class DrawerState: ObservableObject {
    static let shared = DrawerState()
    @Published var isOpen = false
    private init() {}

    /// Wide enough to read a row and leave a hand's width of the app showing,
    /// so it is obvious what the drawer is covering and how to get back.
    static var width: CGFloat { min(UIScreen.main.bounds.width * 0.76, 320) }

    static var motion: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    func toggle() { withAnimation(Self.motion) { isOpen.toggle() } }
    func close() { withAnimation(Self.motion) { isOpen = false } }
}

/// The app's navigation: every destination, and everything that had nowhere
/// else to live.
///
/// It replaces the bottom bar. Three seats and a grid button could name three
/// places; a bar is also permanently spent screen — 64 points of every screen,
/// including the browser, where the page wants all of it. A drawer costs
/// nothing until it is asked for, has room to say what each row is for, and
/// puts Home, Browser and Videos in the same list as Settings and Stream
/// instead of splitting five destinations across two mechanisms.
///
/// The app slides sideways to reveal it rather than the drawer sliding over the
/// app, which is what makes it obvious the app is still there, behind, waiting.
struct AppDrawerPanel: View {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        /// What the row is for, in a few words. A glyph and a noun leave people
        /// guessing at exactly the rows they have never pressed.
        var detail: String = ""
        /// The tile behind the glyph. Each row keeps its own colour so the list
        /// can be found by shape rather than read top to bottom every time.
        var tint: Color = PanuraTheme.accent
        /// Drawn as where you are, rather than somewhere to go.
        var isCurrent: Bool = false
        let action: () -> Void
    }

    /// The five places you can be.
    let destinations: [Item]
    /// Everything else: casting, help, and the App Store.
    let actions: [Item]
    /// Opens About, from the card that already names the version.
    let onAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(destinations) { item in
                        Button(action: item.action) { row(item) }
                            .buttonStyle(.plain)
                    }

                    Divider()
                        .overlay(PanuraTheme.surfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                    ForEach(actions) { item in
                        Button(action: item.action) { row(item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanuraTheme.surfaceContainer.ignoresSafeArea())
    }

    /// Who this is - the same card About opens with, doing both jobs at once.
    ///
    /// The version used to be a line along the bottom edge, which is where a
    /// drawer usually puts it; the card states it anyway, so the footer was the
    /// same sentence twice with the height of the list between them. The info
    /// button goes straight to About rather than through Settings, because the
    /// card is what makes anyone want About in the first place.
    private var identity: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Panura").font(.title3.weight(.semibold))
                Text(Self.versionLine)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            Spacer(minLength: 4)
            Button(action: onAbout) {
                Image(systemName: "info.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Panura")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [PanuraTheme.accentContainer, PanuraTheme.surfaceContainer],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: PanuraTheme.cornerMedium)
        )
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(item.tint)
                .frame(width: 40, height: 40)
                .background(item.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.isCurrent ? PanuraTheme.accent : .primary)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(item.isCurrent ? PanuraTheme.accentSoft : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Version and build, as the drawer of every app this one is measured
    /// against carries — and the first thing worth knowing in a bug report.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}
