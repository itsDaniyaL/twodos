import AppIntents
import WidgetKit

/// Ticks an item off from the Home Screen.
///
/// ## Where this runs
/// Unlike the intents in `TwodosIntents.swift`, this one runs inside the
/// **widget extension** — that is what WidgetKit does for a `Button(intent:)`.
/// So it lives in `Shared/` and is compiled into both targets.
///
/// ## What it can and cannot do
/// The extension can read the access token from the shared keychain group, so
/// while that token is fresh — an hour from the app's last refresh — a tap
/// reaches the API immediately and the user's partner sees it at once.
///
/// It can never *renew* that token. The refresh token stays in the app's private
/// keychain, because this API destroys every session on the account when a spent
/// refresh token is replayed, and two processes racing to renew one is exactly
/// how that happens. When the token has lapsed the tap is queued instead and the
/// app replays it on next launch.
///
/// Either way the snapshot is updated first, so the checkbox responds on the
/// next frame and never appears to have ignored the tap.
struct ToggleTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick an item off"
    static var description = IntentDescription("Marks a twodos item as done, or not done.")

    /// Nothing about this needs the app on screen — that is the whole point of
    /// an interactive widget.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "List") var listId: String
    @Parameter(title: "Item") var todoId: String
    @Parameter(title: "Done") var done: Bool

    init() {}

    init(listId: String, todoId: String, done: Bool) {
        self.listId = listId
        self.todoId = todoId
        self.done = done
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The visible change first. WidgetKit reloads the timeline after an
        // intent returns, so if the snapshot were updated last the row would
        // redraw in its old state before flipping — a visible stutter on
        // something as small as a checkbox.
        applyOptimistically()

        guard TokenStore.shared.hasSession,
              TokenStore.shared.accessTokenNeedsRefresh(window: 0) == false else {
            // No usable token, and no way to get one from here.
            enqueue()
            return .result()
        }

        do {
            _ = try await APIClient.shared.setTodoDone(listId: listId, todoId: todoId, done: done)
        } catch {
            // Offline, or the token expired between the check and the call.
            enqueue()
        }
        return .result()
    }

    /// Writes the snapshot as it will look once this item is done, so the row
    /// disappears on the next frame rather than after a round trip.
    private func applyOptimistically() {
        let snapshot = WidgetSnapshotStore.load()
        WidgetSnapshotStore.save(snapshot.completing(todoId: todoId, listId: listId))
    }

    private func enqueue() {
        // The same log the app writes to when a tap fails offline. One queue,
        // not two that have to be kept agreeing with each other.
        PendingMutationLog.enqueue(
            PendingMutation(kind: .setDone(listId: listId, todoId: todoId, done: done))
        )
    }
}
