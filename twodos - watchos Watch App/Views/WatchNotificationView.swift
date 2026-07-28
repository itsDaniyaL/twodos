import SwiftUI
import UserNotifications
import WatchKit

/// The long-look interface for a twodos notification on the wrist.
///
/// ## Why bother replacing the default
/// iOS notifications mirror to the watch automatically, and the system look is
/// perfectly legible — but it is the same grey card for a deadline, an alarm, a
/// partner's edit and an arrival at the shop. On a screen this size the *kind*
/// of interruption is most of the information: a geofence arrival is something
/// you act on now, a partner's edit is something you merely note.
///
/// So this draws the same four categories with the app's own colours, leading
/// with a glyph that says which of the four it is before a word is read.
///
/// ## What this file is not
/// The action buttons underneath are not declared here. They come from the
/// `UNNotificationCategory` the phone registered, and watchOS renders them
/// itself — which is why "Mark done" already worked from the wrist before this
/// existed. This is the look, not the actions.
struct WatchNotificationView: View {
    var title: String
    var message: String
    var kind: NotificationKind

    /// Takes plain values rather than a `UNNotification`, so the view can be
    /// previewed, tested, and rendered before a notification has arrived without
    /// anyone having to invent an empty one.
    init(title: String, message: String, categoryIdentifier: String) {
        self.title = title
        self.message = message
        self.kind = NotificationKind(identifier: categoryIdentifier)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: kind.icon)
                        .font(.caption.weight(.semibold))
                    Text(kind.watchLabel)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(kind.tint)

                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}

extension NotificationKind {
    var icon: String {
        switch self {
        case .deadline: "calendar.badge.clock"
        case .alarm: "alarm.fill"
        case .geofence: "mappin.and.ellipse"
        case .social: "person.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .deadline: Brand.info
        case .alarm: Brand.danger
        case .geofence: Brand.meadow
        case .social: Brand.apricot
        }
    }

    /// One word for what this is, above the title, so the category registers
    /// before the eye reaches the actual text.
    var watchLabel: String {
        switch self {
        case .deadline: "Deadline"
        case .alarm: "Alarm"
        case .geofence: "Place"
        case .social: "Shared list"
        }
    }
}

/// Hosts the view above for every twodos category.
///
/// One controller for all four rather than four: the layout is identical and
/// only the colour and glyph differ, so splitting them would be four files that
/// have to be kept looking the same.
final class WatchNotificationController: WKUserNotificationHostingController<WatchNotificationView> {
    private var content: UNNotificationContent?

    override func didReceive(_ notification: UNNotification) {
        content = notification.request.content
    }

    override var body: WatchNotificationView {
        WatchNotificationView(
            title: content?.title ?? "",
            message: content?.body ?? "",
            categoryIdentifier: content?.categoryIdentifier ?? ""
        )
    }
}
