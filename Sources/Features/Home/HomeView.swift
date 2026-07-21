import SwiftUI

struct HomeView: View {
    var onOpenBrowser: () -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    searchPill
                    quickLinks
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { CastButton() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Panura").font(.largeTitle.bold())
            Text("WEB VIDEO PLAYER")
                .font(.caption).tracking(2).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the web", text: $query)
                .submitLabel(.go)
                .onSubmit(onOpenBrowser)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(PanuraTheme.accentSoft, in: Capsule())
    }

    private var quickLinks: some View {
        HStack(spacing: 12) {
            LinkChip(title: "Share App", systemImage: "square.and.arrow.up")
            LinkChip(title: "Telegram", systemImage: "paperplane.fill")
        }
    }
}

private struct LinkChip: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(PanuraTheme.accent)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(PanuraTheme.accentSoft, in: Capsule())
    }
}
