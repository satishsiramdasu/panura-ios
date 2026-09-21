import SwiftUI

/// Per-site overrides of the browser's protections, and the global defaults
/// they fall back to.
///
/// **Why only three of them are per-site.** A setting can be per-site here only
/// if it can be changed on a web view that is already running. Ad blocking can
/// — rule lists are added to and removed from the live content controller, and
/// the page is reloaded. Detection can, because it is our own code reading its
/// own results. Desktop mode can, being a user-agent string and a reload.
///
/// Everything else the browser does — the auto-click, keeping video inline,
/// suppressing the long-press menu — is a WebKit *user script*, and those are
/// fixed when the web view is created. Making one of those per-site would mean
/// rebuilding the web view on every hop to a different host, throwing away the
/// back list and the page each time. So they stay global, and the panel says so
/// rather than pretending otherwise.
@MainActor
final class SiteSettings: ObservableObject {
    static let shared = SiteSettings()

    /// A protection that can differ from site to site.
    enum Control: String, CaseIterable, Identifiable {
        case adBlock, detection, desktop
        var id: String { rawValue }

        var title: String {
            switch self {
            case .adBlock: return "Hide distractions"
            case .detection: return "Find videos"
            case .desktop: return "Desktop site"
            }
        }

        var detail: String {
            switch self {
            case .adBlock: return "Ads, pop-ups and trackers — applied on reload"
            case .detection: return "Watch this site for playable streams"
            case .desktop: return "Ask for the desktop layout"
            }
        }

        var icon: String {
            switch self {
            case .adBlock: return "shield.lefthalf.filled"
            case .detection: return "sparkle.magnifyingglass"
            case .desktop: return "display"
            }
        }

        /// The global preference this falls back to, and the value to assume
        /// when even that is unset.
        var globalKey: String {
            switch self {
            case .adBlock: return "ad_block"
            case .detection: return "detection_enabled"
            case .desktop: return "desktop_mode_default"
            }
        }

        var globalDefault: Bool {
            switch self {
            case .adBlock, .detection: return true
            case .desktop: return false
            }
        }
    }

    private static let storeKey = "site_settings"

    /// host → control rawValue → value. Only what the user has actually
    /// changed: an absent entry means "whatever the default is", so changing a
    /// global default still moves every site that was never touched.
    @Published private var overrides: [String: [String: Bool]]

    private init() {
        overrides = UserDefaults.standard
            .dictionary(forKey: Self.storeKey) as? [String: [String: Bool]] ?? [:]
    }

    /// The registrable-ish host a rule is keyed on.
    ///
    /// `www.` is stripped so a site is one site, but nothing further: this is
    /// not the manifest's hashing, and guessing at public suffixes here would
    /// silently merge distinct hosts.
    static func key(for url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func globalValue(_ control: Control) -> Bool {
        UserDefaults.standard.object(forKey: control.globalKey) as? Bool ?? control.globalDefault
    }

    /// What is in force for this site — its own override, or the global value.
    func value(_ control: Control, host: String?) -> Bool {
        if let host, let v = overrides[host]?[control.rawValue] { return v }
        return globalValue(control)
    }

    /// True when this site is running on the defaults, so the panel can say
    /// "standard" and the header icon can stay quiet.
    func isDefault(host: String?) -> Bool {
        guard let host, let site = overrides[host] else { return true }
        return site.allSatisfy { key, value in
            guard let control = Control(rawValue: key) else { return true }
            return value == globalValue(control)
        }
    }

    /// True when anything is switched *off* for this site that is normally on,
    /// which is the state worth marking in the header.
    func isLowered(host: String?) -> Bool {
        guard let host, let site = overrides[host] else { return false }
        return site.contains { key, value in
            guard let control = Control(rawValue: key), control != .desktop else { return false }
            return value == false && globalValue(control) == true
        }
    }

    func set(_ control: Control, host: String, to value: Bool) {
        var site = overrides[host] ?? [:]
        // Storing a value equal to the global would freeze this site against a
        // later change of mind in Settings, so matching the default removes the
        // override rather than writing it.
        if value == globalValue(control) {
            site[control.rawValue] = nil
        } else {
            site[control.rawValue] = value
        }
        overrides[host] = site.isEmpty ? nil : site
        persist()
    }

    /// Back to the defaults for one site.
    func reset(host: String) {
        guard overrides[host] != nil else { return }
        overrides[host] = nil
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: Self.storeKey)
    }
}
