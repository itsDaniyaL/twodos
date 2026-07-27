#if DEBUG
import Foundation

/// Sample data for SwiftUI previews and for checking layout without a paired
/// phone. Debug builds only.
extension WatchStore {

    /// Set `TWODOS_WATCH_SAMPLE=1` in the scheme's environment to launch
    /// straight into a populated app.
    static var wantsSampleData: Bool {
        ProcessInfo.processInfo.environment["TWODOS_WATCH_SAMPLE"] == "1"
    }

    static func sample() -> WatchStore {
        let store = WatchStore()
        store.loadSample()
        return store
    }

    /// Deliberately awkward content: a very long item title, an overdue
    /// deadline, a finished list and an empty one. Previewing only tidy data
    /// hides the layouts that actually break on a 41mm screen.
    func loadSample() {
        applySample([
            WatchList(
                id: "l1", label: "Weekly shop", tintIndex: 5,
                items: [
                    WatchItem(id: "i1", title: "Oat milk", done: false, dueAt: nil),
                    WatchItem(id: "i2", title: "Sourdough", done: false, dueAt: nil),
                    WatchItem(id: "i3", title: "Washing-up liquid and a new sponge",
                              done: false, dueAt: .now.addingTimeInterval(-3600)),
                    WatchItem(id: "i4", title: "Coffee beans", done: true, dueAt: nil)
                ],
                dueAt: nil, isShared: true, isFavorite: false
            ),
            WatchList(
                id: "l2", label: "Flat admin", tintIndex: 2,
                items: [
                    WatchItem(id: "i5", title: "Chase the letting agent",
                              done: false, dueAt: .now.addingTimeInterval(5400))
                ],
                dueAt: .now.addingTimeInterval(-7200), isShared: true, isFavorite: false
            ),
            WatchList(
                id: "l3", label: "Reading list", tintIndex: 1,
                items: [WatchItem(id: "i6", title: "Piranesi", done: true, dueAt: nil)],
                dueAt: nil, isShared: false, isFavorite: true
            ),
            WatchList(
                id: "l4", label: "Someday", tintIndex: 0,
                items: [], dueAt: nil, isShared: false, isFavorite: false
            )
        ])
    }
}
#endif
