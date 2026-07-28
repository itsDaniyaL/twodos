import Foundation
import ActivityKit
import OSLog

/// Runs the "you are here, this is what's left" Live Activity.
///
/// ## What starts it
/// Arriving somewhere with pinned items. That is the moment the list stops being
/// a plan and becomes something you are doing, and it is when a glanceable,
/// unlockable list earns its place on the screen.
///
/// ## What ends it
/// Leaving, finishing everything there, or four hours passing. All three matter:
/// a Live Activity that outstays the visit is clutter the user has to dismiss
/// by hand, which is a worse experience than never having shown one.
///
/// ## The background constraint
/// A geofence crossing wakes the app in the *background*, and iOS restricts
/// starting a Live Activity from there. The attempt is made anyway and its
/// failure is not treated as an error: the geofence notification has already
/// been delivered by that point, so the user is told either way — the Activity
/// is an upgrade on that path, never a replacement for it. When the user taps
/// the notification the app comes to the foreground and the Activity starts
/// then, which is the common case in practice.
@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()
    private init() {}

    private let logger = Logger(subsystem: "app.twodos", category: "liveactivity")

    /// A visit is over long before this; the cap exists so a forgotten Activity
    /// cannot sit on the Lock Screen all day if no exit crossing arrives.
    private static let maxDuration: TimeInterval = 4 * 60 * 60

    private var current: Activity<PlaceVisitAttributes>?
    /// Which place the running Activity is for, so a second arrival at the same
    /// shop updates rather than replacing.
    private var currentPlaceId: String?

    var isRunning: Bool { current != nil }

    /// Which list the running Activity is showing, so the store knows which
    /// list changing is worth pushing an update for.
    var currentListId: String? { current?.attributes.listId }

    /// Whether the user has Live Activities switched on for this app at all.
    private var isPermitted: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Starts, or updates, the Activity for a place the user has just reached.
    func begin(placeId: String, placeName: String, list: TodoList) {
        guard isPermitted else { return }

        let state = Self.state(for: list)
        // Nothing outstanding means nothing to show. Starting an Activity that
        // immediately says "all done" is noise.
        guard !state.isComplete, state.totalCount > 0 else { return }

        if currentPlaceId == placeId, current != nil {
            update(list: list)
            return
        }

        // One at a time. Two Live Activities from one app is a stack of cards
        // the user has to sort through, and a person is only ever in one place.
        Task { await end() }

        do {
            current = try Activity.request(
                attributes: PlaceVisitAttributes(placeName: placeName, listId: list.id),
                content: ActivityContent(state: state, staleDate: staleDate),
                pushType: nil
            )
            currentPlaceId = placeId
            logger.info("Live Activity started for \(placeName, privacy: .public).")
        } catch {
            // Expected when the crossing arrived in the background. The user
            // already has the notification; see the note on this type.
            logger.debug("Live Activity not started: \(error.localizedDescription)")
        }
    }

    /// Reflects a tick. Called whenever the list behind a running Activity moves.
    func update(list: TodoList) {
        guard let current, current.attributes.listId == list.id else { return }
        let state = Self.state(for: list)

        Task {
            await current.update(ActivityContent(state: state, staleDate: staleDate))
            // Finishing everything here is the natural end of the visit — there
            // is nothing left to glance at.
            if state.isComplete { await end(showing: state) }
        }
    }

    /// Ends the Activity, optionally leaving a final frame on screen briefly.
    func end(showing finalState: PlaceVisitAttributes.ContentState? = nil) async {
        guard let activity = current else { return }
        current = nil
        currentPlaceId = nil

        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        // `.after` rather than `.immediate` when finishing: a card that vanishes
        // the instant the last item is ticked denies the user the confirmation
        // they were watching for.
        await activity.end(content, dismissalPolicy: finalState == nil ? .immediate : .after(.now + 8))
    }

    /// Ends only if the running Activity belongs to this place — so leaving one
    /// shop does not dismiss the card for another.
    func endIfAt(placeId: String) async {
        guard currentPlaceId == placeId else { return }
        await end()
    }

    // MARK: - Content

    private var staleDate: Date { .now.addingTimeInterval(Self.maxDuration) }

    private static func state(for list: TodoList) -> PlaceVisitAttributes.ContentState {
        let open = list.todos.filter { !$0.done }
        return PlaceVisitAttributes.ContentState(
            remaining: open.prefix(PlaceVisitAttributes.maxTitles).map(\.title),
            doneCount: list.completedCount,
            totalCount: list.totalCount
        )
    }
}
