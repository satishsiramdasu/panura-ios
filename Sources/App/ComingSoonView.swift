import SwiftUI

/// What a tab added from the `+` shows until somebody builds it.
///
/// It exists so the shell can be laid out and walked through before either
/// feature is written, and it says so plainly rather than pretending to be an
/// empty state. An empty state means "nothing here yet, add something"; this
/// means "there is nothing here because it has not been made", and the two must
/// not look alike — the first invites a tap that cannot work.
///
/// ⚠️ This screen is reachable only while `FeatureFlags.showsPlannedTabs` is on,
/// and that flag must be off for a submission: Guideline 2.1 App Completeness
/// rejects a feature that announces itself and does nothing.
struct ComingSoonView: View {
    let destination: AppDestination

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: destination.icon(selected: false))
                .font(.system(size: 42))
                .foregroundStyle(destination.tint)

            Text(destination.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PanuraTheme.onSurface)

            Text(destination.detail)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)

            Text("Not built yet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanuraTheme.onAccentSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PanuraTheme.accentSoft, in: Capsule())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .background(PanuraTheme.background)
    }
}
