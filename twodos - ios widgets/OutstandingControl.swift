import AppIntents
import SwiftUI
import WidgetKit

/// A Control Centre / Lock Screen / Action Button control.
///
/// The smallest surface the app appears on, and the only one the user can put on
/// the side of their phone. So it does the one thing worth a physical button:
/// says how much is outstanding, and opens the app when pressed.
///
/// It reads the same App Group snapshot the widgets do, which means the number
/// is already correct before the control is ever drawn — a control that had to
/// fetch would show a placeholder in the one place a placeholder is useless.
struct OutstandingControl: ControlWidget {
    static let kind = "twodos.OutstandingControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: OutstandingValueProvider()) { value in
            ControlWidgetButton(action: OpenTwodosIntent()) {
                Label(value.title, systemImage: value.symbol)
            }
        }
        .displayName("Outstanding")
        .description("How much is left across your twodos lists.")
    }
}

/// What the control shows, resolved from the snapshot.
struct OutstandingValue {
    var title: String
    var symbol: String

    init(_ snapshot: WidgetSnapshot) {
        if !snapshot.isSignedIn {
            title = "Sign in"
            symbol = "person.crop.circle.badge.questionmark"
        } else if snapshot.openCount == 0 {
            title = "All clear"
            symbol = "checkmark.circle"
        } else if snapshot.overdueCount > 0 {
            // Lateness is the only state worth putting on a hardware button —
            // it is the one that changes what the user does next.
            title = "\(snapshot.overdueCount) overdue"
            symbol = "exclamationmark.triangle.fill"
        } else {
            title = "\(snapshot.openCount) open"
            symbol = "checklist"
        }
    }
}

struct OutstandingValueProvider: ControlValueProvider {
    /// What the control gallery shows before the user has added it. Deliberately
    /// not zero — a control previewing as "All clear" sells nothing.
    var previewValue: OutstandingValue { OutstandingValue(.sample) }

    func currentValue() async throws -> OutstandingValue {
        OutstandingValue(WidgetSnapshotStore.load())
    }
}

/// Opens the app. Nothing more — a control has no room to disambiguate, and
/// guessing which list someone meant from a single press would be wrong more
/// often than right.
struct OpenTwodosIntent: AppIntent {
    static var title: LocalizedStringResource = "Open twodos"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult { .result() }
}
