import Foundation

/// The `twodos://` URL contract, shared by everything that writes one and
/// everything that reads one.
///
/// Widgets are the reason this exists: a widget runs in a different process from
/// the app and cannot call into it, so the only thing it can hand over on a tap
/// is a URL. Both sides of that handover live here so a change to the format
/// cannot be made on one side alone — a widget emitting a URL the app silently
/// fails to parse looks exactly like a widget that is simply not tappable.
///
/// Deliberately tiny. A deep link carries an *intent*, not state: which list to
/// open, and nothing else. Anything richer would be a second copy of the model
/// travelling through a string.
enum DeepLink: Equatable, Sendable {
    /// Open one list.
    case list(id: String)
    /// Open the app at the lists screen, nothing selected.
    case lists

    static let scheme = "twodos"

    private enum Host {
        static let list = "list"
        static let lists = "lists"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .list(let id):
            components.host = Host.list
            components.path = "/\(id)"
        case .lists:
            components.host = Host.lists
        }
        // The components above are fully controlled, so this cannot fail — but
        // a widget must never crash, so the fallback is the bare scheme rather
        // than a force-unwrap.
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    /// Parses an incoming URL, tolerating the shapes iOS actually delivers.
    ///
    /// Both `twodos://list/abc` and `twodos:///list/abc` are accepted, because
    /// the host/path split depends on how the URL was constructed and a link
    /// that works from the widget but not from a pasteboard is a bug nobody
    /// finds until a user reports it.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }

        var parts: [String] = []
        if let host = url.host(), !host.isEmpty { parts.append(host) }
        parts.append(contentsOf: url.pathComponents.filter { $0 != "/" && !$0.isEmpty })

        switch parts.first?.lowercased() {
        case Host.list:
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            self = .list(id: parts[1])
        case Host.lists:
            self = .lists
        default:
            return nil
        }
    }
}
