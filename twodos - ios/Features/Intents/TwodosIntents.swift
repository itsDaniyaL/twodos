import AppIntents
import SwiftUI
import WidgetKit

/// Siri, Shortcuts, the Action Button and Spotlight.
///
/// ## Why these live in the app target
/// An `AppIntent` declared in the app runs in the app's own process — launched
/// in the background if it is not already open. That matters here: adding an
/// item needs the session token, and the token lives in this app's keychain.
///
/// Putting the intents in a separate extension would have meant a shared
/// keychain access group, which in turn means two processes able to present the
/// same refresh token. This API destroys every session on the account when a
/// spent refresh token is reused, so the cheapest correct answer is to keep
/// exactly one process holding credentials.
///
/// ## Why they use `APIClient` and not `AppStore`
/// A background launch has no view tree and no `AppStore` — that object is owned
/// by the SwiftUI scene. `APIClient` is a singleton over `TokenStore`, which is
/// all a write needs. The app reconciles on its next refresh, and the widgets
/// are nudged directly below.

// MARK: - Add an item

struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to a list"
    static var description = IntentDescription(
        "Adds an item to one of your twodos lists.",
        categoryName: "Lists"
    )

    /// The whole point is not opening the app. "Add milk to the weekly shop"
    /// should be over before the phone is back in a pocket.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Item", requestValueDialog: "What should I add?")
    var title: String

    @Parameter(title: "List", requestValueDialog: "Which list?")
    var list: TodoListEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.emptyTitle
        }
        guard TokenStore.shared.hasSession else {
            throw IntentError.signedOut
        }

        do {
            _ = try await APIClient.shared.createTodo(listId: list.id, title: trimmed)
        } catch {
            throw IntentError.requestFailed
        }

        // The snapshot on disk is now one item out of date. Refreshing it
        // properly needs the full model, which this process does not have — so
        // ask WidgetKit to reload and let the next app refresh write the truth.
        // A widget that is briefly one item stale is better than one that stays
        // wrong until the app is opened.
        WidgetCenter.shared.reloadAllTimelines()

        return .result(dialog: "Added “\(trimmed)” to \(list.label).")
    }
}

// MARK: - Open a list

struct OpenListIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a list"
    static var description = IntentDescription(
        "Opens one of your twodos lists.",
        categoryName: "Lists"
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "List", requestValueDialog: "Which list?")
    var list: TodoListEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Goes through the same `pendingListToOpen` channel a notification tap
        // and a widget tap use, so there is one path into a list rather than
        // three that have to be kept behaving alike.
        IntentNavigation.shared.request(.list(id: list.id))
        return .result()
    }
}

// MARK: - Ask what's outstanding

struct OutstandingCountIntent: AppIntent {
    static var title: LocalizedStringResource = "What's outstanding"
    static var description = IntentDescription(
        "Tells you how much is left across your lists.",
        categoryName: "Lists"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = WidgetSnapshotStore.load()

        guard snapshot.isSignedIn else { throw IntentError.signedOut }
        guard snapshot.openCount > 0 else {
            return .result(dialog: "Nothing outstanding.")
        }

        // Leads with lateness, because that is the part worth interrupting
        // someone for. The rest is a count they can act on or ignore.
        var spoken = "\(snapshot.openCount) open"
        if snapshot.overdueCount > 0 {
            spoken += ", \(snapshot.overdueCount) overdue"
        } else if snapshot.dueTodayCount > 0 {
            spoken += ", \(snapshot.dueTodayCount) due today"
        }
        if let next = snapshot.headline {
            spoken += ". Next up: \(next.title)."
        }
        return .result(dialog: "\(spoken)")
    }
}

// MARK: - Errors

/// Phrased for speech. Siri reads these aloud, so they say what happened and
/// what to do — not a status code.
enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case emptyTitle
    case requestFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            "You're not signed in to twodos. Open the app to sign in first."
        case .emptyTitle:
            "I need something to add."
        case .requestFailed:
            "I couldn't reach twodos just now. Try again in a moment."
        }
    }
}

// MARK: - Navigation bridge

/// Carries an intent's navigation request into the running app.
///
/// An intent may run before the scene exists, so this holds the request the same
/// way `AppStore` holds a deferred deep link — and for the same reason. The app
/// drains it on appear.
@MainActor
@Observable
final class IntentNavigation {
    static let shared = IntentNavigation()
    private init() {}

    private(set) var pending: DeepLink?

    func request(_ link: DeepLink) { pending = link }

    func take() -> DeepLink? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Shortcuts

/// The phrases that work without the user building anything in Shortcuts.
///
/// Every phrase must contain the app name — the system requires it, and it is
/// also what stops "add milk" from being ambiguous across every app on the
/// phone.
struct TwodosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OutstandingCountIntent(),
            phrases: [
                "What's outstanding in \(.applicationName)",
                "What's left in \(.applicationName)",
                "Check \(.applicationName)"
            ],
            shortTitle: "What's outstanding",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "Add to \(.applicationName)",
                "Add an item to \(.applicationName)"
            ],
            shortTitle: "Add to a list",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenListIntent(),
            phrases: [
                "Open a list in \(.applicationName)",
                "Show my \(.applicationName) list"
            ],
            shortTitle: "Open a list",
            systemImageName: "list.bullet"
        )
    }
}
