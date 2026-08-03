import SwiftUI

/// Full-screen address / search entry, opened by tapping the Home address pill.
/// Mirrors Android's `BrowserAddressScreen`: a focused field plus the visit
/// history, filtered as you type. Submitting hands the raw text to the browser,
/// which normalises it into a URL or a web search.
struct AddressScreen: View {
    var onNavigate: (String) -> Void
    var onDismiss: () -> Void

    @ObservedObject private var store = BrowsingStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var suggestions: [SiteEntry] {
        let all = store.recentlyVisited
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(all.prefix(30)) }
        return Array(
            all.filter {
                $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
            }.prefix(30)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { entry in
                            Button { onNavigate(entry.url) } label: {
                                SiteRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(text.isEmpty ? "Recent" : "Matches")
                            Spacer()
                            if text.isEmpty {
                                Button("Clear") { store.clearHistory() }
                                    .font(.caption)
                            }
                        }
                    }
                } else if !text.isEmpty {
                    Section {
                        Button { onNavigate(text) } label: {
                            Label("Search for “\(text)”", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Google or enter website", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit {
                            let t = text.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            onNavigate(t)
                        }
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(PanuraTheme.accentSoft, in: Capsule())
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onDismiss)
                }
            }
        }
        .onAppear { focused = true }
    }
}

/// Favicon + title + host row, shared by the address screen and the Home sheets.
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
