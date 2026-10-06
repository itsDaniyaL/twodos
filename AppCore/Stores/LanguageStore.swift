import SwiftUI
import OSLog

/// A language the app can be read in.
///
/// The same four Android ships, so a couple on different phones can read the
/// app in the same language. Each is named in its own language — "Deutsch",
/// never "German" — because the person who most needs this list is somebody
/// looking at an app in a language they cannot read, and translating "Русский"
/// into the current language hides it from exactly them.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case german = "de"
    case russian = "ru"
    case dutch = "nl"

    var id: String { rawValue }

    /// The bundle localization, or nil for "follow the device".
    var code: String? { self == .system ? nil : rawValue }

    /// The language's own name. Nil for System, which is a sentence rather
    /// than a name and is translated like any other text.
    var endonym: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .german: "Deutsch"
        case .russian: "Русский"
        case .dutch: "Nederlands"
        }
    }
}

/// The in-app language setting.
///
/// ## Why the app has its own picker
/// iOS and macOS both offer a per-app language in system settings, and this
/// writes to the same place (`AppleLanguages`) so the two never disagree on the
/// next launch. But the system route needs a relaunch and is three levels deep
/// where nobody looks; this one switches the running app at once.
///
/// ## How the running app switches
/// Two things change together:
///
/// * **`Bundle.main` is redirected** to the chosen `.lproj`, so everything
///   that asks the bundle — `String(localized:)`, `Text` — gets the new
///   language from then on. See ``LanguageBundle``.
/// * **The SwiftUI locale is replaced** at the root (`.appLanguage()`), so
///   every `Text` built from a literal re-resolves straight away.
///
/// A few strings computed once and held — a label cached in a view's state —
/// update the next time their screen opens. Dates and numbers keep the device's
/// format until the next launch, because `Locale.current` is fixed per process.
///
/// ## Why a change has to be kept
/// After a switch the app asks whether to keep it and goes back by itself if
/// nobody answers — the pattern a display-resolution change uses. Somebody who
/// tapped "Русский" by mistake may be unable to read the screen that would
/// let them undo it, so doing nothing has to be a way back.
@MainActor
@Observable
final class LanguageStore {
    static let shared = LanguageStore()

    /// How long a new language is on trial before it reverts on its own.
    static let trialSeconds = 15

    private let logger = Logger(subsystem: "app.twodos", category: "language")
    private let defaults = UserDefaults.standard
    private static let storageKey = "app.language"

    /// What the user chose.
    private(set) var language: AppLanguage

    /// A change awaiting "Keep" — what to go back to, and when.
    struct Trial: Equatable {
        let previous: AppLanguage
        /// The previous language's own name, captured before the switch —
        /// for System it depends on preferences the switch is about to change.
        let previousName: String
        let revertsAt: Date
    }
    private(set) var trial: Trial?

    /// Bumped on every switch; drives the transition overlay.
    private(set) var switchCount = 0

    private var revertTask: Task<Void, Never>?

    private init() {
        language = AppLanguage(rawValue: defaults.string(forKey: Self.storageKey) ?? "") ?? .system
        LanguageBundle.activate(localization: Self.resolvedLocalization(for: language))
    }

    /// The locale SwiftUI renders with.
    var locale: Locale { Locale(identifier: Self.resolvedLocalization(for: language)) }

    /// The language actually showing — what System currently resolves to.
    var effectiveLanguage: AppLanguage {
        AppLanguage(rawValue: Self.resolvedLocalization(for: language)) ?? .english
    }

    // MARK: - Choosing

    /// Switches language now and starts the trial.
    ///
    /// Choosing again during a trial keeps the *original* language as the way
    /// back: three quick taps through the list should not leave "undo" pointing
    /// at the second of them.
    func select(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        let previous = trial?.previous ?? language
        let previousName = trial?.previousName ?? (language.endonym ?? effectiveLanguage.endonym ?? "English")
        apply(newValue)

        if newValue == previous {
            endTrial()
        } else {
            trial = Trial(previous: previous, previousName: previousName,
                          revertsAt: .now.addingTimeInterval(TimeInterval(Self.trialSeconds)))
            scheduleRevert()
        }
    }

    /// Keeps the language on trial.
    func keep() {
        endTrial()
        logger.info("Kept language \(self.language.rawValue, privacy: .public)")
    }

    /// Goes back to the language before the trial.
    func revert() {
        guard let trial else { return }
        endTrial()
        apply(trial.previous)
        logger.info("Reverted language to \(trial.previous.rawValue, privacy: .public)")
    }

    // MARK: - Applying

    private func apply(_ newValue: AppLanguage) {
        if let code = newValue.code {
            defaults.set(newValue.rawValue, forKey: Self.storageKey)
            // The system's own per-app setting, so the next cold launch — and
            // the Settings app — agree with what was chosen here.
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: Self.storageKey)
            defaults.removeObject(forKey: "AppleLanguages")
        }
        LanguageBundle.activate(localization: Self.resolvedLocalization(for: newValue))
        withAnimation(.easeInOut(duration: 0.35)) {
            language = newValue
            switchCount += 1
        }
    }

    private func scheduleRevert() {
        revertTask?.cancel()
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.trialSeconds))
            guard !Task.isCancelled else { return }
            self?.revert()
        }
    }

    private func endTrial() {
        revertTask?.cancel()
        revertTask = nil
        withAnimation(.easeInOut(duration: 0.25)) { trial = nil }
    }

    /// The bundle localization a choice resolves to.
    ///
    /// System is resolved here rather than left to the bundle: the bundle
    /// decided its language at launch from whatever `AppleLanguages` said
    /// *then*, which may be the language being left. Asking afresh, after the
    /// override has been removed, gives the device's real preference.
    private static func resolvedLocalization(for language: AppLanguage) -> String {
        if let code = language.code { return code }
        let shipped = AppLanguage.allCases.compactMap(\.code)
        return Bundle.preferredLocalizations(from: shipped, forPreferences: Locale.preferredLanguages).first
            ?? "en"
    }
}

// MARK: - Bundle redirection

/// Points `Bundle.main`'s string lookups at one `.lproj` while the app runs.
///
/// The bundle chooses its localization once, at launch. Swapping its class for
/// a subclass that forwards `localizedString` to the chosen language's own
/// bundle is the one way to change that without a relaunch. It touches string
/// lookup only; resources, images and everything else resolve as before.
enum LanguageBundle {
    /// The `.lproj` bundle strings are read from. Written on the main actor,
    /// read from wherever a string is looked up.
    nonisolated(unsafe) static var current: Bundle?

    nonisolated(unsafe) private static var isInstalled = false

    static func activate(localization: String) {
        if !isInstalled {
            object_setClass(Bundle.main, RedirectingBundle.self)
            isInstalled = true
        }
        current = Bundle.main.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

private final class RedirectingBundle: Bundle, @unchecked Sendable {
    nonisolated override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        // `current` is a plain Bundle, not this class, so there is no loop.
        if let current = LanguageBundle.current {
            return current.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// MARK: - Root modifier

/// Applies the chosen language to a view tree and animates the change.
///
/// Sits at the root of every window. The overlay is a short cross-fade with the
/// new language's name on it — enough to say "this changed on purpose" without
/// hiding the screen the person wants to check.
struct LanguageContainer: ViewModifier {
    @Environment(LanguageStore.self) private var languages
    @State private var flashing = false

    func body(content: Content) -> some View {
        content
            .environment(\.locale, languages.locale)
            .overlay {
                if flashing {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        VStack(spacing: 6) {
                            Image(systemName: "character.bubble")
                                .font(.system(size: 34, weight: .medium))
                            Text(verbatim: languages.effectiveLanguage.endonym ?? "")
                                .font(.title2.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: languages.switchCount) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { flashing = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(550))
                    withAnimation(.easeIn(duration: 0.35)) { flashing = false }
                }
            }
    }
}

/// "Keep Deutsch?" — offered after every switch, at the bottom of the window.
///
/// Both buttons name a language in that language, so the way back is readable
/// even to someone who cannot read the one on screen.
struct LanguageTrialBar: View {
    @Environment(LanguageStore.self) private var languages

    var body: some View {
        if let trial = languages.trial {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(trial.revertsAt.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 12) {
                    Image(systemName: "character.bubble")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep this language?")
                            .font(.subheadline.weight(.semibold))
                        Text("Going back in \(remaining) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button {
                        languages.revert()
                    } label: {
                        Text(verbatim: "↩︎ " + trial.previousName)
                    }
                    .buttonStyle(.bordered)
                    Button("Keep") { languages.keep() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Clear of the tab bar on iOS; a Mac window has nothing along its bottom.
#if os(iOS)
private let trialBarInset: CGFloat = 96
#else
private let trialBarInset: CGFloat = 20
#endif

extension View {
    /// The chosen language, its switch animation, and the keep-or-revert bar.
    func appLanguage() -> some View {
        modifier(LanguageContainer())
            .overlay(alignment: .bottom) {
                LanguageTrialBar()
                    .padding(.bottom, trialBarInset)
            }
    }
}
