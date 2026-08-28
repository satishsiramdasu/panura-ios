import SwiftUI

/// Which list a blank search box browses.
enum AddressSection: String, CaseIterable, Identifiable {
    case shortcuts = "Shortcuts"
    case mostVisited = "Most visited"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .shortcuts: return "star.fill"
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
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var section: AddressSection = .mostVisited
    @State private var confirmClear = false
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var isBlank: Bool { trimmed.isEmpty }

    /// All three, always. Hiding an empty section hid Shortcuts on any install
    /// that had not saved one yet — which is exactly the install that needs to
    /// be told the section exists. Each empty state says what belongs there.
    private var chips: [AddressSection] { AddressSection.allCases }

    private func entries(for section: AddressSection) -> [SiteEntry] {
        switch section {
        case .shortcuts: return store.shortcuts
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
        .background(PanuraTheme.background)
        .onAppear {
            section = startSection
            focused = true
        }
        // Debounced in the fetcher; re-run on each keystroke.
        .task(id: query) {
            suggestions = await SearchSuggestions.fetch(trimmed)
        }
        .confirmationDialog(
            "Clear history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All browsing history will be deleted, and your most-visited websites will be cleared.")
        }
    }

    // MARK: header — 52pt, matching every other screen's

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onDismiss) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(PanuraTheme.accentSoft, in: Circle())
                    .foregroundStyle(PanuraTheme.accent)
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
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(PanuraTheme.surfaceVariant, in: Capsule())
        }
        .padding(.horizontal, 8)
        .frame(height: PanuraHeader<AnyView>.height)
        .background(PanuraTheme.surfaceContainer)
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
                        ForEach(mv) { row($0, icon: AddressSection.mostVisited.icon) }
                    }
                    let hist = matches(store.recentlyVisited, limit: 5)
                    if !hist.isEmpty {
                        sectionHeader("From History:")
                        ForEach(hist) { row($0, icon: AddressSection.history.icon) }
                    }
                } else {
                    chipRow
                    let rows = entries(for: section)
                    if section == .history, !rows.isEmpty {
                        HStack {
                            Text("Recently visited")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear history") { confirmClear = true }
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
                                icon: section.icon,
                                accent: section == .shortcuts,
                                // Only a Most Visited tile can be dismissed:
                                // shortcuts are removed where they are made, and
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
                                    s == section ? PanuraTheme.accentSoft : PanuraTheme.surfaceVariant
                                )
                            )
                            .foregroundStyle(s == section ? PanuraTheme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var currentPageCard: some View {
        Button { onNavigate(currentURL) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(PanuraTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTitle.isEmpty ? currentURL : currentTitle)
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(currentURL).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                // Fills the box instead of navigating — the way to edit the URL
                // you are on rather than retype it.
                Button { query = currentURL } label: {
                    Image(systemName: "arrow.up.left").font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    private var emptySection: some View {
        Text(
            {
                switch section {
                case .shortcuts: return "Websites you save as shortcuts show here."
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
                    Capsule().fill(primary ? PanuraTheme.accentSoft : PanuraTheme.surfaceVariant)
                )
                .foregroundStyle(primary ? PanuraTheme.accent : Color.primary)
        }
        .buttonStyle(.plain)
        // Long-press fills the box rather than navigating, so a suggestion can
        // be edited into the query it nearly was.
        .contextMenu { Button("Edit in search box") { query = text } }
    }

    private func row(
        _ entry: SiteEntry,
        icon: String,
        accent: Bool = false,
        removableHost: String? = nil
    ) -> some View {
        Button { onNavigate(entry.url) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(accent ? PanuraTheme.accent : Color.secondary)
                    .frame(width: 22)
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
            .padding(.vertical, 10)
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
