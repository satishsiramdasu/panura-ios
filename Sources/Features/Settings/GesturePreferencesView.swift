import SwiftUI

/// Which player gestures are live, and how far a swipe has to travel — Android's
/// Gestures screen.
///
/// Switches rather than a fixed set, because these conflict with how people
/// actually hold a phone: a light grip drags the brightness gesture every time
/// the video is picked up, and someone who scrubs by dragging wants that and
/// nothing else. Each one that is off is simply ignored by the player.
struct GesturePreferencesView: View {
    @AppStorage("gesture_seek") private var seek = true
    @AppStorage("gesture_brightness") private var brightness = true
    @AppStorage("gesture_volume") private var volume = true
    @AppStorage("gesture_zoom") private var zoom = true
    @AppStorage("gesture_double_tap") private var doubleTap = true
    @AppStorage("gesture_long_press") private var longPress = true
    /// Multiplier on how far a drag moves what it controls. 1.0 = a full screen
    /// width is the full range.
    @AppStorage("gesture_sensitivity") private var sensitivity = 1.0
    @AppStorage("skip_interval") private var skipInterval = 10

    var body: some View {
        List {
            Section {
                PreferenceToggle(
                    title: "Swipe to seek",
                    description: "Drag left or right anywhere on the video",
                    icon: "arrow.left.and.right",
                    isOn: $seek
                )
                PreferenceToggle(
                    title: "Swipe for brightness",
                    description: "Drag up or down on the left half",
                    icon: "sun.max",
                    isOn: $brightness
                )
                PreferenceToggle(
                    title: "Swipe for volume",
                    description: "Drag up or down on the right half",
                    icon: "speaker.wave.2",
                    isOn: $volume
                )
                PreferenceToggle(
                    title: "Pinch to zoom",
                    description: "Pinch to fill the screen, two fingers to move the picture",
                    icon: "arrow.up.left.and.arrow.down.right",
                    isOn: $zoom
                )
            } header: {
                Text("Swipes")
            }

            Section {
                PreferenceToggle(
                    title: "Double tap to skip",
                    description: "Tap either side to jump by the skip interval",
                    icon: "hand.tap",
                    isOn: $doubleTap
                )
                PreferenceToggle(
                    title: "Hold to speed up",
                    description: "Press and hold for 2× while held",
                    icon: "hare",
                    isOn: $longPress
                )
                Picker(selection: $skipInterval) {
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                } label: {
                    PreferenceLabel(
                        title: "Skip interval",
                        description: "The ± buttons and the double-tap jump",
                        icon: "goforward"
                    )
                }
            } header: {
                Text("Taps")
            }

            Section {
                Picker(selection: $sensitivity) {
                    Text("Low").tag(0.6)
                    Text("Normal").tag(1.0)
                    Text("High").tag(1.6)
                } label: {
                    PreferenceLabel(
                        title: "Sensitivity",
                        description: "How far a swipe moves what it controls",
                        icon: "dial.medium"
                    )
                }
            } header: {
                Text("Feel")
            } footer: {
                Text("Low asks for a longer drag, which makes fine seeking easier; high covers the whole range in a short one.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Videos tab's own preferences — Android's "Local Videos" screen, minus
/// the entries Photos makes meaningless (there are no folders to manage and no
/// thumbnails to generate; the library owns both).
struct LocalVideoPreferencesView: View {
    @AppStorage("mark_last_played") private var markLastPlayed = true
    @AppStorage("show_extension") private var showExtension = true

    var body: some View {
        List {
            Section {
                PreferenceToggle(
                    title: "Mark last played",
                    description: "Put an accent stripe on the video you played most recently",
                    icon: "bookmark",
                    isOn: $markLastPlayed
                )
                PreferenceToggle(
                    title: "Show file extension",
                    description: "\"holiday.mp4\" rather than \"holiday\"",
                    icon: "doc.text",
                    isOn: $showExtension
                )
            } header: {
                Text("Videos list")
            } footer: {
                Text("Folders and thumbnails are managed by the Photos library, so there is nothing to set for them here.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Local Videos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
