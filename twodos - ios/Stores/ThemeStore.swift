import SwiftUI

/// Appearance preferences.
///
/// The goal here is that a user can make the app comfortable without leaving it:
/// light/dark, an accent that works for their eyes, and a text size that does
/// not require changing a system-wide setting. Dynamic Type is still honoured on
/// top of this — the in-app control shifts the baseline, it does not override
/// the user's system choice.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let appearance = "theme.appearance"
        static let accent = "theme.accent"
        static let textSize = "theme.textSize"
        static let listColorsInCards = "theme.listColorsInCards"
    }

    // MARK: - Appearance

    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "Automatic"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var icon: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var accent: AccentTheme {
        didSet { defaults.set(accent.rawValue, forKey: Key.accent) }
    }

    // MARK: - Text size

    /// An in-app nudge on top of the system Dynamic Type setting. Someone who
    /// keeps their phone at the default size but wants larger text *here* can
    /// have it without changing every other app.
    enum TextSize: String, CaseIterable, Identifiable, Sendable {
        case compact, standard, large

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compact: "Compact"
            case .standard: "Standard"
            case .large: "Large"
            }
        }

        /// Applied via `dynamicTypeSize(...partial range)` so the user's own
        /// accessibility sizes are never capped away.
        var scale: CGFloat {
            switch self {
            case .compact: 0.92
            case .standard: 1.0
            case .large: 1.14
            }
        }
    }

    var textSize: TextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }

    /// Whether list colours tint the whole card or only the leading accent bar.
    /// Off by default: a wall of tinted cards is pretty in a screenshot and
    /// tiring to actually read.
    var tintEntireCard: Bool {
        didSet { defaults.set(tintEntireCard, forKey: Key.listColorsInCards) }
    }

    private init() {
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        accent = AccentTheme(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .meadow
        textSize = TextSize(rawValue: defaults.string(forKey: Key.textSize) ?? "") ?? .standard
        tintEntireCard = defaults.bool(forKey: Key.listColorsInCards)
    }
}

/// Applies the user's appearance choices to a view tree.
struct ThemedContainer: ViewModifier {
    @Environment(ThemeStore.self) private var theme

    func body(content: Content) -> some View {
        content
            .tint(theme.accent.color)
            .preferredColorScheme(theme.appearance.colorScheme)
            .environment(\.textSizeScale, theme.textSize.scale)
    }
}

private struct TextSizeScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var textSizeScale: CGFloat {
        get { self[TextSizeScaleKey.self] }
        set { self[TextSizeScaleKey.self] = newValue }
    }
}

extension View {
    func themed() -> some View { modifier(ThemedContainer()) }
}
