import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite struct ExtractionPromptTests {
    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    /// Tuesday 10 November 2026, 14:32 in Helsinki.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = helsinki
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 32))!
    }()

    @Test func systemPromptStatesDateWeekdayTimeAndZone() {
        let prompt = ExtractionPrompt.system(now: Self.now, timeZone: Self.helsinki)
        #expect(prompt.contains("Today is Tuesday 2026-11-10"))
        #expect(prompt.contains("The local time is 14:32"))
        #expect(prompt.contains("Europe/Helsinki (UTC+02:00)"))
    }

    @Test func systemPromptListsTheComingDaysWithWeekdays() {
        let prompt = ExtractionPrompt.system(now: Self.now, timeZone: Self.helsinki)
        #expect(prompt.contains("Tue 2026-11-10 (today), Wed 2026-11-11 (tomorrow), Thu 2026-11-12"))
        #expect(prompt.contains("Mon 2026-11-23"))
        #expect(!prompt.contains("2026-11-24"))
    }

    @Test func dateInThePromptFollowsTheGivenZoneNotUTC() {
        // 00:30 on 1 January in Helsinki is still 31 December in UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.helsinki
        let justAfterMidnight = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 30))!
        let prompt = ExtractionPrompt.system(now: justAfterMidnight, timeZone: Self.helsinki)
        #expect(prompt.contains("Today is Friday 2027-01-01"))
    }

    @Test func withoutCalendarsThePromptAndSchemaSayNothingAboutThem() {
        let prompt = ExtractionPrompt.system(now: Self.now, timeZone: Self.helsinki)
        #expect(!prompt.contains("suggested_calendar"))
        #expect(prompt == ExtractionPrompt.system(now: Self.now, timeZone: Self.helsinki, calendarNames: []))

        let properties = ExtractionPrompt.schema()["properties"] as? [String: Any]
        #expect(properties?["suggested_calendar"] == nil)
    }

    @Test func calendarNamesAreListedInThePrompt() {
        let prompt = ExtractionPrompt.system(
            now: Self.now, timeZone: Self.helsinki, calendarNames: ["Työ", "Koti (iCloud)", #"Lasten "harkat""#]
        )
        #expect(prompt.contains(#"The user's calendars are: "Työ", "Koti (iCloud)", "Lasten \"harkat\"". "#))
        #expect(prompt.contains("`suggested_calendar`"))
        // The date context is still there.
        #expect(prompt.contains("Today is Tuesday 2026-11-10"))
    }

    @Test func suggestedCalendarMustBeOneOfTheNamesOrNull() throws {
        let schema = ExtractionPrompt.schema(calendarNames: ["Työ", "Koti"])
        #expect(Set(schema["required"] as? [String] ?? []) == ["events", "reason_if_none", "suggested_calendar"])

        let properties = try #require(schema["properties"] as? [String: Any])
        let suggestion = try #require(properties["suggested_calendar"] as? [String: Any])
        let options = try #require(suggestion["anyOf"] as? [[String: Any]])
        #expect(options.count == 2)
        #expect(options[0]["type"] as? String == "string")
        #expect(options[0]["enum"] as? [String] == ["Työ", "Koti"])
        #expect(options[1]["type"] as? String == "null")
        _ = try JSONSerialization.data(withJSONObject: schema)
    }

    @Test func schemaMeetsStructuredOutputRules() throws {
        let schema = ExtractionPrompt.schema()
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["events", "reason_if_none"])

        let properties = try #require(schema["properties"] as? [String: Any])
        let events = try #require(properties["events"] as? [String: Any])
        let event = try #require(events["items"] as? [String: Any])
        let fields = try #require(event["properties"] as? [String: Any])

        #expect(event["additionalProperties"] as? Bool == false)
        // Every property is required; "nullable" is expressed in the type.
        #expect(Set(event["required"] as? [String] ?? []) == Set(fields.keys))
        #expect(Set(fields.keys) == ["title", "start", "end", "all_day", "year_given", "location", "description"])
        _ = try JSONSerialization.data(withJSONObject: schema)
    }
}

@Suite struct ExtractionDecodingTests {
    @Test func decodesAStructuredReply() throws {
        let json = """
        {"events":[{"title":"Tiimipalaveri","start":"2026-11-17T14:00:00","end":null,"all_day":false,
        "year_given":false,"location":"Neukkari 3","description":null}],"reason_if_none":null}
        """
        let extraction = try Extraction.decode(fromModelText: json)
        #expect(extraction.events == [
            ExtractedEvent(title: "Tiimipalaveri", start: "2026-11-17T14:00:00", yearGiven: false, location: "Neukkari 3"),
        ])
        #expect(extraction.reasonIfNone == nil)
    }

    @Test func decodesAnEmptyResultWithAReason() throws {
        let extraction = try Extraction.decode(fromModelText: #"{"events":[],"reason_if_none":"No date is visible."}"#)
        #expect(extraction.events.isEmpty)
        #expect(extraction.reasonIfNone == "No date is visible.")
    }

    @Test func toleratesACodeFenceAndMissingOptionalKeys() throws {
        let reply = """
        ```json
        {"events":[{"title":"Lunch","start":"2026-11-18T12:00:00"}]}
        ```
        """
        let extraction = try Extraction.decode(fromModelText: reply)
        #expect(extraction.events == [ExtractedEvent(title: "Lunch", start: "2026-11-18T12:00:00")])
        // A missing year_given must not trigger a rollover.
        #expect(extraction.events[0].yearGiven)
    }

    @Test func rejectsProse() {
        #expect(throws: (any Error).self) {
            try Extraction.decode(fromModelText: "I could not find an event.")
        }
    }
}

@Suite struct ClaudeClientTests {
    static let image = PreparedImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png", pixelWidth: 2, pixelHeight: 2)
    static let now = Date(timeIntervalSince1970: 1_794_000_000)
    static let utc = TimeZone(identifier: "UTC")!
    static let oneEvent = #"{"events":[{"title":"Demo","start":"2026-11-17T14:00:00","end":null,"all_day":false,"year_given":true,"location":null,"description":null}],"reason_if_none":null}"#

    /// Replays canned HTTP responses and records the request bodies.
    final class FakeAPI {
        var responses: [(status: Int, body: String)]
        var requests: [URLRequest] = []

        init(_ responses: [(status: Int, body: String)]) { self.responses = responses }

        var bodies: [[String: Any]] {
            requests.compactMap { $0.httpBody }.compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }

        func client(model: String = "claude-haiku-5-5") -> ClaudeClient {
            ClaudeClient(apiKey: "test-key", model: model, transport: { request in
                self.requests.append(request)
                let next = self.responses.removeFirst()
                let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
                return (Data(next.body.utf8), response)
            }, retryDelay: .zero)
        }
    }

    static func message(text: String, stopReason: String = "end_turn", thinkingFirst: Bool = false) -> String {
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        if thinkingFirst { blocks.insert(["type": "thinking", "thinking": "", "signature": "abc"], at: 0) }
        let object: [String: Any] = ["type": "message", "role": "assistant", "content": blocks, "stop_reason": stopReason]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func apiError(_ message: String) -> String {
        #"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"}}"#
    }

    @Test func requestUsesStructuredOutputsLowEffortAndNoSamplingParameters() async throws {
        let api = FakeAPI([(200, Self.message(text: Self.oneEvent))])
        _ = try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)

        let request = try #require(api.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)

        let body = try #require(api.bodies.first)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        for forbidden in ["temperature", "top_p", "top_k", "thinking", "output_format"] {
            #expect(body[forbidden] == nil, "\(forbidden) must not be sent")
        }
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] != nil)

        // Image first, then the text instruction.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Self.image.data.base64EncodedString())
    }

    @Test func readsTheTextBlockThatFollowsAThinkingBlock() async throws {
        let api = FakeAPI([(200, Self.message(text: Self.oneEvent, thinkingFirst: true))])
        let result = try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        #expect(result.extraction.events.map(\.title) == ["Demo"])
        #expect(result.usedStructuredOutputs)
    }

    @Test func refusalAndTruncationAreErrors() async {
        let refused = FakeAPI([(200, Self.message(text: "I can't help with that.", stopReason: "refusal"))])
        await #expect(throws: ClaudeError.refused) {
            try await refused.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }

        let truncated = FakeAPI([(200, Self.message(text: #"{"events":[{"ti"#, stopReason: "max_tokens"))])
        await #expect(throws: ClaudeError.truncated) {
            try await truncated.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }
    }

    @Test func missingKeyFailsWithoutCallingTheAPI() async {
        let api = FakeAPI([])
        var client = api.client()
        client.apiKey = ""
        await #expect(throws: ClaudeError.missingAPIKey) {
            try await client.extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }
        #expect(api.requests.isEmpty)
    }

    @Test func rejectedKeyIsReportedAndNotRetried() async {
        let api = FakeAPI([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        await #expect(throws: ClaudeError.api(status: 401, type: "authentication_error", message: "invalid x-api-key")) {
            try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }
        #expect(api.requests.count == 1)
    }

    @Test func overloadIsRetriedOnce() async throws {
        let api = FakeAPI([
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (200, Self.message(text: Self.oneEvent)),
        ])
        let result = try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        #expect(result.extraction.events.count == 1)
        #expect(api.requests.count == 2)
    }

    // Suggested calendar

    static func reply(suggesting calendar: String?) -> String {
        let value = calendar.map { "\"\($0)\"" } ?? "null"
        return String(oneEvent.dropLast()) + #","suggested_calendar":\#(value)}"#
    }

    @Test func calendarNamesGoIntoThePromptAndTheSchema() async throws {
        let api = FakeAPI([(200, Self.message(text: Self.reply(suggesting: "Työ")))])
        let result = try await api.client()
            .extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc, calendarNames: ["Työ", "Koti"])

        #expect(result.extraction.suggestedCalendar == "Työ")
        #expect(result.extraction.events.map(\.title) == ["Demo"])

        let body = try #require(api.bodies.first)
        #expect((body["system"] as? String)?.contains(#"The user's calendars are: "Työ", "Koti"."#) == true)
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["suggested_calendar"] != nil)
    }

    @Test func noSuggestionIsNil() async throws {
        let api = FakeAPI([(200, Self.message(text: Self.reply(suggesting: nil)))])
        let result = try await api.client()
            .extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc, calendarNames: ["Työ", "Koti"])
        #expect(result.extraction.suggestedCalendar == nil)
    }

    /// Only the plain-JSON fallback can do this; the schema rules it out.
    @Test func aSuggestionThatIsNotOneOfTheNamesIsDropped() async throws {
        let api = FakeAPI([
            (400, Self.apiError("output_config.format: structured outputs are not supported by this model")),
            (200, Self.message(text: Self.reply(suggesting: "Work stuff"))),
        ])
        let result = try await api.client(model: "some-older-model")
            .extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc, calendarNames: ["Työ", "Koti"])

        #expect(result.extraction.suggestedCalendar == nil)
        #expect(result.extraction.events.map(\.title) == ["Demo"])
        // The fallback prompt carries the same schema, names included.
        #expect((api.bodies.last?["system"] as? String)?.contains(#""enum":["Työ","Koti"]"#) == true)
    }

    @Test func withoutCalendarNamesTheRequestHasNoSuggestionField() async throws {
        let api = FakeAPI([(200, Self.message(text: Self.oneEvent))])
        let result = try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)

        #expect(result.extraction.suggestedCalendar == nil)
        let body = try #require(api.bodies.first)
        #expect((body["system"] as? String)?.contains("suggested_calendar") == false)
    }

    @Test func fallsBackToPlainJSONWhenTheModelRejectsOutputConfig() async throws {
        let api = FakeAPI([
            (400, Self.apiError("output_config.format: structured outputs are not supported by this model")),
            (200, Self.message(text: "```json\n\(Self.oneEvent)\n```")),
        ])
        let result = try await api.client(model: "some-older-model")
            .extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)

        #expect(!result.usedStructuredOutputs)
        #expect(result.extraction.events.map(\.title) == ["Demo"])
        let fallback = try #require(api.bodies.last)
        #expect(fallback["output_config"] == nil)
        #expect((fallback["system"] as? String)?.contains("JSON Schema") == true)
    }

    @Test func plainJSONGetsOneCorrectionAttempt() async throws {
        let api = FakeAPI([
            (400, Self.apiError("output_config: Extra inputs are not permitted")),
            (200, Self.message(text: "Here are the events you asked for!")),
            (200, Self.message(text: Self.oneEvent)),
        ])
        let result = try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        #expect(result.extraction.events.count == 1)
        #expect(api.requests.count == 3)

        // The correction request quotes the reply that failed to parse.
        let messages = try #require(api.bodies.last?["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect((content.last?["text"] as? String)?.contains("Here are the events you asked for!") == true)
    }

    @Test func plainJSONGivesUpAfterTheSecondBadReply() async {
        let api = FakeAPI([
            (400, Self.apiError("output_config: Extra inputs are not permitted")),
            (200, Self.message(text: "not json")),
            (200, Self.message(text: "still not json")),
        ])
        await #expect(throws: ClaudeError.self) {
            try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }
        #expect(api.requests.count == 3)
    }

    @Test func otherBadRequestsDoNotTriggerTheFallback() async {
        let api = FakeAPI([(400, Self.apiError("messages.0.content.0.image.source.base64: invalid base64 data"))])
        await #expect(throws: ClaudeError.self) {
            try await api.client().extractEvents(from: Self.image, now: Self.now, timeZone: Self.utc)
        }
        #expect(api.requests.count == 1)
    }
}

@Suite struct ImagePreparerTests {
    /// Writes a solid-colour PNG of the given size to a temp file.
    static func makePNG(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarpeTests-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func largeImageIsScaledToTheLongEdgeLimit() throws {
        let url = try Self.makePNG(width: 3200, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try ImagePreparer.prepare(fileAt: url)
        #expect(prepared.pixelWidth == 1600)
        #expect(prepared.pixelHeight == 500)
        #expect(prepared.mediaType == "image/png")
        #expect(prepared.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func tallImageIsLimitedByItsHeight() throws {
        let url = try Self.makePNG(width: 800, height: 2400)
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try ImagePreparer.prepare(fileAt: url)
        #expect(prepared.pixelHeight == 1600)
        #expect(prepared.pixelWidth == 533)
    }

    @Test func smallImageIsSentUntouched() throws {
        let url = try Self.makePNG(width: 1600, height: 900)
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try ImagePreparer.prepare(fileAt: url)
        #expect(prepared.pixelWidth == 1600)
        #expect(prepared.data == (try Data(contentsOf: url)))
    }

    @Test func missingFileThrows() {
        #expect(throws: ImagePreparerError.self) {
            try ImagePreparer.prepare(fileAt: URL(fileURLWithPath: "/nonexistent/shot.png"))
        }
    }
}

@Suite struct JSONFormattingTests {
    @Test func indentsWithoutReorderingKeys() {
        let pretty = JSONFormatting.pretty(#"{"title":"A: {b}, \"c\"","events":[],"start":null,"list":[1,2]}"#)
        #expect(pretty == """
        {
          "title": "A: {b}, \\"c\\"",
          "events": [],
          "start": null,
          "list": [
            1,
            2
          ]
        }
        """)
    }

    @Test func leavesNonJSONAlone() {
        #expect(JSONFormatting.pretty("not json {") == "not json {")
    }
}
