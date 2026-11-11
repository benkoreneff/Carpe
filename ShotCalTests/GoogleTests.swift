import CryptoKit
import Foundation
import Testing

/// Replays canned HTTP responses and records the requests.
final class FakeHTTP {
    var responses: [(status: Int, body: String)]
    var requests: [URLRequest] = []
    /// Give other tasks a turn before answering, to test overlapping calls.
    var yieldsFirst = false

    init(_ responses: [(status: Int, body: String)] = []) { self.responses = responses }

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if yieldsFirst { await Task.yield() }
        let next = responses.isEmpty ? (status: 500, body: "no canned response left") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (Data(next.body.utf8), response)
    }

    /// The fields of a form-encoded request body.
    func form(_ index: Int) -> [String: String] {
        guard requests.indices.contains(index), let body = requests[index].httpBody else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func json(_ index: Int) -> [String: Any] {
        guard requests.indices.contains(index), let body = requests[index].httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

func query(of url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

// MARK: - OAuth building blocks

@Suite struct GoogleOAuthTests {
    @Test func pkceChallengeMatchesTheRFC7636Example() {
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomTokensAreLongURLSafeAndDifferent() {
        let first = GoogleOAuth.randomToken()
        let second = GoogleOAuth.randomToken()
        #expect(first.count == 43)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(first != second)
    }

    @Test func authorizationURLAsksForEventsAndTheCalendarListWithPKCE() {
        let url = GoogleOAuth.authorizationURL(
            clientID: "abc.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:51234",
            challenge: "the-challenge", state: "the-state"
        )
        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))

        let fields = query(of: url)
        // Events, plus the narrowest scope that can list calendars. Nothing broader.
        #expect(fields["scope"] == "https://www.googleapis.com/auth/calendar.events "
            + "https://www.googleapis.com/auth/calendar.calendarlist.readonly")
        #expect(fields["client_id"] == "abc.apps.googleusercontent.com")
        #expect(fields["redirect_uri"] == "http://127.0.0.1:51234")
        #expect(fields["response_type"] == "code")
        #expect(fields["code_challenge"] == "the-challenge")
        #expect(fields["code_challenge_method"] == "S256")
        #expect(fields["state"] == "the-state")
        #expect(fields["access_type"] == "offline")
        // The secret never goes through the browser.
        #expect(fields["client_secret"] == nil)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = GoogleOAuth.formEncoded([("a", "1/2+3 4&5=6"), ("redirect_uri", "http://127.0.0.1:80")])
        #expect(encoded == "a=1%2F2%2B3%204%265%3D6&redirect_uri=http%3A%2F%2F127.0.0.1%3A80")
    }
}

// MARK: - Loopback listener

@Suite struct LoopbackRedirectListenerTests {
    static let session = URLSession(configuration: .ephemeral)

    @Test func parsesOnlyGETRequestsForTheRootPath() {
        typealias Listener = LoopbackRedirectListener
        #expect(Listener.parameters(fromRequestLine: "GET /?code=4%2FabC&state=xyz HTTP/1.1") == ["code": "4/abC", "state": "xyz"])
        #expect(Listener.parameters(fromRequestLine: "GET / HTTP/1.1") == [:])
        #expect(Listener.parameters(fromRequestLine: "GET /favicon.ico HTTP/1.1") == nil)
        #expect(Listener.parameters(fromRequestLine: "POST /?code=1 HTTP/1.1") == nil)
        #expect(Listener.parameters(fromRequestLine: "garbage") == nil)
    }

    @Test func receivesARealRedirectAndShowsAPage() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)
        #expect(listener.redirectURI == "http://127.0.0.1:\(listener.port)")

        async let answer = listener.redirect(timeout: 10)
        let url = URL(string: "\(listener.redirectURI)/?state=s1&code=4%2Fcode")!
        let (data, response) = try await Self.session.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("go back to ShotCal"))
        #expect(try await answer == ["state": "s1", "code": "4/code"])
    }

    @Test func otherRequestsDoNotEndTheWait() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }

        async let answer = listener.redirect(timeout: 10)
        let (_, favicon) = try await Self.session.data(from: URL(string: "\(listener.redirectURI)/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        let (_, bare) = try await Self.session.data(from: URL(string: "\(listener.redirectURI)/")!)
        #expect((bare as? HTTPURLResponse)?.statusCode == 400)

        _ = try await Self.session.data(from: URL(string: "\(listener.redirectURI)/?error=access_denied&state=s")!)
        #expect(try await answer == ["error": "access_denied", "state": "s"])
    }

    @Test func givesUpAfterTheTimeout() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        await #expect(throws: LoopbackRedirectError.timedOut) {
            try await listener.redirect(timeout: 0.1)
        }
    }

    @Test func cancellingTheTaskEndsTheWait() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let waiting = Task { try await listener.redirect(timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

// MARK: - Account

@Suite struct GoogleAccountTests {
    static let tokenReply = """
    {"access_token":"access-1","expires_in":3599,"refresh_token":"refresh-1",
     "scope":"https://www.googleapis.com/auth/calendar.events","token_type":"Bearer"}
    """
    static let refreshedReply = """
    {"access_token":"access-2","expires_in":3599,
     "scope":"https://www.googleapis.com/auth/calendar.events","token_type":"Bearer"}
    """

    /// One test's world: secrets, defaults, HTTP and a controllable clock.
    final class World {
        let store: InMemorySecretStore
        let defaults: UserDefaults
        let http = FakeHTTP()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var opened: [URL] = []
        /// What the "browser" does with the sign-in page's URL.
        var browser: (URL) -> Void = { _ in }
        private let suite = "ShotCalTests-\(UUID().uuidString)"

        init(_ secrets: [Secret: String] = [.googleClientID: "client-id", .googleClientSecret: "client-secret"]) {
            store = InMemorySecretStore(secrets)
            defaults = UserDefaults(suiteName: suite)!
        }

        isolated deinit { defaults.removePersistentDomain(forName: suite) }

        func account() -> GoogleAccount {
            GoogleAccount(
                store: store, defaults: defaults, transport: http.transport,
                openURL: { [unowned self] url in
                    self.opened.append(url)
                    self.browser(url)
                },
                now: { [unowned self] in self.now }
            )
        }

        /// A browser where the user approves: follows the redirect with a code.
        func approve(code: String = "auth-code", state: String? = nil) {
            browser = { url in
                let fields = query(of: url)
                let redirect = "\(fields["redirect_uri"]!)/?code=\(code)&state=\(state ?? fields["state"]!)"
                Task { _ = try? await LoopbackRedirectListenerTests.session.data(from: URL(string: redirect)!) }
            }
        }
    }

    // Status

    @Test func statusFollowsWhatIsStored() {
        #expect(World([:]).account().status == .notConfigured)
        #expect(World([.googleClientID: "id"]).account().status == .notConfigured)
        #expect(World().account().status == .disconnected)
        #expect(World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "r"]).account().status == .connected)
    }

    // Connecting

    @Test func connectRunsTheWholeSignIn() async throws {
        let world = World()
        world.approve()
        world.http.responses = [(200, Self.tokenReply)]
        let account = world.account()
        var statuses: [GoogleAccount.Status] = []
        account.onChange = { statuses.append(account.status) }

        try await account.connect()

        #expect(statuses == [.connecting, .connected])
        #expect(world.store.get(.googleRefreshToken) == "refresh-1")

        // What went to the browser and what went to the token endpoint agree.
        let authorization = query(of: try #require(world.opened.first))
        let exchange = world.http.form(0)
        #expect(world.http.requests[0].url == GoogleOAuth.tokenEndpoint)
        #expect(world.http.requests[0].httpMethod == "POST")
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["code"] == "auth-code")
        #expect(exchange["client_id"] == "client-id")
        #expect(exchange["client_secret"] == "client-secret")
        #expect(exchange["redirect_uri"] == authorization["redirect_uri"])
        #expect(try #require(authorization["redirect_uri"]).hasPrefix("http://127.0.0.1:"))
        let verifier = try #require(exchange["code_verifier"])
        #expect(GoogleOAuth.PKCE(verifier: verifier).challenge == authorization["code_challenge"])

        // The access token from the exchange is used without another request.
        #expect(try await account.accessToken() == "access-1")
        #expect(world.http.requests.count == 1)
    }

    @Test func aRedirectWithTheWrongStateIsRejected() async throws {
        let world = World()
        world.approve(state: "forged")
        let account = world.account()

        await #expect(throws: GoogleAuthError.stateMismatch) { try await account.connect() }
        #expect(world.http.requests.isEmpty)
        #expect(world.store.get(.googleRefreshToken) == nil)
        #expect(account.status == .disconnected)
    }

    @Test func aCancelledConsentScreenIsReported() async throws {
        let world = World()
        world.browser = { url in
            let fields = query(of: url)
            let redirect = "\(fields["redirect_uri"]!)/?error=access_denied&state=\(fields["state"]!)"
            Task { _ = try? await LoopbackRedirectListenerTests.session.data(from: URL(string: redirect)!) }
        }
        let account = world.account()

        await #expect(throws: GoogleAuthError.denied("access_denied")) { try await account.connect() }
        #expect(account.status == .disconnected)
    }

    @Test func connectNeedsCredentials() async {
        let account = World([:]).account()
        await #expect(throws: GoogleAuthError.notConfigured) { try await account.connect() }
    }

    @Test func aReplyWithoutARefreshTokenIsNotAConnection() async throws {
        let world = World()
        world.approve()
        world.http.responses = [(200, Self.refreshedReply)]
        let account = world.account()

        await #expect(throws: GoogleAuthError.noRefreshToken) { try await account.connect() }
        #expect(account.status == .disconnected)
    }

    @Test func aSignInWaitingInTheBrowserCanBeCancelled() async throws {
        let world = World()
        let account = world.account()
        let connecting = Task { try await account.connect() }
        while world.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(account.status == .connecting)

        account.cancelConnect()

        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(account.status == .disconnected)
    }

    // Access tokens

    @Test func accessTokenIsRefreshedCachedAndRefreshedAgainOnExpiry() async throws {
        let world = World([.googleClientID: "client-id", .googleClientSecret: "client-secret", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(200, Self.refreshedReply), (200, Self.refreshedReply.replacingOccurrences(of: "access-2", with: "access-3"))]
        let account = world.account()

        #expect(try await account.accessToken() == "access-2")
        let refresh = world.http.form(0)
        #expect(refresh["grant_type"] == "refresh_token")
        #expect(refresh["refresh_token"] == "refresh-1")
        #expect(refresh["client_id"] == "client-id")
        #expect(refresh["client_secret"] == "client-secret")

        world.now += 3000
        #expect(try await account.accessToken() == "access-2")
        #expect(world.http.requests.count == 1)

        // Less than a minute left counts as expired.
        world.now += 560
        #expect(try await account.accessToken() == "access-3")
        #expect(world.http.requests.count == 2)
        #expect(world.store.get(.googleRefreshToken) == "refresh-1")
    }

    @Test func forceRefreshSkipsTheCache() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(200, Self.refreshedReply), (200, Self.refreshedReply.replacingOccurrences(of: "access-2", with: "access-3"))]
        let account = world.account()

        #expect(try await account.accessToken() == "access-2")
        #expect(try await account.accessToken(forceRefresh: true) == "access-3")
    }

    @Test func overlappingCallsShareOneRefresh() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(200, Self.refreshedReply)]
        world.http.yieldsFirst = true
        let account = world.account()

        async let first = account.accessToken()
        async let second = account.accessToken()
        #expect(try await [first, second] == ["access-2", "access-2"])
        #expect(world.http.requests.count == 1)
    }

    @Test func aRotatedRefreshTokenIsKept() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "old"])
        world.http.responses = [(200, Self.tokenReply)]
        _ = try await world.account().accessToken()
        #expect(world.store.get(.googleRefreshToken) == "refresh-1")
    }

    @Test func aRejectedRefreshTokenAsksForReconnectAndIsRemembered() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "dead"])
        world.http.responses = [(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)]
        let account = world.account()

        await #expect(throws: GoogleAuthError.reconnectRequired) { try await account.accessToken() }
        #expect(account.status == .needsReconnect)
        #expect(world.store.get(.googleRefreshToken) == nil)

        // No further requests until the user signs in again, also after a relaunch.
        await #expect(throws: GoogleAuthError.reconnectRequired) { try await account.accessToken() }
        #expect(world.http.requests.count == 1)
        #expect(world.account().status == .needsReconnect)
    }

    @Test func reconnectingClearsTheReconnectState() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "dead"])
        world.http.responses = [(400, #"{"error":"invalid_grant"}"#), (200, Self.tokenReply)]
        let account = world.account()
        _ = try? await account.accessToken()
        #expect(account.status == .needsReconnect)

        world.approve()
        try await account.connect()

        #expect(account.status == .connected)
        #expect(world.account().status == .connected)
    }

    @Test func aRejectedClientIsNotMistakenForAnExpiredSignIn() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "wrong", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(401, #"{"error":"invalid_client","error_description":"Unauthorized"}"#)]
        let account = world.account()

        await #expect(throws: GoogleAuthError.badCredentials) { try await account.accessToken() }
        #expect(world.store.get(.googleRefreshToken) == "refresh-1")
        #expect(account.status == .connected)
    }

    @Test func withoutAConnectionThereIsNoTokenAndNoRequest() async {
        let world = World()
        await #expect(throws: GoogleAuthError.notConnected) { try await world.account().accessToken() }
        #expect(world.http.requests.isEmpty)
    }

    // Disconnecting and credentials

    @Test func disconnectForgetsTheTokenAndRevokesIt() async throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(200, "{}")]
        let account = world.account()

        await account.disconnect()

        #expect(account.status == .disconnected)
        #expect(world.store.get(.googleRefreshToken) == nil)
        #expect(world.http.requests[0].url == GoogleOAuth.revocationEndpoint)
        #expect(world.http.form(0) == ["token": "refresh-1"])
        // The client credentials stay for the next connection.
        #expect(world.store.get(.googleClientID) == "id")
    }

    @Test func disconnectWorksEvenWhenRevocationFails() async {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "refresh-1"])
        world.http.responses = [(503, "")]
        let account = world.account()
        await account.disconnect()
        #expect(account.status == .disconnected)
        #expect(world.store.get(.googleRefreshToken) == nil)
    }

    @Test func savingADifferentClientEndsTheConnection() throws {
        let world = World([.googleClientID: "id", .googleClientSecret: "s", .googleRefreshToken: "refresh-1"])
        let account = world.account()

        try account.saveCredentials(clientID: " id ", clientSecret: "new-secret\n")
        #expect(world.store.get(.googleClientSecret) == "new-secret")
        #expect(account.status == .connected)

        try account.saveCredentials(clientID: "other-id", clientSecret: "new-secret")
        #expect(world.store.get(.googleRefreshToken) == nil)
        #expect(account.status == .disconnected)

        try account.saveCredentials(clientID: "", clientSecret: "")
        #expect(world.store.get(.googleClientID) == nil)
        #expect(account.status == .notConfigured)
    }
}

// MARK: - Calendar API

@Suite struct GoogleCalendarServiceTests {
    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Tue 17 Nov 2026, 14:00–15:00 in Helsinki (UTC+2).
    static let meeting = ResolvedEvent(
        title: "Tiimipalaveri", start: date("2026-11-17T12:00:00Z"), end: date("2026-11-17T13:00:00Z"),
        isAllDay: false, location: "Neuvotteluhuone 3", notes: "Tuo läppäri", timeZone: helsinki
    )

    static let created = #"{"id":"evt123","htmlLink":"https://www.google.com/calendar/event?eid=abc","status":"confirmed"}"#

    final class Tokens {
        var calls: [Bool] = []
        func token(_ forceRefresh: Bool) async throws -> String {
            calls.append(forceRefresh)
            return forceRefresh ? "fresh-token" : "cached-token"
        }
    }

    static func service(_ http: FakeHTTP, _ tokens: Tokens = Tokens()) -> GoogleCalendarService {
        GoogleCalendarService(accessToken: tokens.token, transport: http.transport)
    }

    // Event bodies

    @Test func timedEventCarriesLocalTimeOffsetAndZone() throws {
        let body = GoogleCalendarService.body(for: Self.meeting)
        #expect(body["summary"] as? String == "Tiimipalaveri")
        #expect(body["location"] as? String == "Neuvotteluhuone 3")
        #expect(body["description"] as? String == "Tuo läppäri")
        #expect(body["start"] as? [String: String] == ["dateTime": "2026-11-17T14:00:00+02:00", "timeZone": "Europe/Helsinki"])
        #expect(body["end"] as? [String: String] == ["dateTime": "2026-11-17T15:00:00+02:00", "timeZone": "Europe/Helsinki"])
    }

    @Test func summerTimeUsesTheSummerOffset() {
        #expect(GoogleCalendarService.instant(Self.date("2026-07-01T09:00:00Z"), in: Self.helsinki) == "2026-07-01T12:00:00+03:00")
    }

    @Test func allDayEventCarriesDatesWithAnExclusiveEnd() throws {
        // Midnight Helsinki on 5 Dec to midnight on 7 Dec: the 5th and 6th.
        let event = ResolvedEvent(
            title: "Messut", start: Self.date("2026-12-04T22:00:00Z"), end: Self.date("2026-12-06T22:00:00Z"),
            isAllDay: true, location: nil, notes: nil, timeZone: Self.helsinki
        )
        let body = GoogleCalendarService.body(for: event)
        #expect(body["start"] as? [String: String] == ["date": "2026-12-05"])
        #expect(body["end"] as? [String: String] == ["date": "2026-12-07"])
        #expect(body["location"] == nil)
        #expect(body["description"] == nil)
    }

    @Test func resolverOutputBecomesTheExpectedBody() throws {
        // The two halves together: Claude's strings in, Google's fields out.
        let resolver = EventDateResolver(now: Self.date("2026-11-10T10:00:00Z"), timeZone: Self.helsinki)
        let extracted = try Extraction.decode(fromModelText: """
        {"events":[{"title":"Hammaslääkäri","start":"2026-11-17T14:00","end":null,"all_day":false,
          "year_given":true,"location":null,"description":null}],"reason_if_none":null}
        """)
        let body = GoogleCalendarService.body(for: try resolver.resolve(extracted.events[0]))
        #expect(body["start"] as? [String: String] == ["dateTime": "2026-11-17T14:00:00+02:00", "timeZone": "Europe/Helsinki"])
        #expect(body["end"] as? [String: String] == ["dateTime": "2026-11-17T15:00:00+02:00", "timeZone": "Europe/Helsinki"])
    }

    // Requests

    @Test func insertPostsTheEventAndReturnsItsIDAndLink() async throws {
        let http = FakeHTTP([(200, Self.created)])
        let event = try await Self.service(http).insert(Self.meeting, into: nil)

        #expect(event == CreatedEvent(
            id: "evt123", calendarID: "primary",
            htmlLink: URL(string: "https://www.google.com/calendar/event?eid=abc")
        ))
        let request = http.requests[0]
        #expect(request.url?.absoluteString == "https://www.googleapis.com/calendar/v3/calendars/primary/events")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cached-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(http.json(0)["summary"] as? String == "Tiimipalaveri")
    }

    @Test func insertGoesToTheNamedCalendar() async throws {
        let http = FakeHTTP([(200, Self.created)])
        let event = try await Self.service(http).insert(Self.meeting, into: "team@group.calendar.google.com")

        #expect(event.calendarID == "team@group.calendar.google.com")
        #expect(http.requests[0].url?.absoluteString ==
            "https://www.googleapis.com/calendar/v3/calendars/team%40group.calendar.google.com/events")
    }

    @Test func calendarIDIsEscapedInThePath() {
        let url = GoogleCalendarService.eventsURL(calendarID: "abc#123@group.calendar.google.com", eventID: "evt 1")
        #expect(url.absoluteString ==
            "https://www.googleapis.com/calendar/v3/calendars/abc%23123%40group.calendar.google.com/events/evt%201")
    }

    @Test func aRejectedTokenIsRefreshedOnceAndTheRequestRepeated() async throws {
        let http = FakeHTTP([(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#), (200, Self.created)])
        let tokens = Tokens()
        let event = try await Self.service(http, tokens).insert(Self.meeting, into: nil)

        #expect(event.id == "evt123")
        #expect(tokens.calls == [false, true])
        #expect(http.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer cached-token", "Bearer fresh-token"])
    }

    @Test func anUnknownCalendarIsNamedInTheError() async {
        let http = FakeHTTP([(404, #"{"error":{"code":404,"message":"Not Found"}}"#)])
        let service = Self.service(http)
        await #expect(throws: GoogleCalendarError.calendarNotFound("nope@group.calendar.google.com")) {
            try await service.insert(Self.meeting, into: "nope@group.calendar.google.com")
        }
    }

    @Test func googlesMessageIsPassedOn() async {
        let message = "Google Calendar API has not been used in project 123 before or it is disabled."
        let http = FakeHTTP([(403, #"{"error":{"code":403,"message":"\#(message)"}}"#)])
        let error = await #expect(throws: GoogleCalendarError.self) {
            try await Self.service(http).insert(Self.meeting, into: nil)
        }
        #expect(error == .api(status: 403, message: message))
        #expect(error?.localizedDescription.contains("has not been used in project") == true)
    }

    @Test func prepareOnlyChecksForAToken() async throws {
        let http = FakeHTTP()
        let tokens = Tokens()
        try await Self.service(http, tokens).prepare()
        #expect(tokens.calls == [false])
        #expect(http.requests.isEmpty)
    }

    @Test func deleteRemovesTheEventAndAcceptsAlreadyGone() async throws {
        let created = CreatedEvent(id: "evt123", calendarID: "team@group.calendar.google.com", htmlLink: nil)

        let http = FakeHTTP([(204, ""), (410, #"{"error":{"code":410,"message":"Resource has been deleted"}}"#)])
        try await Self.service(http).delete(created)
        try await Self.service(http).delete(created)

        #expect(http.requests[0].httpMethod == "DELETE")
        #expect(http.requests[0].url?.absoluteString ==
            "https://www.googleapis.com/calendar/v3/calendars/team%40group.calendar.google.com/events/evt123")

        let failing = FakeHTTP([(500, "")])
        await #expect(throws: GoogleCalendarError.api(status: 500, message: "")) {
            try await Self.service(failing).delete(created)
        }
    }

    // Calendar list

    @Test func calendarsListsWritableOnesWithTheMainOneFirst() async throws {
        let http = FakeHTTP([(200, #"""
        {"items":[
          {"id":"team@group.calendar.google.com","summary":"Tiimi","backgroundColor":"#16a765","accessRole":"writer"},
          {"id":"shared@group.calendar.google.com","summary":"Their name","summaryOverride":"Asiakkaat","accessRole":"writer"},
          {"id":"ben@example.com","summary":"ben@example.com","backgroundColor":"#9fe1e7","primary":true,"accessRole":"owner"}
        ]}
        """#)])
        let calendars = try await Self.service(http).calendars()

        #expect(calendars == [
            CalendarInfo(id: "ben@example.com", title: "ben@example.com", colorHex: "#9FE1E7", isDefault: true),
            CalendarInfo(id: "shared@group.calendar.google.com", title: "Asiakkaat"),
            CalendarInfo(id: "team@group.calendar.google.com", title: "Tiimi", colorHex: "#16A765"),
        ])
        let request = http.requests[0]
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/calendar/v3/users/me/calendarList")
        #expect(query(of: request.url!) == ["minAccessRole": "writer", "maxResults": "250"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cached-token")
    }

    @Test func calendarsFollowsEveryPage() async throws {
        let http = FakeHTTP([
            (200, #"{"items":[{"id":"a","summary":"A"}],"nextPageToken":"page 2"}"#),
            (200, #"{"items":[{"id":"b","summary":"B"}]}"#),
        ])
        let calendars = try await Self.service(http).calendars()

        #expect(calendars.map(\.id) == ["a", "b"])
        #expect(http.requests.count == 2)
        #expect(query(of: http.requests[1].url!)["pageToken"] == "page 2")
    }

    /// A sign-in from before the picker, or one where the box was unticked.
    @Test func aSignInWithoutTheListScopeAsksForAReconnect() async {
        let replies = [
            #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED"}}"#,
            #"{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"insufficientPermissions"}]}}"#,
            #"{"error":{"code":403,"message":"Denied","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#,
        ]
        for reply in replies {
            let http = FakeHTTP([(403, reply)])
            let error = await #expect(throws: GoogleCalendarError.self) {
                try await Self.service(http).calendars()
            }
            #expect(error == .calendarListNotAllowed)
            #expect(error?.localizedDescription.contains("Disconnect") == true)
        }
    }

    @Test func otherCalendarListFailuresKeepTheirOwnMessage() async {
        let message = "Google Calendar API has not been used in project 123 before or it is disabled."
        let http = FakeHTTP([
            (403, #"{"error":{"code":403,"message":"\#(message)","errors":[{"reason":"accessNotConfigured"}]}}"#),
            (404, ""),
        ])
        await #expect(throws: GoogleCalendarError.api(status: 403, message: message)) {
            try await Self.service(http).calendars()
        }
        // Not "no calendar with the ID…": the list isn't about one calendar.
        await #expect(throws: GoogleCalendarError.api(status: 404, message: "")) {
            try await Self.service(http).calendars()
        }
    }

    // Open

    @Test func openShowsTheEventsPageOrElseGoogleCalendar() {
        var opened: [URL] = []
        var service = Self.service(FakeHTTP())
        service.openURL = { opened.append($0) }

        let page = URL(string: "https://www.google.com/calendar/event?eid=abc")!
        service.open(CreatedEvent(id: "evt1", calendarID: "primary", htmlLink: page))
        service.open(CreatedEvent(id: "evt2", calendarID: "primary", htmlLink: nil))

        #expect(opened == [page, URL(string: "https://calendar.google.com/")!])
    }
}
