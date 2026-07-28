#if os(iOS)
import ActivityKit
import Foundation

/// A Live Activity for the time you are actually standing somewhere.
///
/// ## Why this is the right shape for the feature
/// A geofence notification is a single moment: it fires as you walk through the
/// door and is gone by the time you reach the aisles. What is useful *while you
/// shop* is the list itself, without unlocking anything — which is exactly what
/// a Live Activity is.
///
/// It exists only for the duration of a visit, so the content is deliberately
/// small: what is left here, and how far through you are. Not the whole list,
/// not other lists.
///
/// ## Guarded to iOS
/// `Shared/` compiles into the watch app too, and ActivityKit does not exist
/// there. The watch shows the Activity through the Smart Stack, mirrored from
/// the phone — it never declares one itself.
struct PlaceVisitAttributes: ActivityAttributes {

    /// Everything that changes while the user is at the place.
    struct ContentState: Codable, Hashable {
        /// What is still outstanding here, most pressing first.
        ///
        /// Titles rather than ids: the Activity is rendered by a process that
        /// cannot look anything up, and `ContentState` has a hard size limit —
        /// so it carries the words themselves, already trimmed to what fits.
        var remaining: [String]
        var doneCount: Int
        var totalCount: Int

        /// How many more are waiting than the Activity has room to name.
        var overflow: Int { max(0, totalCount - doneCount - remaining.count) }

        var isComplete: Bool { totalCount > 0 && doneCount >= totalCount }

        /// Between 0 and 1, safe when `totalCount` is zero.
        var progress: Double {
            guard totalCount > 0 else { return 0 }
            return min(1, Double(doneCount) / Double(totalCount))
        }
    }

    /// The place, as the user named it. Fixed for the life of the Activity.
    var placeName: String
    /// Which list to open when the Activity is tapped.
    var listId: String

    /// The most titles worth carrying.
    ///
    /// A Live Activity is read at arm's length while doing something else. Four
    /// is what the expanded Dynamic Island can show without shrinking the text,
    /// and anything past that is better summarised as a count than listed.
    static let maxTitles = 4
}
#endif
