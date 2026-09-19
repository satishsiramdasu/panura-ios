import SwiftUI

/// Everything about audio or subtitles that is not "which track".
///
/// **Why this is a sheet and the track list is not.** Choosing a track is the
/// thing people open these controls for, it is one tap, and it belongs at the
/// button — a menu, like speed and quality. Delay, boost and subtitle
/// appearance are the opposite: set once, fiddled with, and made of steppers
/// and pickers that a menu cannot draw.
///
/// They were submenus, and submenus are what broke. A SwiftUI `Menu` nested in
/// a `Menu` is rebuilt whenever the parent view's body runs, and the player's
/// body runs several times a second because the engine publishes a new position
/// on every time observation. The result was two menu platters drawn over each
/// other — the flicker in the bug report. Nothing here is nested in anything.
struct PlayerOptionsSheet<Model: PlayerEngine>: View {
    enum Kind: String, Identifiable {
        case audio, subtitles
        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: return "Audio"
            case .subtitles: return "Subtitles"
            }
        }

        var icon: String {
            switch self {
            case .audio: return "waveform"
            case .subtitles: return "captions.bubble"
            }
        }
    }

    @ObservedObject var model: Model
    let kind: Kind
    @Environment(\.dismiss) private var dismiss

    @AppStorage("subtitle_size") private var subtitleSize = 24
    @AppStorage("subtitle_color") private var subtitleColor = 0xFFFFFF
    @AppStorage("subtitle_background") private var subtitleBackground = false
    @AppStorage("subtitle_bold") private var subtitleBold = false
    @AppStorage("preferred_audio_language") private var preferredAudioLang = ""
    @AppStorage("preferred_subtitle_language") private var preferredSubtitleLang = ""

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .audio: audioSections
                case .subtitles: subtitleSections
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: audio

    @ViewBuilder
    private var audioSections: some View {
        if model.supportsAudioDelay {
            Section {
                delayRow(
                    label: "Audio delay",
                    ms: model.audioDelayMs,
                    change: { model.adjustAudioDelay($0) }
                )
            } footer: {
                Text("Positive values play the audio later than the picture.")
            }
        }

        if model.supportsAudioBoost {
            Section("Volume boost") {
                Picker("Boost", selection: Binding(
                    get: { model.audioBoost },
                    set: { model.setAudioBoost($0) }
                )) {
                    ForEach([100, 125, 150, 175, 200], id: \.self) { percent in
                        Text(percent == 100 ? "Normal" : "\(percent)%").tag(percent)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        languageSection(
            title: "Preferred audio language",
            selection: $preferredAudioLang,
            note: "Picked automatically on every video when a matching track exists."
        )
    }

    // MARK: subtitles

    @ViewBuilder
    private var subtitleSections: some View {
        if model.supportsSubtitleDelay {
            Section {
                delayRow(
                    label: "Subtitle delay",
                    ms: model.subtitleDelayMs,
                    change: { model.adjustSubtitleDelay($0) }
                )
            } footer: {
                Text("Positive values show each line later.")
            }
        }

        Section("Appearance") {
            Picker("Size", selection: $subtitleSize) {
                Text("Small").tag(16)
                Text("Medium").tag(24)
                Text("Large").tag(34)
            }
            Picker("Colour", selection: $subtitleColor) {
                Text("White").tag(0xFFFFFF)
                Text("Yellow").tag(0xFFFF00)
            }
            Toggle("Bold", isOn: $subtitleBold)
            Toggle("Background", isOn: $subtitleBackground)
        }

        languageSection(
            title: "Preferred subtitle language",
            selection: $preferredSubtitleLang,
            note: "Turned on automatically when a matching track exists."
        )
    }

    // MARK: shared rows

    /// A stepper rather than the old ±250 ms buttons: holding it repeats, which
    /// is how an offset is actually found, and 50 ms is fine enough to land on.
    private func delayRow(label: String, ms: Int, change: @escaping (Int) -> Void) -> some View {
        Group {
            Stepper {
                LabeledContent(label) {
                    Text(ms == 0 ? "None" : (ms > 0 ? "+\(ms) ms" : "\(ms) ms"))
                        .monospacedDigit()
                }
            } onIncrement: {
                change(50)
            } onDecrement: {
                change(-50)
            }

            if ms != 0 {
                Button("Reset", role: .destructive) { change(-ms) }
            }
        }
    }

    private func languageSection(
        title: String,
        selection: Binding<String>,
        note: String
    ) -> some View {
        Section {
            Picker(title, selection: selection) {
                Text("Off").tag("")
                ForEach(PlayerLanguages.common, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
        } footer: {
            Text(note)
        }
    }
}
