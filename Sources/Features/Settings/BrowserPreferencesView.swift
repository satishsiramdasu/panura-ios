import SwiftUI
import WebKit

/// Port of Android's `BrowserPreferencesScreen`, section for section: Privacy,
/// Display, Clear Data.
struct BrowserPreferencesView: View {
    /// Read by WebViewContainer at web-view creation.
    @AppStorage("ad_block") private var adBlock = true
    // Moved here with the Detection screen they used to live on.
    @AppStorage("debug_detection") private var debugDetection = false
    @AppStorage("auto_play_click") private var autoPlayClick = true
    @AppStorage("block_page_fullscreen") private var blockPageFullscreen = true
    @AppStorage("block_long_press") private var blockLongPress = true
    @State private var rulesRefreshed = false
    /// The default for sites with no opinion of their own. The browser's site
    /// panel overrides it per site — see `SiteSettings`.
    @AppStorage("detection_enabled") private var detection = true
    /// The UA the browser starts on. The in-page menu still flips one session.
    @AppStorage("desktop_mode_default") private var desktopByDefault = false
    @ObservedObject private var session = BrowserSession.shared

    @State private var confirming: ClearTarget?
    @State private var done: ClearTarget?

    private enum ClearTarget: String, Identifiable {
        case cache, cookies, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .cache: return "Clear Cache?"
            case .cookies: return "Clear Cookies?"
            case .history: return "Clear History?"
            }
        }

        var message: String {
            switch self {
            case .cache: return "Cached images and files are deleted. Sites will load slower once."
            case .cookies: return "You will be signed out of every site you are logged in to."
            case .history: return "Your visited pages and Most Visited tiles are deleted."
            }
        }
    }

    var body: some View {
        List {
            Section("Privacy") {
                PreferenceToggle(
                    title: "Hide distractions",
                    description: "Hide ads, pop-ups and trackers on every site",
                    icon: "shield.lefthalf.filled",
                    isOn: $adBlock
                )
                PreferenceToggle(
                    title: "Private browsing",
                    description: "Nothing is written to history, cookies live only while the session does",
                    icon: "eyeglasses",
                    isOn: Binding(
                        get: { session.privateMode },
                        set: { session.setPrivateMode($0) }
                    )
                )
            }

            Section {
                PreferenceToggle(
                    title: "Desktop mode",
                    description: "Request the desktop version of websites by default",
                    icon: "desktopcomputer",
                    isOn: $desktopByDefault
                )
            } header: {
                Text("Display")
            } footer: {
                Text("Takes effect on the next page you open. The browser menu still switches one page at a time.")
            }

            // Detection sits after Display because it is the deepest of these
            // settings, not the first thing anyone came for — and everything
            // under the switch is meaningless while the switch is off, so it
            // is not shown. This used to be a screen of its own on the
            // Settings root, which put the app's most specialised options at
            // the same level as "Playback".
            Section {
                PreferenceToggle(
                    title: "Find videos",
                    description: "Watch pages for playable streams. Off, the browser is only a browser",
                    icon: "sparkle.magnifyingglass",
                    isOn: $detection
                )

                if detection {
                    PreferenceToggle(
                        title: "Press play automatically",
                        description: "Some sites request nothing until their play button is pressed; Panura presses it for them",
                        icon: "play.square",
                        isOn: $autoPlayClick
                    )
                    PreferenceToggle(
                        title: "Keep page videos inline",
                        description: "Pressing play keeps the video in the page; full screen only opens when you tap it. Reopen the Browser tab to apply",
                        icon: "rectangle.inset.filled",
                        isOn: $blockPageFullscreen
                    )
                    PreferenceToggle(
                        title: "Block long-press menu",
                        description: "No text selection or Copy Link menu when you hold a page. Typing and pasting in a page's own boxes still work.",
                        icon: "hand.tap",
                        isOn: $blockLongPress
                    )
                    PreferenceButton(
                        title: rulesRefreshed ? "Site rules will refresh" : "Refresh site rules",
                        description: "Re-download the detection rules. Reopen the Browser tab to apply them.",
                        icon: rulesRefreshed ? "checkmark" : "arrow.down.circle"
                    ) {
                        ManifestStore.clearCache()
                        rulesRefreshed = true
                    }
                    .disabled(rulesRefreshed)
                    PreferenceToggle(
                        title: "Diagnostics",
                        description: "Log every media URL a page requests and why it was kept or filtered",
                        icon: "ladybug",
                        isOn: $debugDetection
                    )
                }
            } header: {
                Text("Detection")
            } footer: {
                Text("The Panura mark in the address bar sets this, and what is hidden, for one site at a time. Rules are fetched from Panura's servers, so a site that stops working can be fixed without an app update.")
            }

            Section {
                PreferenceButton(
                    title: "Clear Cache",
                    description: done == .cache ? "Cache cleared" : "Delete cached images and files",
                    icon: done == .cache ? "checkmark" : "trash"
                ) { confirming = .cache }

                PreferenceButton(
                    title: "Clear Cookies",
                    description: done == .cookies
                        ? "Cookies cleared"
                        : "Delete all site cookies and login sessions",
                    icon: done == .cookies ? "checkmark" : "trash"
                ) { confirming = .cookies }

                PreferenceButton(
                    title: "Clear Browsing History",
                    description: done == .history
                        ? "History cleared"
                        : "Delete your visited pages history",
                    icon: done == .history ? "checkmark" : "trash"
                ) { confirming = .history }
            } header: {
                Text("Clear Data")
            } footer: {
                Text("Shortcuts and Continue Watching are never touched by these.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Web Browser")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                if let target = confirming { clear(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming?.message ?? "")
        }
    }

    private func clear(_ target: ClearTarget) {
        switch target {
        case .cache:
            WKWebsiteDataStore.default().removeData(
                ofTypes: [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache,
                ],
                modifiedSince: .distantPast
            ) {}
        case .cookies:
            // Local storage goes with them: a site's session is as often in one
            // as the other, and clearing half of it leaves a login that half
            // works.
            WKWebsiteDataStore.default().removeData(
                ofTypes: [
                    WKWebsiteDataTypeCookies,
                    WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeSessionStorage,
                    WKWebsiteDataTypeIndexedDBDatabases,
                ],
                modifiedSince: .distantPast
            ) {}
        case .history:
            BrowsingStore.shared.clearHistory()
        }
        done = target
    }
}
