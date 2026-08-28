import SwiftUI

/// One report sheet for the whole app — port of Android's `ReportIssueDialog`,
/// posting to the same Worker endpoint so both platforms land in one place.
///
/// Two modes, same UI: with `pageURL` set it reports the page you are on and
/// sends that URL; without it, it reports the app and sends a source marker the
/// worker can still key on.
struct ReportIssueSheet: View {
    /// nil = reporting the app rather than a page.
    var pageURL: String?
    var source: String = "app"
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var reason: String = ""
    @State private var details: String = ""

    private static let endpoint = URL(string: "https://panura-reports.satishsiramdasu.workers.dev")!
    /// A bare reason ("App crash") is not actionable, so app reports have to say
    /// something. Long enough to rule out "asd" without demanding an essay.
    private static let minDetailChars = 10

    private static let appReasons = [
        "Video not detected", "Playback issue", "Cast issue", "App crash", "Other",
    ]
    private static let pageReasons = [
        "Video not detected", "Page not loading", "Source error",
        "Wrong video", "Ad issue", "Other",
    ]

    private var reasons: [String] { pageURL == nil ? Self.appReasons : Self.pageReasons }
    /// A page report already names the site, so demanding prose there would only
    /// cost reports.
    private var detailsRequired: Bool { pageURL == nil }
    private var detailsTooShort: Bool {
        detailsRequired && details.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.minDetailChars
    }
    private var host: String? {
        guard let pageURL else { return nil }
        return URL(string: pageURL)?.host ?? pageURL
    }

    var body: some View {
        NavigationStack {
            Form {
                if let host {
                    // The host is the report's subject — show it, so nobody has
                    // to describe which page they meant.
                    Section { Text(host).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    // A picker, not six radio rows: same choice in a fraction of
                    // the height, which leaves room for the description that
                    // actually makes a report useful.
                    Picker("What went wrong", selection: $reason) {
                        ForEach(reasons, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Pick what went wrong, then tell us what you saw")
                }

                Section {
                    TextField(
                        pageURL != nil
                            ? "e.g. player opens but stays black"
                            : "e.g. video won't play on example.com",
                        text: $details,
                        axis: .vertical
                    )
                    .lineLimit(3...5)
                } header: {
                    Text("What happened?")
                } footer: {
                    Text(
                        detailsTooShort
                            ? "Required — a sentence is enough"
                            : (detailsRequired
                               ? "Include the site and what you were doing"
                               : "Optional, but it helps")
                    )
                }
            }
            .navigationTitle(pageURL != nil ? "Report this page" : "Report an issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Send") { send() }.disabled(detailsTooShort)
                }
            }
            .onAppear { if reason.isEmpty { reason = reasons[0] } }
        }
    }

    private func send() {
        let typed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = typed.isEmpty ? reason : "\(reason): \(typed)"
        let reportURL = pageURL ?? "(app: \(source))"
        // Fire and forget, off the sheet's lifetime: a report that fails to send
        // is not worth blocking a dismissal or explaining — the same call Android
        // makes, with the same silence.
        Task.detached {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["url": reportURL, "reason": full.replacingOccurrences(of: "\n", with: " ")]
            )
            _ = try? await URLSession.shared.data(for: request)
        }
        onSent()
        dismiss()
    }
}
