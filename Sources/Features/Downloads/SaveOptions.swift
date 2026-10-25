import SwiftUI

/// What a master playlist offers to save, and the sheet that asks.
///
/// Ported from Android's `HlsTrackParser` and `HlsSaveSheetContent`: a title
/// field, then Quality, Audio and Subtitles as rows of pills. Quality carries
/// the size worked out from the rung's average bandwidth and the running time,
/// the same figure the found-video sheet quotes.
struct SaveOptions: Identifiable {
    struct Variant: Hashable {
        let url: URL
        /// "1080p", or "" when the rung does not say.
        let resolution: String
        let bps: Double
        /// The rung names an audio group, so its audio is a playlist of its own.
        let hasAudioGroup: Bool
    }
    struct Track: Hashable {
        let url: URL
        let name: String
        let language: String

        var label: String { language.isEmpty ? name : "\(name) (\(language))" }
    }

    let id = UUID()
    let video: ExtractedVideo
    var title: String
    var variants: [Variant]
    var audio: [Track]
    var subtitles: [Track]
    var seconds: Double

    /// A single rung with nothing to choose from is saved without asking.
    var needsSheet: Bool { variants.count > 1 || !audio.isEmpty || !subtitles.isEmpty }

    func sizeLabel(_ variant: Variant) -> String? {
        guard seconds > 0, variant.bps > 0 else { return nil }
        return "~" + StreamProbe.formatSize(Int64(variant.bps * seconds / 8))
    }

    static func parse(master: String, base: URL, video: ExtractedVideo, title: String, seconds: Double) -> SaveOptions {
        var variants: [Variant] = []
        var audio: [Track] = []
        var subtitles: [Track] = []
        var pending: (res: String, bps: Double, group: Bool)?

        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("#EXT-X-STREAM-INF") {
                let res = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: [.regularExpression, .caseInsensitive])
                    .flatMap { String(line[$0]).split(separator: "x").last }
                    .map { "\($0)p" } ?? ""
                let bps = number("AVERAGE-BANDWIDTH", in: line) ?? number("BANDWIDTH", in: line) ?? 0
                pending = (res, bps, upper.contains("AUDIO=\""))
            } else if let p = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    variants.append(Variant(url: url, resolution: p.res, bps: p.bps, hasAudioGroup: p.group))
                }
                pending = nil
            } else if upper.hasPrefix("#EXT-X-MEDIA") {
                guard let name = quoted("NAME", in: line),
                      let uri = quoted("URI", in: line),
                      let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
                let track = Track(url: url, name: name, language: quoted("LANGUAGE", in: line) ?? "")
                if upper.contains("TYPE=AUDIO"), !audio.contains(where: { $0.url == url }) {
                    audio.append(track)
                } else if upper.contains("TYPE=SUBTITLES"), !subtitles.contains(where: { $0.url == url }) {
                    subtitles.append(track)
                }
            }
        }
        variants.sort { $0.bps > $1.bps }
        return SaveOptions(
            video: video, title: title, variants: variants, audio: audio,
            subtitles: subtitles, seconds: seconds
        )
    }

    private static func quoted(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"", options: .caseInsensitive) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func number(_ name: String, in line: String) -> Double? {
        let pattern = "(?<![-A-Z])" + name + "=(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return Double(line[range])
    }
}

/// The sheet itself. Hands back the indexes the user picked; a subtitle index
/// of nil is "None".
struct SaveOfflineSheet: View {
    let options: SaveOptions
    let onConfirm: (_ title: String, _ variant: Int, _ audio: Int?, _ subtitle: Int?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var variant = 0
    @State private var audio = 0
    @State private var subtitle: Int?

    init(
        options: SaveOptions,
        onConfirm: @escaping (String, Int, Int?, Int?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.options = options
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _title = State(initialValue: options.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Offline").font(.title3.weight(.semibold))

                TextField("Title", text: $title)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(PanuraTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                section("Quality") {
                    ForEach(options.variants.indices, id: \.self) { i in
                        let v = options.variants[i]
                        let size = options.sizeLabel(v)
                        let name = v.resolution.isEmpty ? "\(Int(v.bps / 1000)) kbps" : v.resolution
                        pill(size.map { "\(name) (\($0))" } ?? name, selected: variant == i) { variant = i }
                    }
                }
                if !options.audio.isEmpty {
                    section("Audio") {
                        ForEach(options.audio.indices, id: \.self) { i in
                            pill(options.audio[i].label, selected: audio == i) { audio = i }
                        }
                    }
                }
                if !options.subtitles.isEmpty {
                    section("Subtitles") {
                        pill("None", selected: subtitle == nil) { subtitle = nil }
                        ForEach(options.subtitles.indices, id: \.self) { i in
                            pill(options.subtitles[i].label, selected: subtitle == i) { subtitle = i }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(PanuraTheme.accent)
                    Button {
                        onConfirm(title, variant, options.audio.isEmpty ? nil : audio, subtitle)
                    } label: {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PanuraTheme.onAccent)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(PanuraTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func section<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            PillFlow(spacing: 8) { content() }
        }
    }

    private func pill(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(selected ? PanuraTheme.onAccent : PanuraTheme.onSurfaceVariant)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    selected ? PanuraTheme.accent : PanuraTheme.surfaceContainerHighest,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

/// Pills that wrap onto further lines, as Compose's `FlowRow` does.
private struct PillFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            used = max(used, x - spacing)
        }
        return CGSize(width: used, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
