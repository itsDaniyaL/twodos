#if DEBUG
import Foundation

/// Sample data for SwiftUI previews and for eyeballing screens without a live
/// account. Debug builds only — none of this ships.
extension AppStore {

    /// A store pre-populated with a realistic spread of lists: personal and
    /// shared, overdue and upcoming, empty and finished, with and without a
    /// pinned place. Previewing against only happy-path data hides the layouts
    /// that actually break.
    static func sample() -> AppStore {
        let store = AppStore()
        store.loadSampleData()
        return store
    }

    func loadSampleData() {
        let me = "user-me"
        let them = "user-sam"

        let sampleUser = CurrentUser(id: me, name: "Alex Rivera",
                                     email: "alex@example.com", emailVerified: true)
        let samplePartners = [
            Partner(id: them, name: "Sam Okafor", email: "sam@example.com",
                    emailVerified: true, status: APIConstants.InviteStatus.accepted),
            Partner(id: "user-jo", name: "Jo Bennett", email: "jo@example.com",
                    emailVerified: false, status: APIConstants.InviteStatus.pending)
        ]
        let samplePresence = [them: true]

        let sampleLists = [
            Self.makeList(
                id: "list-1", label: "Weekly shop", createdBy: me, partnerId: them,
                colorHex: "#4E8C6F", updatedAt: .now.addingTimeInterval(-600),
                location: (name: "Sainsbury's, Hackney", lat: 51.5461, lng: -0.0553, radius: 200),
                items: [("Oat milk", false, nil), ("Sourdough", false, nil), ("Coffee beans", true, nil),
                        ("Washing-up liquid", false, nil), ("Tomatoes", true, nil)]
            ),
            Self.makeList(
                id: "list-2", label: "Flat admin", createdBy: me, partnerId: them,
                colorHex: "#875353", priority: APIConstants.Priority.urgent,
                doBefore: .now.addingTimeInterval(-7200),
                updatedAt: .now.addingTimeInterval(-3600),
                items: [("Chase the letting agent", false, nil), ("Renew contents insurance", false, nil)]
            ),
            Self.makeList(
                id: "list-3", label: "Reading list", createdBy: me, partnerId: nil,
                colorHex: "#504E8C", favorite: true,
                updatedAt: .now.addingTimeInterval(-86_400),
                items: [("Piranesi", true, nil), ("The Dispossessed", true, nil), ("Klara and the Sun", true, nil)]
            ),
            Self.makeList(
                id: "list-4", label: "Trip to Lisbon", createdBy: me, partnerId: them,
                colorHex: "#9D8C57", doBefore: .now.addingTimeInterval(86_400 * 3),
                updatedAt: .now.addingTimeInterval(-172_800),
                items: [("Book the airport transfer", false, Date.now.addingTimeInterval(3600 * 5)),
                        ("Sort out the eSIM", false, nil),
                        ("Print the tickets", true, nil)]
            ),
            Self.makeList(
                id: "list-5", label: "Someday", createdBy: me, partnerId: nil,
                colorHex: "#7A7A7A", updatedAt: .now.addingTimeInterval(-604_800), items: []
            ),
            Self.makeList(
                id: "list-6", label: "Old receipts", createdBy: me, partnerId: nil,
                colorHex: "#7A7A7A", archived: true,
                updatedAt: .now.addingTimeInterval(-2_592_000),
                items: [("Scan the boiler service", true, nil)]
            ),
            // An invitation waiting to be answered.
            Self.makeList(
                id: "list-7", label: "Dinner party", createdBy: them, partnerId: me,
                colorHex: "#7A588A", inviteStatus: APIConstants.InviteStatus.pending,
                inviteAccepted: false,
                inviteExpiresAt: .now.addingTimeInterval(86_400 * 3),
                updatedAt: .now.addingTimeInterval(-1800),
                items: []
            )
        ]

        let sampleAlarms = [
            Self.makeAlarm(id: "alarm-1", label: "Put the bins out",
                           at: .now.addingTimeInterval(3600 * 8), repeatRule: .weekly),
            Self.makeAlarm(id: "alarm-2", label: "Call the dentist",
                           at: .now.addingTimeInterval(86_400), repeatRule: .never, listId: "list-2"),
            Self.makeAlarm(id: "alarm-3", label: "Water the plants",
                           at: .now.addingTimeInterval(-7200), repeatRule: .daily)
        ]

        let sampleNotifications = [
            Self.makeNotification(id: "n-1", type: APIConstants.NotificationType.inviteReceived,
                                  title: "Sam shared a list with you",
                                  body: "Dinner party", listId: "list-7",
                                  read: false, ago: 1_800),
            Self.makeNotification(id: "n-2", type: APIConstants.NotificationType.geofence,
                                  title: "You're at Sainsbury's, Hackney",
                                  body: "Weekly shop — 3 items left", listId: "list-1",
                                  read: false, ago: 5_400),
            Self.makeNotification(id: "n-3", type: APIConstants.NotificationType.inviteAccepted,
                                  title: "Sam accepted your invitation",
                                  body: "Flat admin", listId: "list-2",
                                  read: true, ago: 90_000),
            Self.makeNotification(id: "n-4", type: APIConstants.NotificationType.alarmFired,
                                  title: "Water the plants", body: nil, listId: nil,
                                  read: true, ago: 176_000)
        ]

        applySample(
            user: sampleUser,
            lists: sampleLists,
            partners: samplePartners,
            alarms: sampleAlarms,
            notifications: sampleNotifications,
            presence: samplePresence
        )
    }

    // MARK: - Builders
    //
    // The models decode from JSON and have no memberwise initialisers, so the
    // sample data is built by round-tripping dictionaries through the decoder —
    // which has the happy side effect of exercising the real decoding path.

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            return ISO8601DateFormatter.twodosFractional.date(from: raw)
                ?? ISO8601DateFormatter.twodosPlain.date(from: raw)
                ?? .now
        }
        return d
    }()

    private static func decode<T: Decodable>(_ dictionary: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: dictionary)
        return try! decoder.decode(T.self, from: data)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.twodosOut.string(from: date)
    }

    private static func makeList(
        id: String,
        label: String,
        createdBy: String,
        partnerId: String?,
        colorHex: String,
        favorite: Bool = false,
        archived: Bool = false,
        priority: String? = nil,
        doBefore: Date? = nil,
        inviteStatus: String? = APIConstants.InviteStatus.accepted,
        inviteAccepted: Bool = true,
        inviteExpiresAt: Date? = nil,
        updatedAt: Date = .now,
        location: (name: String, lat: Double, lng: Double, radius: Double)? = nil,
        items: [(String, Bool, Date?)]
    ) -> TodoList {
        var payload: [String: Any] = [
            "id": id,
            "label": label,
            "favorite": favorite,
            "archived": archived,
            "color": colorHex,
            "createdBy": createdBy,
            "inviteAccepted": inviteAccepted,
            "order": 0,
            "createdAt": iso(.now.addingTimeInterval(-2_592_000)),
            "updatedAt": iso(updatedAt),
            "items": items.enumerated().map { index, item -> [String: Any] in
                var todo: [String: Any] = [
                    "id": "\(id)-todo-\(index)",
                    "listId": id,
                    "title": item.0,
                    "done": item.1,
                    "order": index,
                    "updatedAt": iso(updatedAt)
                ]
                if let due = item.2 { todo["doBefore"] = iso(due) }
                return todo
            }
        ]
        if let partnerId { payload["partnerId"] = partnerId }
        if let priority { payload["priority"] = priority }
        if let doBefore { payload["doBefore"] = iso(doBefore) }
        if let inviteStatus { payload["inviteStatus"] = inviteStatus }
        if let inviteExpiresAt { payload["inviteExpiresAt"] = iso(inviteExpiresAt) }
        if let location {
            payload["locationName"] = location.name
            payload["locationLat"] = location.lat
            payload["locationLng"] = location.lng
            payload["locationRadius"] = location.radius
            payload["locationTrigger"] = GeofenceTrigger.arrive.rawValue
        }
        return decode(payload)
    }

    private static func makeAlarm(
        id: String, label: String, at date: Date,
        repeatRule: AlarmRepeat, listId: String? = nil
    ) -> Alarm {
        var payload: [String: Any] = [
            "id": id,
            "label": label,
            "alarmAt": iso(date),
            "repeat": repeatRule.apiValue,
            "fired": date < .now
        ]
        if let listId { payload["listId"] = listId }
        return decode(payload)
    }

    private static func makeNotification(
        id: String, type: String, title: String, body: String?,
        listId: String?, read: Bool, ago: TimeInterval
    ) -> AppNotification {
        var payload: [String: Any] = [
            "id": id,
            "notificationType": type,
            "title": title,
            "read": read,
            "createdAt": iso(.now.addingTimeInterval(-ago))
        ]
        if let body { payload["body"] = body }
        if let listId { payload["data"] = "{\"listId\":\"\(listId)\"}" }
        return decode(payload)
    }
}
#endif
