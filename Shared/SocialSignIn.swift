import Foundation

/// The three identity providers the API will accept a token from.
///
/// The wire values are what `POST /api/account/social-login` expects in its
/// `provider` field, so they are spelled once here rather than as string
/// literals at each call site.
enum SocialProvider: String, CaseIterable, Identifiable, Sendable {
    case apple
    case google
    case facebook

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .facebook: "Facebook"
        }
    }
}

// MARK: - Server-supplied configuration

/// `GET /api/v1/client-config` — the runtime settings the app reads on launch.
///
/// Only the social half is modelled: the rate-limit block is documentation for
/// humans rather than something the client acts on today, and decoding fields
/// nobody reads is a maintenance cost with no payoff.
struct ClientConfig: Decodable, Sendable {
    let socialAuth: SocialAuthConfig?

    /// What a client should assume before the first fetch lands, or when the
    /// server is too old to answer: nothing is available. Social buttons appear
    /// only once the server has said they work, which means a provider whose
    /// credentials were never filled in cannot present a button that dead-ends.
    static let empty = ClientConfig(socialAuth: nil)
}

struct SocialAuthConfig: Decodable, Sendable {
    let redirectScheme: String?
    let google: GoogleConfig?
    let facebook: FacebookConfig?
    let apple: AppleConfig?

    struct GoogleConfig: Decodable, Sendable {
        let enabled: Bool
        let iosClientId: String?
        let authorizationEndpoint: String?
        let tokenEndpoint: String?
        let scopes: [String]?
    }

    struct FacebookConfig: Decodable, Sendable {
        let enabled: Bool
        let appId: String?
        let redirectUri: String?
        let authorizationEndpoint: String?
        /// The server-side flow. Meta only redirects a browser to an https URL
        /// on its allow-list, so the server takes that redirect, exchanges the
        /// code with the secret it holds, and bounces the access token back
        /// over `redirectScheme`. Preferred whenever it is present.
        let bridgeStartUrl: String?
        let scopes: [String]?
    }

    struct AppleConfig: Decodable, Sendable {
        let enabled: Bool
        let serviceId: String?
        let bridgeStartUrl: String?
        let androidAvailable: Bool?
    }

    /// Which buttons this build should actually draw, in the order they belong.
    ///
    /// Apple leads on iOS because it is the fastest route to a working account
    /// and the one the platform's users expect at the top. A provider is listed
    /// only when the server both enabled it *and* holds the credentials the
    /// flow needs — anything less produces a button that fails after the user
    /// has already committed to it.
    var availableProviders: [SocialProvider] {
        var providers: [SocialProvider] = []
        // Apple's native sheet needs no client ID from us: the entitlement on
        // the App ID is what makes it work, so the server's toggle is the only
        // thing to consult.
        if apple?.enabled == true { providers.append(.apple) }
        if let google, google.enabled, !(google.iosClientId ?? "").isEmpty { providers.append(.google) }
        if let facebook, facebook.enabled, !(facebook.appId ?? "").isEmpty { providers.append(.facebook) }
        return providers
    }
}
