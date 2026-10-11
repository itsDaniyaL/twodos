import SwiftUI

extension View {
    /// Lets an open item be picked up and dropped onto another to reorder.
    ///
    /// The rows live in a `LazyVStack` of glass cards, not a `List`, so
    /// `.onMove` — which is what the Mac uses — is not available. Drag and drop
    /// is the system's own answer for a stack: long-press lifts the row (the
    /// context menu opens first, and moving the finger turns it into the drag),
    /// and dropping it on another row puts it in that row's place.
    ///
    /// The payload is the item's id. Anything else dropped here — text dragged
    /// in from another app — is not an id on this list, and the move ignores it.
    func reorderable(
        todo: Todo,
        enabled: Bool,
        dropTarget: Binding<String?>,
        onDrop: @escaping (_ draggedId: String) -> Void
    ) -> some View {
        modifier(ReorderableRow(todoId: todo.id, enabled: enabled, dropTarget: dropTarget, onDrop: onDrop))
    }
}

private struct ReorderableRow: ViewModifier {
    let todoId: String
    let enabled: Bool
    @Binding var dropTarget: String?
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(todoId)
                .dropDestination(for: String.self) { items, _ in
                    dropTarget = nil
                    guard let dragged = items.first, dragged != todoId else { return false }
                    onDrop(dragged)
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        dropTarget = todoId
                    } else if dropTarget == todoId {
                        dropTarget = nil
                    }
                }
                // A bar where the row will land. Without it a drop onto a stack
                // of identical cards has no visible destination.
                .overlay(alignment: .top) {
                    if dropTarget == todoId {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .offset(y: -5.5)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .motion(Motion.tap, value: dropTarget == todoId)
        } else {
            content
        }
    }
}
