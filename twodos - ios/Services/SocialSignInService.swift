import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Obtains an identity token from Google or Facebook, using the system's
/// authentication browser rather than a vendor SDK.
///
/// ## Why `ASWebAuthenticationSession` and not the Google / Facebook SDKs
///
/// Both vendors ship an SDK, and both SDKs would add a dependency that runs on
/// launch, carries its own analytics, and has to be kept current for the life of
/// the app. The flows they implement are ordinary OAuth 2.0, and iOS already
/// ships the piece that actually matters: a browser that shares the system
/// cookie jar, runs out of process, and shows the real URL bar so the user can
/// see who is asking for their password. Everything below is the standard
/// authorisation-code-with-PKCE flow against that browser.
///
/// Apple is not here. Its native sheet returns an identity token directly with
/// no browser involved, so `WelcomeView` drives it through `SignInWithAppleButton`
/// and hands the token to the same `socialLogin` endpoint.
///
/// ## What comes back
///
/// Whatever the provider issues, unread. Google returns an `id_token`, Facebook
/// an access token; the server verifies each against the provider before
/// trusting it, so nothing here needs to — and nothing here *should*, since a
/// client-side check of a token the client obtained proves nothing.
@MainActor
final class SocialSignInService: NSObject {

    enum Failure: LocalizedError {
        /// The user backed out. Not worth a message — see `isCancellation`.
        case cancelled
        case notConfigured(SocialProvider)
        case providerRejected(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .cancelled:
                nil
            case .notConfigured(let provider):
                "\(provider.displayName) sign-in isn't available right now. Try another way in."
            case .providerRejected(let reason):
                reason
            case .malformedResponse:
                "That sign-in didn't complete. Please try again."
            }
        }

        /// A cancellation is a decision, not a failure, and must never surface
        /// as an error alert — the user knows what they just did.
        var isCancellation: Bool { if case .cancelled = self { true } else { false } }
    }

    /// Runs the provider's flow and returns the token plus, when the provider
    /// volunteers one, a display name to seed the new account with.
    func token(for provider: SocialProvider, config: SocialAuthConfig) async throws -> (token: String, name: String?) {
        switch provider {
        case .google:
            return (try await googleIDToken(config: config), nil)
        case .facebook:
            return (try await facebookAccessToken(config: config), nil)
        case .apple:
            // Apple's native sheet is presented by the view, not by this
            // service; routing it through a browser would be a worse flow and
            // would break the Face ID path users expect.
            throw Failure.notConfigured(.apple)
        }
    }

    // MARK: - Apple

    /// Presents Apple's native sheet and resolves with the identity token.
    ///
    /// The sign-in screens use SwiftUI's `SignInWithAppleButton`, which owns
    /// its own presentation. Settings needs the same sheet from an ordinary
    /// "Connect" button in a row, so this drives `ASAuthorizationController`
    /// directly. Same request, same credential, same server endpoint.
    func appleIdentityToken() async throws -> (token: String, name: String?) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let relay = AppleAuthorizationRelay()
        controller.delegate = relay
        controller.presentationContextProvider = self
        // The relay must outlive the sheet; the continuation holds it.
        return try await withCheckedThrowingContinuation { continuation in
            relay.continuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - Google

    /// Authorisation code + PKCE, exchanged for an `id_token`.
    ///
    /// The exchange happens on the device against Google's token endpoint. That
    /// is safe without a client secret because this is a *public* client: the
    /// iOS client type issues no secret at all, and PKCE is what stands in for
    /// one — the verifier never leaves the process, so an intercepted code is
    /// useless to whoever intercepted it.
    private func googleIDToken(config: SocialAuthConfig) async throws -> String {
        guard let google = config.google,
              let clientId = google.iosClientId, !clientId.isEmpty,
              let authEndpoint = google.authorizationEndpoint,
              let tokenEndpoint = google.tokenEndpoint
        else { throw Failure.notConfigured(.google) }

        // Google's installed-app clients redirect to the client ID reversed into
        // a scheme. Deriving it here rather than shipping it as config keeps the
        // two halves from ever disagreeing.
        let scheme = reversedClientIdScheme(clientId)
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.randomURLSafeString()
        let challenge = Self.s256Challenge(for: verifier)
        let state = Self.randomURLSafeString()

        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: (google.scopes ?? ["openid", "email", "profile"]).joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let authURL = components?.url else { throw Failure.notConfigured(.google) }

        let callback = try await present(authURL, callbackScheme: scheme)

        let returned = Self.queryItems(from: callback)

        // The error is read first. A provider reporting a failure may
        // legitimately drop the state, and there is no token in that response to
        // steal — checking state first would turn every user cancellation into
        // "that sign-in didn't complete".
        if let error = returned["error"] {
            throw error == "access_denied" ? Failure.cancelled : Failure.providerRejected(googleMessage(for: error))
        }
        // A state that is missing or does not match means the response did not
        // come from the request this process started, and nothing in it is
        // trustworthy.
        guard returned["state"] == state else { throw Failure.malformedResponse }
        guard let code = returned["code"] else { throw Failure.malformedResponse }

        return try await exchangeGoogleCode(
            code, verifier: verifier, clientId: clientId,
            redirectURI: redirectURI, tokenEndpoint: tokenEndpoint
        )
    }

    private func exchangeGoogleCode(
        _ code: String,
        verifier: String,
        clientId: String,
        redirectURI: String,
        tokenEndpoint: String
    ) async throws -> String {
        guard let url = URL(string: tokenEndpoint) else { throw Failure.notConfigured(.google) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let idToken: String?
            let error: String?
            let errorDescription: String?

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case error
                case errorDescription = "error_description"
            }
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let error = decoded.error {
            throw Failure.providerRejected(decoded.errorDescription ?? googleMessage(for: error))
        }
        guard let idToken = decoded.idToken, !idToken.isEmpty else { throw Failure.malformedResponse }
        return idToken
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
    private func reversedClientIdScheme(_ clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    private func googleMessage(for code: String) -> String {
        switch code {
        case "invalid_client", "unauthorized_client":
            "Google sign-in isn't set up correctly for this app. Try another way in."
        default:
            "Google couldn't complete the sign-in. Please try again."
        }
    }

    // MARK: - Facebook

    /// Facebook hands back an access token in the callback fragment.
    ///
    /// There is no code exchange: the server needs the *access* token, which it
    /// validates with `debug_token` using the app secret it holds and we
    /// deliberately do not. That is why this flow can be shorter than Google's
    /// without being looser — verification simply happens on the other side.
    private func facebookAccessToken(config: SocialAuthConfig) async throws -> String {
        guard let facebook = config.facebook,
              let appId = facebook.appId, !appId.isEmpty,
              let redirectUri = facebook.redirectUri, !redirectUri.isEmpty,
              let authEndpoint = facebook.authorizationEndpoint,
              let redirectScheme = URL(string: redirectUri)?.scheme
        else { throw Failure.notConfigured(.facebook) }

        let state = Self.randomURLSafeString()

        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            .init(name: "client_id", value: appId),
            .init(name: "redirect_uri", value: redirectUri),
            .init(name: "response_type", value: "token"),
            .init(name: "scope", value: (facebook.scopes ?? ["email", "public_profile"]).joined(separator: ",")),
            .init(name: "state", value: state),
        ]
        guard let authURL = components?.url else { throw Failure.notConfigured(.facebook) }

        let callback = try await present(authURL, callbackScheme: redirectScheme)

        // The token arrives in the fragment, and errors in the query, so both
        // halves of the callback have to be read.
        let returned = Self.queryItems(from: callback).merging(
            Self.fragmentItems(from: callback), uniquingKeysWith: { _, fragment in fragment }
        )

        if let error = returned["error"] {
            // Facebook's own word for "the user tapped Cancel".
            let denied = error == "access_denied" || returned["error_reason"] == "user_denied"
            throw denied ? Failure.cancelled : Failure.providerRejected(
                returned["error_description"] ?? "Facebook couldn't complete the sign-in. Please try again."
            )
        }
        // Strict, and checked before the token is read. Facebook's implicit flow
        // hands back a usable access token outright, with no code exchange and
        // so no PKCE behind it — accepting a response whose state is absent
        // would sign the user into whichever account the sender chose.
        guard returned["state"] == state else { throw Failure.malformedResponse }
        guard let token = returned["access_token"], !token.isEmpty else { throw Failure.malformedResponse }
        return token
    }

    // MARK: - Browser session

    /// Presents the system authentication browser and resolves with the
    /// callback URL, translating the user closing it into `.cancelled`.
    private func present(_ url: URL, callbackScheme: String) async throws -> URL {
        // The session must outlive this scope or it is torn down before the
        // user can finish, so it is held for the duration of the continuation.
        var session: ASWebAuthenticationSession?

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let created = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let error {
                        let isCancel = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        continuation.resume(throwing: isCancel ? Failure.cancelled : Failure.malformedResponse)
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: Failure.malformedResponse)
                        return
                    }
                    continuation.resume(returning: callbackURL)
                }
                created.presentationContextProvider = self
                // A shared cookie jar is the difference between "tap, done" for
                // someone already signed in to Google in Safari and retyping a
                // password on a phone keyboard.
                created.prefersEphemeralWebBrowserSession = false
                session = created

                if !created.start() {
                    continuation.resume(throwing: Failure.malformedResponse)
                }
            }
        } onCancel: {
            Task { @MainActor in session?.cancel() }
        }
    }

    // MARK: - PKCE and parsing

    /// 32 bytes of randomness, base64url-encoded — a valid PKCE verifier and a
    /// perfectly good `state` value.
    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here would mean the system RNG is unavailable; falling back
        // to anything weaker would silently downgrade the flow's security, so
        // the arc4random path is used instead, which cannot fail.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    private static func s256Challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func queryItems(from url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    private static func fragmentItems(from url: URL) -> [String: String] {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              !fragment.isEmpty
        else { return [:] }
        // The fragment is form-encoded, so it parses as a query string once it
        // is handed to URLComponents as one.
        var components = URLComponents()
        components.percentEncodedQuery = fragment
        let items = components.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Apple delegate

/// Turns the delegate callbacks of one Apple authorisation into a result.
///
/// A separate object rather than the service itself, because the service may
/// have a browser session in flight at the same time and the two must not
/// share a continuation.
@MainActor
private final class AppleAuthorizationRelay: NSObject, ASAuthorizationControllerDelegate {
    var continuation: CheckedContinuation<(token: String, name: String?), Error>?

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            continuation?.resume(throwing: SocialSignInService.Failure.malformedResponse)
            continuation = nil
            return
        }
        // Apple supplies the name exactly once, on the first authorisation.
        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
        continuation?.resume(returning: (token, name.isEmpty ? nil : name))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let isCancel = (error as? ASAuthorizationError)?.code == .canceled
        continuation?.resume(throwing: isCancel
            ? SocialSignInService.Failure.cancelled
            : SocialSignInService.Failure.providerRejected("Apple sign-in didn't complete. Please try again."))
        continuation = nil
    }
}

// MARK: - Presentation anchor

extension SocialSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        keyWindowAnchor()
    }
}

extension SocialSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        keyWindowAnchor()
    }

    /// The key window of the active foreground scene. When there isn't one
    /// the flow could not have been started by a tap, so an empty anchor is
    /// the honest answer rather than a crash. Shared by the browser session
    /// and Apple's sheet, which want the same window.
    private func keyWindowAnchor() -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
