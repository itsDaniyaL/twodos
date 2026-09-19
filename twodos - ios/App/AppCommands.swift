import SwiftUI

/// Menu-bar commands and keyboard shortcuts.
///
/// ## Why this exists
/// On a Mac the app *is* the iPad build — "Designed for iPad", no separate
/// target — and nothing in the iPad build assumed a keyboard or a mouse. Every
/// refresh was a pull, every screen was reached by tap, and the menu bar held
/// only the system's defaults. A Mac app with no ⌘N and no way to refresh from
/// a mouse is missing features, whatever the code says it can do. These are
/// the same shortcuts on an iPad with a keyboard, where holding ⌘ lists them.
///
/// ## Why signals rather than focused values
/// SwiftUI's `@FocusedValue` route needs a focused view to publish the action,
/// and on iPad and Mac focus is often nowhere — the user has just clicked a
/// card and nothing is first responder. A counter that the owning view watches
/// works whatever is focused, and it is the shape ``IntentNavigation`` already
/// uses for Siri. Counters rather than flags so two presses in a row both fire.
@MainActor
@Observable
final class AppCommands {
    private(set) var newListRequests = 0
    private(set) var newItemRequests = 0
    private(set) var refreshRequests = 0
    private(set) var searchRequests = 0
    private(set) var tabRequest: TabRequest?

    struct TabRequest: Equatable {
        let serial: Int
        let tab: MainTabView.Tabs
    }

    /// The list on screen, if any — kept by ``ListDetailView`` so "New Item"
    /// can be greyed out when there is nowhere to add one.
    var openListId: String?

    func newList() { newListRequests += 1 }
    func newItem() { newItemRequests += 1 }
    func refresh() { refreshRequests += 1 }
    func search() { searchRequests += 1 }

    func show(_ tab: MainTabView.Tabs) {
        tabRequest = TabRequest(serial: (tabRequest?.serial ?? 0) + 1, tab: tab)
    }
}

/// What goes in the menu bar.
///
/// Placed in the standard menus where a Mac user looks for them — New under
/// File, Refresh under View — plus a Go menu for the tabs, which is what Mail
/// and Notes do with theirs. Everything is disabled while signed out rather
/// than hidden, so the menu keeps its shape.
struct TwodosCommands: Commands {
    let commands: AppCommands
    let isSignedIn: Bool
    /// Read in the App body and passed in, so the item re-evaluates when a list
    /// opens or closes — the App body is what SwiftUI is certain to watch.
    let hasOpenList: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New List…") { commands.newList() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!isSignedIn)

            Button("New Item") { commands.newItem() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!isSignedIn || !hasOpenList)
        }

        CommandGroup(after: .toolbar) {
            // Pull-to-refresh needs a finger. The socket keeps a shared list
            // current and coming to the foreground reconciles, but a person at
            // a Mac who wants to *know* it is current needs something to press.
            Button("Refresh") { commands.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!isSignedIn)
        }

        CommandMenu("Go") {
            Button("Lists") { commands.show(.lists) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!isSignedIn)
            Button("Alarms") { commands.show(.alarms) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!isSignedIn)
            Button("Activity") { commands.show(.activity) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!isSignedIn)
            Button("You") { commands.show(.profile) }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(!isSignedIn)

            Divider()

            // ⌥⌘F, not ⌘F: the system already binds ⌘F to Find inside text
            // views, and a shortcut that only works when no field is focused
            // is worse than one that always does. Mail and Notes make the same
            // choice for the same reason.
            Button("Search") { commands.search() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!isSignedIn)
        }
    }
}
