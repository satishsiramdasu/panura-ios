import SwiftUI

/// Subtitle look and decoding — Android's Subtitle settings screen, minus the
/// two entries that mean nothing here (system caption style is an Android
/// accessibility service, and its font list is the system's font directory).
///
/// VLC reads every value when media opens (`VLCPlayerModel.applySubtitleStyle`),
/// and the player's own sheet re-opens the media for the few it offers. The
/// Apple player applies them live: as text style rules for subtitles inside the
/// stream, and through `SubtitleOverlay` for files sniffed from the page.
struct SubtitlePreferencesView: View {
    @AppStorage("subtitle_size") private var size = 24
    @AppStorage("subtitle_color") private var color = 0xFFFFFF
    @AppStorage("subtitle_background") private var background = false
    @AppStorage("subtitle_bold") private var bold = false
    @AppStorage("subtitle_outline") private var outline = 4
    @AppStorage("subtitle_font") private var font = ""
    @AppStorage("subtitle_encoding") private var encoding = ""
    @AppStorage("subtitle_embedded_styles") private var embeddedStyles = true
    @AppStorage("preferred_subtitle_language") private var preferredLanguage = ""

    /// Families that ship with iOS, so a name here always resolves. Written the
    /// way libVLC wants them — the family name, not the PostScript name.
    private static let fonts: [(String, String)] = [
        ("Default", ""),
        ("Helvetica", "Helvetica"),
        ("Avenir Next", "Avenir Next"),
        ("Georgia", "Georgia"),
        ("Verdana", "Verdana"),
        ("Courier New", "Courier New"),
    ]

    /// The encodings that actually come up. Auto handles UTF-8 and guesses the
    /// rest, which is why a Windows-1256 Arabic .srt arrives as mojibake until
    /// it is named here.
    private static let encodings: [(String, String)] = [
        ("Auto", ""),
        ("Unicode (UTF-8)", "UTF-8"),
        ("Western (Windows-1252)", "Windows-1252"),
        ("Cyrillic (Windows-1251)", "Windows-1251"),
        ("Arabic (Windows-1256)", "Windows-1256"),
        ("Hebrew (Windows-1255)", "Windows-1255"),
        ("Greek (Windows-1253)", "Windows-1253"),
        ("Turkish (Windows-1254)", "Windows-1254"),
        ("Japanese (Shift-JIS)", "Shift_JIS"),
        ("Simplified Chinese (GBK)", "GBK"),
        ("Traditional Chinese (Big5)", "Big5"),
    ]

    var body: some View {
        List {
            Section {
                Picker(selection: $preferredLanguage) {
                    Text("None").tag("")
                    ForEach(Self.languages, id: \.self) { Text($0).tag($0) }
                } label: {
                    PreferenceLabel(
                        title: "Preferred language",
                        description: "Auto-selects a matching track on every video",
                        icon: "globe"
                    )
                }
            } header: {
                Text("Track")
            }

            Section("Text") {
                Picker(selection: $size) {
                    Text("Small").tag(16)
                    Text("Medium").tag(24)
                    Text("Large").tag(34)
                    Text("Extra large").tag(44)
                } label: {
                    PreferenceLabel(title: "Size", description: "", icon: "textformat.size")
                }
                Picker(selection: $font) {
                    ForEach(Self.fonts, id: \.1) { Text($0.0).tag($0.1) }
                } label: {
                    PreferenceLabel(title: "Font", description: "", icon: "textformat")
                }
                Picker(selection: $color) {
                    Text("White").tag(0xFFFFFF)
                    Text("Yellow").tag(0xFFFF00)
                    Text("Cyan").tag(0x00FFFF)
                    Text("Grey").tag(0xBBBBBB)
                } label: {
                    PreferenceLabel(title: "Colour", description: "", icon: "paintpalette")
                }
                PreferenceToggle(
                    title: "Bold",
                    description: "Heavier strokes, easier over busy footage",
                    icon: "bold",
                    isOn: $bold
                )
            }

            Section {
                Picker(selection: $outline) {
                    Text("None").tag(0)
                    Text("Thin").tag(2)
                    Text("Medium").tag(4)
                    Text("Thick").tag(8)
                } label: {
                    PreferenceLabel(
                        title: "Outline",
                        description: "Dark edge around each glyph",
                        icon: "circle.dashed"
                    )
                }
                PreferenceToggle(
                    title: "Background",
                    description: "Solid box behind the text",
                    icon: "rectangle.fill",
                    isOn: $background
                )
            } header: {
                Text("Legibility")
            } footer: {
                Text("An outline keeps white text readable over bright frames; a background does it more forcefully, at the cost of covering more of the picture.")
            }

            Section {
                Picker(selection: $encoding) {
                    ForEach(Self.encodings, id: \.1) { Text($0.0).tag($0.1) }
                } label: {
                    PreferenceLabel(
                        title: "Text encoding",
                        description: "For subtitle files that arrive as gibberish",
                        icon: "character.textbox"
                    )
                }
                PreferenceToggle(
                    title: "Use embedded styles",
                    description: "Honour the fonts, colours and positions a subtitle file carries",
                    icon: "wand.and.stars",
                    isOn: $embeddedStyles
                )
            } header: {
                Text("Files")
            } footer: {
                Text("Turn embedded styles off to force every line into the look set above — useful when a file's own styling is unreadable.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Same list the player's own picker offers.
    static let languages = [
        "English", "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada", "Marathi",
        "Bengali", "Spanish", "French", "German", "Italian", "Arabic", "Japanese",
        "Korean", "Chinese", "Russian", "Portuguese", "Turkish",
    ]
}
