import CryptoKit
import Foundation

/// The fixed parts of Google's OAuth 2.0 flow for desktop apps:
/// https://developers.google.com/identity/protocols/oauth2/native-app
enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Create, read and delete events. Nothing works without it.
    static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    /// "See the list of Google calendars you're subscribed to": the narrowest
    /// of the four scopes calendarList.list accepts. Only the calendar picker
    /// needs it. https://developers.google.com/workspace/calendar/api/auth
    static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    static let scopes = [eventsScope, calendarListScope]

    /// Proof Key for Code Exchange (RFC 7636), method S256.
    struct PKCE: Equatable, Sendable {
        var verifier: String
        var challenge: String

        init(verifier: String = GoogleOAuth.randomToken()) {
            self.verifier = verifier
            challenge = GoogleOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    /// 32 random bytes, which base64url turns into 43 characters.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = formEncoded([
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", scopes.joined(separator: " ")),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            // Both are needed for Google to hand out a refresh token again
            // when the same account reconnects.
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
        return components.url!
    }

    /// application/x-www-form-urlencoded, keeping the given order.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// Percent-encodes everything outside RFC 3986's unreserved characters.
    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
