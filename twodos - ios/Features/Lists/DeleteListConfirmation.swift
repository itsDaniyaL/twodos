import SwiftUI

/// The one confirmation every route to deleting a list goes through.
///
/// Deleting used to be immediate with a five-second undo banner. That put the
/// decision *after* the action, in a banner the user had to notice and reach
/// for — and the request it deferred could fail after the list had long since
/// left the screen, surfacing as an error about something the user thought was
/// finished. A dialog puts the decision first, says exactly what goes with the
/// list, and means the server hears about the delete while the user is still
/// looking at it.
extension View {
    func deleteListConfirmation(
        _ list: TodoList?,
        isPresented: Binding<Bool>,
        currentUserId: String?,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Delete “\(list?.label ?? "this list")”?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete list", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DeleteListWarning.message(for: list, currentUserId: currentUserId))
        }
    }
}

enum DeleteListWarning {
    /// What the user is about to lose, in one sentence.
    ///
    /// The API deletes a shared list differently depending on who asks, so the
    /// warning has to say which one is about to happen — and it always states
    /// the item count, because "the list" undersells a list with forty things
    /// in it.
    static func message(for list: TodoList?, currentUserId: String?) -> String {
        guard let list else { return "This can't be undone." }

        let items: String
        switch list.totalCount {
        case 0: items = "It has no items."
        case 1: items = "The 1 item in it will be deleted too."
        default: items = "The \(list.totalCount) items in it will be deleted too."
        }

        if list.isEffectivelyPersonal(currentUserId: currentUserId) {
            return "This permanently deletes the list. \(items)"
        }
        return list.createdBy == currentUserId
            ? "This deletes the list for both of you, permanently. \(items)"
            : "This removes the list from your account. Your partner keeps their copy."
    }
}
