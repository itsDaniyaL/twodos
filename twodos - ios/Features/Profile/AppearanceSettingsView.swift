import SwiftUI

/// Appearance controls, with a live preview so the user can see the result
/// before committing rather than guessing from a swatch name.
struct AppearanceSettingsView: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        @Bindable var theme = theme

        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    preview

                    GlassSection(
                        title: "Theme",
                        footer: "Automatic follows your device's light and dark setting."
                    ) {
                        Picker("Theme", selection: $theme.appearance) {
                            ForEach(ThemeStore.Appearance.allCases) { option in
                                Label(option.title, systemImage: option.icon).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(Metrics.cardPadding)
                        .onChange(of: theme.appearance) { _, _ in Haptics.selection() }
                    }

                    accentPicker

                    GlassSection(
                        title: "Text size",
                        footer: "This adjusts twodos only. Your device's own text size setting still applies on top."
                    ) {
                        Picker("Text size", selection: $theme.textSize) {
                            ForEach(ThemeStore.TextSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(Metrics.cardPadding)
                        .onChange(of: theme.textSize) { _, _ in Haptics.selection() }
                    }

                    GlassSection(
                        title: "List cards",
                        footer: "Every card shows its list's colour. On washes the whole card in it — bolder, but busier when you have a lot of lists."
                    ) {
                        GlassRow(
                            icon: "paintpalette",
                            title: "Tint the whole card",
                            subtitle: "Use each list's colour as its background"
                        ) {
                            Toggle("", isOn: $theme.tintEntireCard)
                                .labelsHidden()
                                .onChange(of: theme.tintEntireCard) { _, _ in Haptics.selection() }
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Preview

    /// A mock list card that reacts live to every control below it.
    ///
    /// It has to contain something each control can visibly change, or the
    /// preview quietly stops being one. The card previously used a fixed list
    /// tint and fixed brand colours throughout, so changing the accent — the
    /// control most likely to send someone here — altered nothing on screen and
    /// the preview looked broken.
    ///
    /// So: the accent drives the progress ring, the section label and the
    /// deadline chip, exactly as it does on the real screens through `.tint`.
    /// The list tint stays a list tint, because that is what it is — the card
    /// would be lying if the accent recoloured it.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Preview")

            GlassCard(
                tint: previewTint,
                tintStrength: theme.tintEntireCard ? 0.26 : 0.11
            ) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(previewTint)
                        Circle()
                            .stroke(.white.opacity(0.32), lineWidth: 3)
                            .frame(width: 26, height: 26)
                        Circle()
                            .trim(from: 0, to: 0.6)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 26, height: 26)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 46, height: 46)
                    .shadow(color: previewTint.opacity(0.35), radius: 5, y: 2)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("Weekend trip").font(.headline)
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(theme.accent.color)
                        }
                        Text("3 of 5 done")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            MetaChip(icon: "clock", text: "Tomorrow, 09:00",
                                     tint: theme.accent.color, emphasised: true)
                            MetaChip(icon: "person.2.fill", text: "Sam")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Metrics.cardPadding)
            }
            // Every control below is named here, so a change to any of them
            // animates rather than snapping. `textSize` included: the card
            // reflows when it changes, and an unanimated reflow reads as a
            // glitch rather than as the setting taking effect.
            .motion(Motion.content, value: theme.tintEntireCard)
            .motion(Motion.content, value: theme.accent)
            .motion(Motion.content, value: theme.textSize)
            .accessibilityHidden(true)
        }
    }

    /// Graphite removes hue from the interface, so the preview card follows it
    /// to a neutral list colour — otherwise the one accent whose entire purpose
    /// is "no colour" would still show a coloured card.
    private var previewTint: Color {
        theme.accent == .graphite ? ListTint.all[0].color : ListTint.all[1].color
    }

    // MARK: - Accent

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Accent colour")

            GlassCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 12) {
                    ForEach(AccentTheme.allCases) { accent in
                        Button {
                            withAnimation(Motion.content) { theme.accent = accent }
                            Haptics.selection()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(accent.color)
                                        .frame(width: 38, height: 38)
                                    if theme.accent == accent {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(
                                        theme.accent == accent ? Color.primary.opacity(0.4) : .clear,
                                        lineWidth: 2
                                    )
                                }
                                .scaleEffect(theme.accent == accent ? 1.08 : 1)

                                Text(accent.title)
                                    .font(.caption2)
                                    .foregroundStyle(theme.accent == accent ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.title)
                        .accessibilityAddTraits(theme.accent == accent ? .isSelected : [])
                    }
                }
                .padding(Metrics.cardPadding)
            }
            .motion(Motion.tap, value: theme.accent)

            Text("Graphite removes colour from the interface entirely, which can make text easier to separate from the background.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
