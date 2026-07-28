import Foundation
import WidgetKit

/// Writes the snapshot and asks WidgetKit to redraw — the app's half of the
/// contract the widgets depend on.
///
/// ## Why the change check matters
/// WidgetKit budgets reloads. An app that calls `reloadAllTimelines` on every
/// list refresh spends its allowance on redraws that change nothing, and the
/// user pays for it later in the day when a reload that *would* have mattered is
/// refused. So the snapshot is compared before it is written, and the reload
/// only happens when something a widget could actually show has changed.
///
/// This is also why callers may invoke `publish` as liberally as they like — it
/// is the same bargain ``PhoneConnectivityService`` makes for the watch.
enum WidgetPublisher {

    /// Publishes the given snapshot. Cheap and idempotent when nothing changed.
    ///
    /// Sign-out needs no special case: the snapshot built while signed out is
    /// `.empty`, which differs from whatever was there before, so it is written
    /// and reloaded like any other change. A widget cannot go on showing the
    /// previous user's tasks.
    static func publish(_ snapshot: WidgetSnapshot) {
        guard WidgetSnapshotStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
