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

    // "Video not detected" sits second, not first. At the top of a list it is
    // the answer people reach for when they are unsure, which turns every vague
    // report into a detection bug and buries the real ones. The genuinely most
    // common failure leads instead.
    private static let appReasons = [
        "Playback issue", "Video not detected", "Cast issue", "App crash", "Other",
    ]
    private static let pageReasons = [
        "Page not loading", "Video not detected", "Source error",
        "Wrong video", "Ad issue", "Other",
    ]

    private var reasons: [String] { pageURL == nil ? Self.appReasons : Self.pageReasons }
    /// A page report already names the site, so demanding prose there would only
    /// cost reports.
    private var detailsRequired: Bool { pageURL == nil }
    private var detailsTooShort: Bool {
        detailsRequired && details.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.minDetailChars
    }
    /// Nothing is chosen for you. A pre-selected reason is a guess the form
    /// makes on the reporter's behalf, and it arrives as though they had made
    /// it - so the picker opens empty and Send waits for a real answer.
    private var incomplete: Bool { reason.isEmpty || detailsTooShort }
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
                        // The empty tag, so "nothing picked yet" is a state the
                        // picker can show rather than silently resolving to
                        // whatever happens to be first.
                        Text("Select a reason").tag("")
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
            // Sending sits at the bottom, under the thumb, rather than in a
            // corner of the navigation bar. It is the one thing this screen is
            // for, and a form whose only action is a small word in the top
            // right reads as optional.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button { send() } label: {
                        Text("Send report")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(incomplete ? PanuraTheme.onSurfaceVariant : Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                Capsule().fill(
                                    incomplete ? PanuraTheme.surfaceVariant : PanuraTheme.accent
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(incomplete)

                    // A button the same size as Send. It was a footnote-sized
                    // word with no edges, which is not something you aim at -
                    // and on a form with a required field it is what people
                    // need when they change their mind.
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Capsule().fill(Color.red.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                // Right, where every other sheet in the app closes.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
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
