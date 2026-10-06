import SwiftUI

/// Language.
///
/// Switches the running app at once, with a short fade so the change reads as
/// deliberate, then offers "Keep" — and goes back by itself if nobody answers,
/// because somebody who picked a language they cannot read may not be able to
/// find the way back. See ``LanguageStore``.
///
/// Each language is listed in its own language. "System default" is the one
/// row that is translated, since it is a sentence rather than a name.
struct LanguageSettingsView: View {
    @Environment(LanguageStore.self) private var languages

    var body: some View {
        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    GlassSection(
                        title: "Language",
                        footer: "twodos changes straight away. Keep the new language, or it switches back on its own after a few seconds."
                    ) {
                        ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { index, option in
                            if index > 0 { GlassDivider() }
                            row(for: option)
                        }
                    }

                    GlassSection(
                        footer: "Emails from twodos, and what your partner sees, stay in English or their own language — this only changes the app on this device."
                    ) {
                        GlassRow(
                            icon: "gear",
                            title: "Language in iOS Settings",
                            subtitle: "The same setting, under Settings → Apps → twodos",
                            showsChevron: true,
                            action: openSettings
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for option: AppLanguage) -> some View {
        let isSelected = languages.language == option
        return Button {
            Haptics.selection()
            languages.select(option)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let endonym = option.endonym {
                        // Verbatim: a language's own name is never translated.
                        Text(verbatim: endonym)
                            .font(.body)
                    } else {
                        Text("System default")
                            .font(.body)
                        Text("Follows your device — currently \(languages.effectiveLanguage.endonym ?? "English")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 13)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motion(Motion.tap, value: isSelected)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
