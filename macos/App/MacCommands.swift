import SwiftUI

/// What the sidebar can be showing.
///
/// Four, where iOS has five tabs: "You" is missing on purpose. Its contents are
/// preferences, and on a Mac preferences live behind ⌘, in a Settings window,
/// not in the navigation. Search is likewise not a destination here — it is a
/// field in the toolbar, which is where a Mac user looks for it.
enum MacSection: String, Hashable, Identifiable, CaseIterable {
    case lists, alarms, activity, partners

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lists: "Lists"
        case .alarms: "Alarms"
        case .activity: "Activity"
        case .partners: "Partners"
        }
    }

    var icon: String {
        switch self {
        case .lists: "checklist"
        case .alarms: "alarm"
        case .activity: "bell"
        case .partners: "person.2"
        }
    }

    /// ⌘1 … ⌘4, in sidebar order — the convention Mail and Notes use for
    /// jumping between top-level sections.
    var shortcut: KeyEquivalent {
        switch self {
        case .lists: "1"
        case .alarms: "2"
        case .activity: "3"
        case .partners: "4"
        }
    }
}

/// Menu-bar actions, as counters the owning view watches.
///
/// The same design as the iOS `AppCommands` and for the same reason:
/// SwiftUI's `@FocusedValue` route needs a focused view to publish the action,
/// and after a click on a card focus is frequently nowhere. A counter works
/// whatever is first responder, and counting rather than flagging means two
/// presses in a row both fire.
@MainActor
@Observable
final class MacCommands {
    private(set) var newListRequests = 0
    private(set) var newItemRequests = 0
    private(set) var refreshRequests = 0
    private(set) var focusSearchRequests = 0
    private(set) var sectionRequest: SectionRequest?

    struct SectionRequest: Equatable {
        let serial: Int
        let section: MacSection
    }

    /// The list on screen, so "New Item" can be greyed out when there is
    /// nowhere to put one. A disabled menu item explains the app's state; a
    /// missing one just looks broken.
    var openListId: String?

    func newList() { newListRequests += 1 }
    func newItem() { newItemRequests += 1 }
    func refresh() { refreshRequests += 1 }
    func focusSearch() { focusSearchRequests += 1 }

    func show(_ section: MacSection) {
        sectionRequest = SectionRequest(serial: (sectionRequest?.serial ?? 0) + 1, section: section)
    }
}

/// The menu bar.
///
/// Everything sits in the menu a Mac user would open looking for it — New under
/// File, Refresh under View, a Go menu for the sections the way Mail has one.
/// Items are disabled rather than hidden while signed out, so the menus keep
/// their shape and nothing appears to move around.
struct MacMenuCommands: Commands {
    let commands: MacCommands
    let isSignedIn: Bool

    var body: some Commands {
        // Replaces the template's "New Item" rather than adding beside it:
        // two New entries in File, one of them doing nothing, is worse than
        // none.
        CommandGroup(replacing: .newItem) {
            Button("New List") { commands.newList() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!isSignedIn)

            Button("New Item") { commands.newItem() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!isSignedIn || commands.openListId == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { commands.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!isSignedIn)

            Divider()

            Button("Find") { commands.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!isSignedIn)
        }

        CommandMenu("Go") {
            ForEach(MacSection.allCases) { section in
                Button(section.title) { commands.show(section) }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(!isSignedIn)
            }
        }
    }
}
