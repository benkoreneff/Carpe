import Foundation
import Observation
import os

enum GoogleAuthError: LocalizedError, Equatable {
    case notConfigured
    case notConnected
    case reconnectRequired
    case alreadyConnecting
    case denied(String)
    case stateMismatch
    case noRefreshToken
    case scopeNotGranted
    case badCredentials
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add the Google client ID and client secret in Settings first."
        case .notConnected:
            "Google Calendar isn't connected. Connect it in Settings."
        case .reconnectRequired:
            "Google no longer accepts the saved sign-in. Choose Reconnect Google from the Carpe menu."
        case .alreadyConnecting:
            "A Google sign-in is already waiting in the browser."
        case .denied("access_denied"):
            "The Google sign-in was cancelled."
        case .denied(let reason):
            "Google refused the sign-in (\(reason))."
        case .stateMismatch:
            "The sign-in answer didn't match this request, so it was ignored. Try again."
        case .noRefreshToken:
            "Google didn't return a refresh token. Try connecting again."
        case .scopeNotGranted:
            "Calendar access wasn't granted. Connect again and allow Carpe to manage events."
        case .badCredentials:
            "Google rejected the client ID or client secret. Check them in Settings."
        case .api(let status, let code, let message):
            "Google sign-in failed (HTTP \(status), \(code)): \(message)"
        }
    }
}

/// The connection to one Google account: the OAuth client credentials, the
/// sign-in flow, and a current access token on request.
///
/// The client ID, client secret and refresh token are kept in the secret
/// store (the Keychain). The access token lives in memory only.
@Observable
final class GoogleAccount {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    enum Status: Equatable {
        /// No client ID and secret yet.
        case notConfigured
        case disconnected
        /// The browser is open and the sign-in hasn't come back.
        case connecting
        case connected
        /// Google rejected the refresh token; the user has to sign in again.
        case needsReconnect
    }

    private(set) var status: Status = .notConfigured

    /// Called after every status change, for UI that doesn't observe.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var accessToken: (value: String, expires: Date)?
    @ObservationIgnored private var refreshing: Task<String, Error>?
    @ObservationIgnored private var connecting: Task<Void, Error>?

    private static let log = Logger(subsystem: "com.koreneff.carpe", category: "google")
    static let needsReconnectKey = "googleNeedsReconnect"

    init(
        store: SecretStore,
        defaults: UserDefaults = .standard,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        openURL: @escaping (URL) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.defaults = defaults
        self.transport = transport
        self.openURL = openURL
        self.now = now
        status = restingStatus
    }

    // MARK: - Credentials

    var clientID: String { store.get(.googleClientID) ?? "" }
    var clientSecret: String { store.get(.googleClientSecret) ?? "" }

    /// Saves the OAuth client. A refresh token belongs to the client that
    /// obtained it, so a different client ID ends the current connection.
    func saveCredentials(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientChanged = id != self.clientID

        try store.set(id.isEmpty ? nil : id, for: .googleClientID)
        try store.set(secret.isEmpty ? nil : secret, for: .googleClientSecret)
        if clientChanged {
            try store.set(nil, for: .googleRefreshToken)
            defaults.removeObject(forKey: Self.needsReconnectKey)
            accessToken = nil
        }
        if status != .connecting { update(restingStatus) }
    }

    // MARK: - Connecting

    /// Runs the sign-in: opens the browser, waits for the redirect on a
    /// loopback port, and trades the code for tokens.
    func connect() async throws {
        guard connecting == nil else { throw GoogleAuthError.alreadyConnecting }
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw GoogleAuthError.notConfigured }

        let task = Task { try await self.signIn() }
        connecting = task
        update(.connecting)
        defer {
            connecting = nil
            update(restingStatus)
        }
        // Cancelling the caller's task cancels the sign-in too.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Gives up on a sign-in that is waiting for the browser.
    func cancelConnect() {
        connecting?.cancel()
    }

    private func signIn() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }

        let pkce = GoogleOAuth.PKCE()
        let state = GoogleOAuth.randomToken()
        openURL(GoogleOAuth.authorizationURL(
            clientID: clientID, redirectURI: listener.redirectURI, challenge: pkce.challenge, state: state
        ))

        let answer = try await listener.redirect()
        // The state proves the redirect answers the request made above.
        guard answer["state"] == state else { throw GoogleAuthError.stateMismatch }
        if let error = answer["error"] { throw GoogleAuthError.denied(error) }
        guard let code = answer["code"], !code.isEmpty else { throw GoogleAuthError.denied("no code") }

        let reply = try await requestTokens([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("redirect_uri", listener.redirectURI),
            ("client_id", clientID),
            ("client_secret", clientSecret),
        ])
        guard let refreshToken = reply.refresh_token, !refreshToken.isEmpty else {
            throw GoogleAuthError.noRefreshToken
        }
        // The consent screen lets each scope be unticked. Events are required;
        // without the calendar list only the picker is unavailable.
        if let granted = reply.scope, !granted.split(separator: " ").contains(Substring(GoogleOAuth.eventsScope)) {
            throw GoogleAuthError.scopeNotGranted
        }

        try store.set(refreshToken, for: .googleRefreshToken)
        defaults.removeObject(forKey: Self.needsReconnectKey)
        remember(reply)
        Self.log.notice("Google connected")
    }

    /// Forgets the connection and asks Google to revoke the token. The local
    /// part always happens; a failed revocation is only logged.
    func disconnect() async {
        cancelConnect()
        let token = store.get(.googleRefreshToken)
        try? store.set(nil, for: .googleRefreshToken)
        defaults.removeObject(forKey: Self.needsReconnectKey)
        accessToken = nil
        refreshing?.cancel()
        refreshing = nil
        update(restingStatus)

        guard let token else { return }
        var request = URLRequest(url: GoogleOAuth.revocationEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GoogleOAuth.formEncoded([("token", token)]).utf8)
        do {
            let (_, response) = try await transport(request)
            Self.log.notice("Google token revoked: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            Self.log.error("Google token revocation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Access tokens

    /// A token that is valid for at least another minute, refreshed when
    /// needed. `forceRefresh` is for when Google has just rejected one.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, accessToken.expires.timeIntervalSince(now()) > 60 {
            return accessToken.value
        }
        // Several captures at once share one refresh.
        if let refreshing { return try await refreshing.value }

        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw GoogleAuthError.notConfigured }
        guard let refreshToken = store.get(.googleRefreshToken), !refreshToken.isEmpty else {
            throw status == .needsReconnect ? GoogleAuthError.reconnectRequired : GoogleAuthError.notConnected
        }

        let task = Task { try await self.refresh(with: refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh(with refreshToken: String) async throws -> String {
        do {
            let reply = try await requestTokens([
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", clientID),
                ("client_secret", clientSecret),
            ])
            // Google may rotate the refresh token; keep the newest.
            if let rotated = reply.refresh_token, !rotated.isEmpty, rotated != refreshToken {
                try store.set(rotated, for: .googleRefreshToken)
            }
            remember(reply)
            return reply.access_token
        } catch GoogleAuthError.api(_, "invalid_grant", _) {
            // Expired or revoked. Only a new sign-in fixes it.
            Self.log.notice("Google rejected the refresh token")
            try? store.set(nil, for: .googleRefreshToken)
            defaults.set(true, forKey: Self.needsReconnectKey)
            accessToken = nil
            update(restingStatus)
            throw GoogleAuthError.reconnectRequired
        }
    }

    // MARK: - Token endpoint

    private struct TokenReply: Decodable {
        var access_token: String
        var expires_in: Double?
        var refresh_token: String?
        var scope: String?
    }

    private struct TokenErrorReply: Decodable {
        var error: String
        var error_description: String?
    }

    private func requestTokens(_ fields: [(String, String)]) async throws -> TokenReply {
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GoogleOAuth.formEncoded(fields).utf8)

        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = try? JSONDecoder().decode(TokenErrorReply.self, from: data)
            let code = detail?.error ?? "unknown"
            if code == "invalid_client" || code == "unauthorized_client" { throw GoogleAuthError.badCredentials }
            throw GoogleAuthError.api(
                status: status, code: code,
                message: detail?.error_description ?? String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        do {
            return try JSONDecoder().decode(TokenReply.self, from: data)
        } catch {
            throw GoogleAuthError.api(status: status, code: "unreadable", message: "The token answer couldn't be read.")
        }
    }

    private func remember(_ reply: TokenReply) {
        accessToken = (reply.access_token, now().addingTimeInterval(reply.expires_in ?? 3600))
    }

    // MARK: - Status

    /// The status when no sign-in is in progress, from what is stored.
    private var restingStatus: Status {
        if clientID.isEmpty || clientSecret.isEmpty { return .notConfigured }
        if let token = store.get(.googleRefreshToken), !token.isEmpty { return .connected }
        return defaults.bool(forKey: Self.needsReconnectKey) ? .needsReconnect : .disconnected
    }

    private func update(_ new: Status) {
        guard new != status else { return }
        status = new
        onChange?()
    }
}
