import SwiftUI

/// The questions people actually arrive with.
///
/// Written from the things that have gone wrong on real devices rather than
/// from the feature list: a television that renders Dolby Vision as noise, a TV
/// that never appears because the phone was on mobile data, a page that finds
/// nothing. Each answer says what to do, and where nothing can be done it says
/// that instead of offering hope.
///
/// Answers live in the app, not on the website. Someone whose casting has just
/// failed may have no working connection to read a web page with, and the one
/// screen they can always reach is this one.
struct FAQView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var open: Int?
    @State private var showReport = false

    private struct Entry {
        let question: String
        let answer: String
    }

    private static let entries: [Entry] = [
        Entry(
            question: "How do I send a video to my TV?",
            answer: """
            Open a page in the Browser tab and play the video. When Panura finds \
            a stream, a bar appears at the bottom — tap Cast on it and pick your \
            television.

            For a video already on your phone, open the Videos tab and tap it. \
            If a TV is connected, Panura asks whether to play it here or there.
            """
        ),
        Entry(
            question: "Which TVs can I cast to?",
            answer: """
            Two kinds. Any Chromecast, or a Google TV / Android TV with \
            Chromecast built in. And any Android TV running the Panura app, \
            which appears as its own device.

            Panura on Android TV is the better of the two. It runs the same \
            player as this app, so it plays what this app plays — including \
            formats a Chromecast refuses.
            """
        ),
        Entry(
            question: "My TV does not appear in the list",
            answer: """
            Both devices must be on the same Wi-Fi network. This is the usual \
            cause: a phone on mobile data, or on a guest network that keeps \
            devices apart.

            Panura also needs permission to find devices on your local network. \
            If you declined that prompt, turn it back on in iOS Settings → \
            Panura → Local Network.

            Some routers block the discovery that finding a TV depends on — \
            often an "AP isolation" or "client isolation" setting.
            """
        ),
        Entry(
            question: "The picture on my TV is noise or broken lines",
            answer: """
            That is almost always Dolby Vision. iPhones record in it, and many \
            televisions accept the video and then decode it wrongly — the file \
            is fine, which is why the same clip looks right on the phone.

            Panura now spots this before sending and converts a standard copy \
            first. If your television handles Dolby Vision properly, choose \
            "Send original" while it is converting and Panura will remember \
            that for that TV.
            """
        ),
        Entry(
            question: "Why does a video from my phone stop or buffer?",
            answer: """
            A television cannot open a file that only exists on your phone, so \
            the phone serves it — which means the phone has to stay on the \
            network and awake for as long as it plays. Locking it or leaving \
            Wi-Fi ends the video.

            A video from a website is different: there the TV fetches it \
            directly, and the phone is only the remote control.
            """
        ),
        Entry(
            question: "Panura is not finding any video on a page",
            answer: """
            Press the site's own play button first. Many pages request nothing \
            at all until you do, so there is nothing to find before that.

            Check that Find videos is on — in the panel behind the Panura mark \
            in the address bar, which sets it for one site at a time, or in \
            Settings → Web Browser.

            Some pages only work with the desktop version; try Desktop site in \
            the same panel. If it still finds nothing, report the page — the \
            rules that handle stubborn sites are updated without an app update.
            """
        ),
        Entry(
            question: "Can I line up several videos?",
            answer: """
            Yes. When something is already playing on the TV, casting another \
            offers to add it to the queue instead of replacing it, and Panura \
            starts the next one by itself when one ends.

            In the Videos tab you can select several at once and send the lot. \
            The queue lives on the phone, so you can reorder or remove things \
            while the TV is playing.
            """
        ),
        Entry(
            question: "Can I control the TV from my phone?",
            answer: """
            Yes. While something is casting, a bar sits above the app bar — tap \
            it for play, pause, seeking and volume.

            Panura on Android TV reports the most back: position, audio tracks \
            and subtitles. A Chromecast reports less, so that screen shows only \
            what it can honestly control.
            """
        ),
        Entry(
            question: "Why can I not skip forward in some videos?",
            answer: """
            Live streams have nothing to skip to — that is what live means.

            For anything else, seeking depends on the site allowing it. Some \
            hand out single-use links that stop working the moment you jump.
            """
        ),
        Entry(
            question: "Does Panura download videos?",
            answer: """
            No. Panura plays and casts; it does not save anything from a \
            website to your phone.

            The Videos tab shows videos that are already in your photo library — \
            your own recordings — so that you can play or cast them.
            """
        ),
        Entry(
            question: "How do I browse without leaving a trace?",
            answer: """
            Turn on Private browsing, from the panel behind the Panura mark or \
            in Settings → Web Browser. Nothing is written to history, and \
            cookies last only while the session does. The header mark turns \
            purple so you can tell at a glance.

            To clear what is already there: Settings → Web Browser → Clear Data.
            """
        ),
        Entry(
            question: "What leaves my phone?",
            answer: """
            Browsing stays on the device — history, bookmarks and what you were \
            watching are never uploaded.

            Panura sends anonymous crash reports and basic usage analytics, and \
            fetches its detection rules from Panura's own server. Casting to a \
            TV happens entirely on your own network.

            The full detail is in the privacy policy, in Settings → About.
            """
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    header
                    ForEach(Array(Self.entries.enumerated()), id: \.offset) { index, entry in
                        card(index: index, entry: entry)
                    }
                    contact
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(PanuraTheme.background)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // The same cross as Report and Settings. "Done" claims
                    // something was finished, and reading an answer is not a
                    // task with a state to commit.
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .sheet(isPresented: $showReport) {
                ReportIssueSheet(source: "faq")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 48, height: 48)
                .background(PanuraTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Need a hand?").font(.headline)
                Text("The things that go wrong most often, and what to do about them")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(PanuraTheme.surfaceContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(PanuraTheme.accent.opacity(0.35), lineWidth: 1)
        )
        .padding(.bottom, 4)
    }

    /// One question. Numbered, because "the third one" is how people refer back
    /// to these — in a report, or to each other.
    private func card(index: Int, entry: Entry) -> some View {
        let isOpen = open == index
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open = isOpen ? nil : index }
            } label: {
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .frame(width: 30, height: 30)
                        .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 9))
                    Text(entry.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(entry.answer)
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PanuraTheme.surfaceContainer))
    }

    /// The way out when none of the above was it.
    private var contact: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 52, height: 52)
                .background(PanuraTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))

            Text("Still stuck?").font(.headline)
            Text("Tell us what happened and we will look at it. Your version and device come along, so you do not have to describe them.")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button { showReport = true } label: {
                Label("Report a problem", systemImage: "envelope.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(PanuraTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(PanuraTheme.surfaceContainer))
        .padding(.top, 6)
    }
}
