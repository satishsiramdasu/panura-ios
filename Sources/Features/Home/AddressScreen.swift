import UIKit
import SwiftUI

/// Runs a state change with the sheet slide switched off.
///
/// `fullScreenCover` always arrives from the bottom, and the address screen is
/// not a sheet in any sense that matters: it replaces the pill it was opened
/// from, in place, and the keyboard is already coming up underneath. A third of
/// a second of travel before you can type reads as the app being slow to
/// respond to a tap. Both ends are silenced, because a screen that appears
/// instantly and then slides away is worse than either done consistently.
func withoutSheetAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

/// Which list a blank search box browses.
/// Two lists, not three. Bookmarks were a third tab, which put the sites you
/// chose to keep behind the same tap as the ones the app counted for you — and
/// hid them behind it. They are a row of their own now, above the tabs.
enum AddressSection: String, CaseIterable, Identifiable {
    case mostVisited = "Most visited"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mostVisited: return "chart.line.uptrend.xyaxis"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Full-screen address / search entry, opened by tapping either address pill.
/// Port of Android's `BrowserAddressScreen`, section for section.
///
/// Typing searches; a blank box browses. The two never mix: with text in the
/// box you get Google's suggestions, then matching Most Visited, then matching
/// history — with it empty you get section chips and whichever list they select.
struct AddressScreen: View {
    /// The page the caller is on, offered back as a card when the box is blank.
    var currentURL: String = ""
    var currentTitle: String = ""
    /// Where the screen lands. Callers meaning "search" open on Most Visited —
    /// the sites you actually return to.
    var startSection: AddressSection = .mostVisited
    var onNavigate: (String) -> Void
    var onDismiss: () -> Void

    @ObservedObject private var store = BrowsingStore.shared
    /// Private browsing is a property of the browser session, not of whoever
    /// opened this screen, so it is read rather than passed in — Home's address
    /// bar and the browser's open the same screen and must agree about it.
    @ObservedObject private var session = BrowserSession.shared
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var section: AddressSection = .mostVisited
    @FocusState private var focused: Bool
    /// Said once, for the copy button — which otherwise gives no sign at all
    /// that anything happened, on a screen with no visible clipboard.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var isBlank: Bool { trimmed.isEmpty }

    // Private browsing repaints the screen violet, as the browser's own pill
    // already is. Typing an address is exactly the moment it matters that this
    // is not being recorded, and a screen that looks identical either way is
    // the one place the mode can be forgotten.
    private var incognito: Bool { session.privateMode }
    private var pageColor: Color {
        incognito ? PanuraTheme.incognitoSurface : PanuraTheme.background
    }
    private var barColor: Color {
        incognito ? PanuraTheme.incognitoSurfaceHigh : PanuraTheme.surfaceContainer
    }
    private var fieldColor: Color {
        incognito ? PanuraTheme.incognito.opacity(0.18) : PanuraTheme.surfaceVariant
    }
    /// The screen's own accent follows the mode too, or an amber chip on a
    /// violet screen says the tint is decoration rather than a state.
    private var tint: Color { incognito ? PanuraTheme.incognito : PanuraTheme.accent }
    private var tintSoft: Color {
        incognito ? PanuraTheme.incognito.opacity(0.22) : PanuraTheme.accentSoft
    }

    /// All three, always. Hiding an empty section hid Bookmarks on any install
    /// that had not saved one yet — which is exactly the install that needs to
    /// be told the section exists. Each empty state says what belongs there.
    private var chips: [AddressSection] { AddressSection.allCases }

    private func entries(for section: AddressSection) -> [SiteEntry] {
        switch section {
        case .mostVisited: return store.mostVisited
        case .history: return Array(store.recentlyVisited.prefix(30))
        }
    }

    private func matches(_ entries: [SiteEntry], limit: Int) -> [SiteEntry] {
        guard !isBlank else { return [] }
        let q = trimmed.lowercased()
        return Array(
            entries.filter {
                $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q)
            }.prefix(limit)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(pageColor)
        // Above the keyboard, which owns the bottom of this screen, and clear of
        // the card the button is on.
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .onAppear {
            section = startSection
            focused = true
        }
        // Debounced in the fetcher; re-run on each keystroke.
        .task(id: query) {
            suggestions = await SearchSuggestions.fetch(trimmed)
        }
    }

    // MARK: header — 52pt, matching every other screen's

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onDismiss) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(tintSoft, in: Circle())
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            HStack(spacing: 4) {
                TextField("Search or enter website", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { if !isBlank { onNavigate(trimmed) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                // Inside the field, at its end: the same slot a browser puts a
                // security indicator in, and it stays visible while typing —
                // which is when the mode is worth knowing.
                if incognito {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PanuraTheme.incognito)
                        .accessibilityLabel("Private browsing is on")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(fieldColor, in: Capsule())
        }
        .padding(.horizontal, 8)
        .frame(height: PanuraHeader<AnyView>.height)
        .background(barColor)
    }

    // MARK: results

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isBlank, !currentURL.isEmpty { currentPageCard }

                if !isBlank {
                    // Pills rather than rows, and not only for compactness:
                    // suggestions arrive over the network, and a horizontal strip
                    // grows sideways. Vertical rows would shove everything below
                    // them down as they land — under a finger already moving.
                    sectionHeader("Google Search:")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // What you typed, always first and always there: it
                            // needs no network, so the leftmost pill never moves
                            // or vanishes mid-tap.
                            pill(trimmed, icon: looksLikeURL(trimmed) ? "link" : "magnifyingglass", primary: true)
                            ForEach(suggestions, id: \.self) { s in
                                pill(s, icon: "magnifyingglass", primary: false)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 10)

                    let mv = matches(store.mostVisited, limit: 4)
                    if !mv.isEmpty {
                        sectionHeader("Most Visited:")
                        ForEach(mv) { row($0) }
                    }
                    let hist = matches(store.recentlyVisited, limit: 5)
                    if !hist.isEmpty {
                        sectionHeader("From History:")
                        ForEach(hist) { row($0) }
                    }
                } else {
                    // The sites you kept, before the ones the app counted for
                    // you: a row of faces rather than a list of addresses,
                    // because a bookmark is recognised rather than read.
                    bookmarksRow
                    chipRow
                    let rows = entries(for: section)
                    if section == .history, !rows.isEmpty {
                        HStack {
                            Text("Recently visited")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            // On the row it belongs to, not up from the
                            // bottom of the screen with nothing to say which
                            // list it was about.
                            Menu {
                                Section("History and your most-visited sites are both cleared.") {
                                    Button(role: .destructive) {
                                        store.clearHistory()
                                    } label: { Label("Clear History", systemImage: "trash") }
                                }
                            } label: {
                                Text("Clear history")
                            }
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    if rows.isEmpty {
                        emptySection
                    } else {
                        ForEach(rows) { entry in
                            row(
                                entry,
                                // Only a Most Visited tile can be dismissed:
                                // bookmarks are removed where they are made, and
                                // a history row is not a thing you curate.
                                removableHost: section == .mostVisited ? entry.host : nil
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        // Scrolling the results means you are done typing.
        .scrollDismissesKeyboard(.immediately)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { s in
                    Button { section = s } label: {
                        Label(s.rawValue, systemImage: s.icon)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(
                                Capsule().fill(
                                    s == section ? tintSoft : PanuraTheme.surfaceVariant
                                )
                            )
                            .foregroundStyle(s == section ? tint : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    /// The page you are on, and the three things anyone opens this screen to do
    /// to it: send it somewhere, copy it, or edit it into a different address.
    ///
    /// They are what an address bar is for other than typing, and each was
    /// previously several taps away — share through the site panel, copy by
    /// selecting text in a field, edit by retyping the whole URL.
    private var currentPageCard: some View {
        let entry = SiteEntry(url: currentURL, title: currentTitle)
        return HStack(spacing: 10) {
            Button { onNavigate(currentURL) } label: {
                HStack(spacing: 10) {
                    Favicon(entry: entry, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentTitle.isEmpty ? currentURL : currentTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(currentURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let url = URL(string: currentURL) {
                ShareLink(item: url) { cardGlyph("square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
            }
            Button {
                UIPasteboard.general.string = currentURL
                flash("Address copied")
            } label: { cardGlyph("doc.on.doc") }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy address")

            // Fills the box instead of navigating — the way to edit the URL you
            // are on rather than retype it.
            Button { query = currentURL } label: { cardGlyph("pencil") }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit address")
        }
        .padding(10)
        .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func flash(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private func cardGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
    }

    /// The saved sites, as faces.
    ///
    /// Horizontal, because this list is short by definition and a row of icons
    /// is read in one glance where five stacked rows of URL text are not.
    @ViewBuilder
    private var bookmarksRow: some View {
        if !store.bookmarks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(store.bookmarks) { entry in
                        Button { onNavigate(entry.url) } label: {
                            VStack(spacing: 6) {
                                Favicon(entry: entry, size: 30)
                                    .padding(13)
                                    .background(PanuraTheme.surfaceVariant, in: Circle())
                                Text(entry.title.isEmpty ? entry.host : entry.title)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: 78)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeBookmark(url: entry.url)
                            } label: { Label("Remove bookmark", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 6)
        }
    }

    private var emptySection: some View {
        Text(
            {
                switch section {
                case .mostVisited: return "Sites you open often show here."
                case .history: return "Type to search or enter a URL"
                }
            }()
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }

    // MARK: bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func pill(_ text: String, icon: String, primary: Bool) -> some View {
        Button { onNavigate(text) } label: {
            Label(text, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    Capsule().fill(primary ? tintSoft : PanuraTheme.surfaceVariant)
                )
                .foregroundStyle(primary ? tint : Color.primary)
        }
        .buttonStyle(.plain)
        // Long-press fills the box rather than navigating, so a suggestion can
        // be edited into the query it nearly was.
        .contextMenu { Button("Edit in search box") { query = text } }
    }

    /// Every row wears the site's own icon.
    ///
    /// They wore the section's glyph before — a clock on every history row, a
    /// chart on every most-visited one — which says where the row came from,
    /// which you already know, and nothing about which site it is.
    private func row(
        _ entry: SiteEntry,
        removableHost: String? = nil
    ) -> some View {
        Button { onNavigate(entry.url) } label: {
            HStack(spacing: 12) {
                Favicon(entry: entry, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entry.url : entry.title)
                        .font(.subheadline).lineLimit(1)
                    Text(entry.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { query = entry.url } label: {
                    Image(systemName: "arrow.up.left").font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            // A fixed height, not vertical padding. History is the long list —
            // thirty rows in a LazyVStack — and a lazy stack measures each row
            // as it comes into view: rows whose text has not been laid out yet
            // are sized from an estimate, which is the uneven spacing that shows
            // while scrolling. Pinning the height makes every row identical
            // before it is measured, so there is nothing left to estimate.
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let removableHost {
                Button(role: .destructive) {
                    store.removeHostVisit(host: removableHost)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private func looksLikeURL(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.contains(" ") { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.contains(".")
    }
}

/// Google's suggest endpoint, same one Android's address screen calls.
///
/// Debounced here rather than at the call site: the caller re-runs this on every
/// keystroke, and the query it was cancelled for is the one that should never
/// have gone out.
enum SearchSuggestions {
    static func fetch(_ query: String) async -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // A URL needs no completions, and asking would leak the address.
        guard !q.isEmpty, !q.contains("://"), !q.hasPrefix("www.") else { return [] }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return [] }

        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        // ["query", ["sug1", "sug2", …]]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count > 1, let list = root[1] as? [String] else { return [] }
        return Array(list.prefix(6))
    }
}

/// Favicon + title + host row, shared by the Home sheets.
struct SiteRow: View {
    let entry: SiteEntry

    var body: some View {
        HStack(spacing: 12) {
            Favicon(entry: entry, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(entry.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Rounded favicon with a globe placeholder while it loads (or if it 404s).
struct Favicon: View {
    let entry: SiteEntry
    var size: CGFloat = 32

    var body: some View {
        AsyncImage(url: entry.faviconURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "globe")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}
