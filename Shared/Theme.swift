import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Brand palette

/// The fixed brand colours, expressed as dynamic colours so every one of them
/// has a considered dark-mode value.
///
/// Nothing in the UI reaches for a raw `Color(hex:)` — everything routes through
/// here or through ``ListTint`` so that a single edit re-themes the whole app.
///
/// The apricot and meadow values are sampled directly from `AppIcon.icon`, so
/// the app opens into the same palette the user just tapped on their Home
/// Screen.
/// ## Tone
/// The palette is deliberately quiet. The app icon sets the register — a muted
/// sage hill and a soft peach sky — and everything here is tuned to sit beside
/// those rather than shout over them.
///
/// Two rules keep it calm:
/// 1. **Colour carries meaning, never decoration.** A red only ever means
///    overdue or destructive; a green only ever means done.
/// 2. **Nothing is fully saturated.** Every value below is pulled back from its
///    pure hue, because a screen of todo items is something people look at for
///    a long time, and saturated colour is tiring.
enum Brand {
    /// Deep charcoal, from the icon's own mark. Used for the wordmark and for
    /// high-emphasis surfaces.
    static let ink = Color(light: 0x1C1B1F, dark: 0xF0F1F3)

    /// A soft olive. Used sparingly — favourites, and the "two" in twodos.
    /// The old lime was acid-bright and fought with everything near it.
    static let lime = Color(light: 0x8A8C3C, dark: 0xC3C57A)

    /// A muted heather. Retained so lists coloured on another device still
    /// resolve, but no longer the app's default accent.
    static let violet = Color(light: 0x6B5490, dark: 0xB6A5CE)

    // MARK: Icon palette

    /// The peach of the app icon's clouds, deepened enough in light mode to
    /// carry text at the required contrast.
    static let apricot = Color(light: 0xB0714B, dark: 0xE6BCA5)

    /// The icon's cloud colour at full strength — decorative fills only, never
    /// text or a glyph that has to be legible.
    static let apricotFill = Color(light: 0xF3C1A8, dark: 0xB88568)

    /// The icon's hill. The app's default accent.
    static let meadow = Color(light: 0x4A7E6B, dark: 0x93BCAC)

    /// The two stops of the hill gradient, in the icon's own order.
    static let meadowDeep = Color(rgb: 0x53907C)
    static let meadowSoft = Color(rgb: 0x89B4A5)

    // MARK: Semantic states
    //
    // Desaturated on purpose. These need to be *recognisable* at a glance, not
    // loud — an overdue list should catch the eye without looking like an alarm.

    static let danger = Color(light: 0xA1524B, dark: 0xE0A199)
    static let warning = Color(light: 0x9A7440, dark: 0xDCBA8A)
    static let success = Color(light: 0x4A7E6B, dark: 0x93BCAC)
    static let info = Color(light: 0x4E7391, dark: 0xA3C2D8)
}

// MARK: - Accent themes

/// The accent the user picks in Settings. Accent choice is a genuine
/// accessibility lever, not decoration: some people cannot separate the default
/// violet from the surrounding glass, and the graphite option removes hue from
/// the equation entirely.
enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    /// Sampled from the app icon's hill. The default, so the app opens into the
    /// colours the user just tapped.
    case meadow
    /// Sampled from the app icon's clouds.
    case apricot
    case violet, lime, ocean, sunset, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meadow: "Meadow"
        case .apricot: "Apricot"
        case .violet: "Violet"
        case .lime: "Lime"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .meadow: Brand.meadow
        case .apricot: Brand.apricot
        case .violet: Brand.violet
        case .lime: Brand.lime
        case .ocean: Color(light: 0x4E7391, dark: 0xA3C2D8)
        case .sunset: Color(light: 0xA9694E, dark: 0xDFAE95)
        case .graphite: Color(light: 0x555B64, dark: 0xB2B8C0)
        }
    }

    /// Whether this accent came from the app icon. Surfaced in Settings so the
    /// two icon colours read as "the app's own" rather than arbitrary choices.
    var isFromAppIcon: Bool {
        self == .meadow || self == .apricot
    }
}

// MARK: - List tints

/// The eight list colours the API stores as hex strings.
///
/// The server is the source of truth for the hex value, so a list coloured on
/// Android arrives here as `#504E8C`. We match it back to a known tint to get a
/// dark-mode-correct rendering, and fall back to the literal hex for anything
/// unrecognised so no list ever loses its colour.
struct ListTint: Identifiable, Hashable, Sendable {
    let hex: String
    let name: String
    private let lightValue: UInt32
    private let darkValue: UInt32

    var id: String { hex }

    var color: Color { Color(light: lightValue, dark: darkValue) }

    /// Muted throughout. A list colour is an identifier, not an accent — you
    /// need to tell two lists apart at a glance, which takes far less intensity
    /// than these once had.
    ///
    /// The two tones per colour are lifted from the reference design, where
    /// every swatch is a saturated ring around a pale centre. Light mode takes
    /// the ring, dark mode the centre — a hue dark enough to read against white
    /// glass turns to mud on black, and the pale tone that glows on black is
    /// invisible on white. Both tones are desaturated and slightly cool, which
    /// is what stops eight of them side by side from looking like a paint chart.
    ///
    /// `hex` is the server's identity for the colour and is deliberately
    /// *unchanged* from the previous palette. Only the rendering moved, so every
    /// list already coloured keeps its identity and simply looks better —
    /// re-keying these would have dropped existing lists into the `Custom`
    /// branch of ``resolve(_:)`` and frozen them on the old tones.
    static let all: [ListTint] = [
        ListTint(hex: "#7A7A7A", name: "Stone", lightValue: 0x6F757B, darkValue: 0xB4BAC0),
        ListTint(hex: "#504E8C", name: "Periwinkle", lightValue: 0x5A5893, darkValue: 0xCDCCEA),
        ListTint(hex: "#875353", name: "Clay", lightValue: 0x8A5F5E, darkValue: 0xDBBBBA),
        ListTint(hex: "#9D8C57", name: "Olive", lightValue: 0x94975C, darkValue: 0xD3D5AA),
        ListTint(hex: "#7A588A", name: "Orchid", lightValue: 0x7A5E8D, darkValue: 0xCDBCD8),
        ListTint(hex: "#4E8C6F", name: "Fern", lightValue: 0x5E8A72, darkValue: 0xB6D3C2),
        ListTint(hex: "#4E6E8C", name: "Harbour", lightValue: 0x5B7B96, darkValue: 0xB3CBDD),
        ListTint(hex: "#8C4E4E", name: "Rose", lightValue: 0x9A6570, darkValue: 0xE0B9C1)
    ]

    /// Resolves a server-supplied hex to a tint, tolerating case and a missing `#`.
    static func resolve(_ hex: String?) -> ListTint {
        guard let hex, !hex.isEmpty else { return all[0] }
        let normalised = "#" + hex.replacingOccurrences(of: "#", with: "").uppercased()
        if let match = all.first(where: { $0.hex.uppercased() == normalised }) { return match }
        // Unknown colour from another client — honour it verbatim.
        let raw = UInt32(normalised.dropFirst(), radix: 16) ?? 0x7A7A7A
        return ListTint(hex: normalised, name: "Custom", lightValue: raw, darkValue: raw)
    }
}

// MARK: - Colour helpers

extension Color {
    /// Builds a colour that resolves differently in light and dark mode.
    ///
    /// Every brand colour goes through here rather than shipping one fixed hex,
    /// because a hex tuned for a white background turns to mud on black glass.
    ///
    /// watchOS has no light appearance, so there it resolves straight to the
    /// dark value — which is also why the watch palette needs no runtime
    /// trait lookup at all.
    init(light: UInt32, dark: UInt32) {
        #if os(watchOS)
        self.init(rgb: dark)
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

#if !os(watchOS)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

// MARK: - Metrics

/// Shared geometry. Corner radii follow the iOS 26 concentric-corner rule:
/// a control inset by `n` inside a container of radius `r` gets radius `r - n`.
enum Metrics {
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 14
    static let sheetRadius: CGFloat = 28
    static let cardPadding: CGFloat = 16
    static let gutter: CGFloat = 16
    static let rowSpacing: CGFloat = 10
}
