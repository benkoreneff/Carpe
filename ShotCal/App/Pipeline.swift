import Foundation
import os

/// The whole flow behind the shortcut: pick a region, send it to Claude,
/// resolve the dates, hand the events to the calendar, notify.
final class Pipeline {
    private static let log = Logger(subsystem: "com.koreneff.ShotCal", category: "pipeline")

    /// Asked at the start of every run, so a change in Settings takes effect
    /// at once. Undo asks for the service the capture was saved with.
    private let calendar: (CalendarServiceKind) -> CalendarService
    private let notifier: Notifier

    /// True while the region picker is on screen.
    private(set) var isSelecting = false
    /// Screenshots currently being read by Claude or saved.
    private(set) var activeJobs = 0
    /// One line about the most recent run, for the menu.
    private(set) var lastSummary: String?
    /// The JSON Claude returned for the most recent screenshot.
    private(set) var lastJSON: String?
    /// What the most recent capture saved, until it is undone. The menu offers
    /// Open and Undo for it, for when a Focus mode hid the notification.
    private(set) var lastSaved: SavedCapture?

    /// How the most recent run ended. Set for a few seconds so the menu bar
    /// icon can show it; a Focus mode can hide the notification, not the icon.
    enum Outcome { case success, needsAttention }
    private(set) var recentOutcome: Outcome?
    private var outcomeReset: Task<Void, Never>?

    var isWorking: Bool { activeJobs > 0 }

    var onChange: (() -> Void)?
    var onNeedsScreenRecording: (() -> Void)?
    var onNeedsAPIKey: (() -> Void)?
    var onNeedsCalendarAccess: (() -> Void)?
    /// Asks which calendar the events go to. Nil means the user cancelled.
    var chooseCalendar: ((CalendarPickerRequest) async -> CalendarInfo?)?

    init(calendar: @escaping (CalendarServiceKind) -> CalendarService, notifier: Notifier) {
        self.calendar = calendar
        self.notifier = notifier
    }

    func trigger() {
        Task { await run() }
    }

    private func run() async {
        guard !isSelecting else { return }

        // Without the permission screencapture still writes a file, but it only
        // contains the desktop picture, so stop before capturing anything.
        guard Permissions.hasScreenRecording else {
            onNeedsScreenRecording?()
            return
        }

        isSelecting = true
        let file: URL?
        do {
            file = try await Preferences.captureToFile
                ? ScreenCapturer.captureRegionToFile()
                : ScreenCapturer.captureRegionViaClipboard()
        } catch {
            isSelecting = false
            report(failure: error)
            return
        }
        isSelecting = false

        // Esc: nothing was written, nothing to do.
        guard let file else {
            Self.log.notice("Selection cancelled")
            return
        }

        activeJobs += 1
        onChange?()
        defer {
            if Preferences.keepCaptures {
                Self.log.notice("Kept capture at \(file.path, privacy: .public)")
            } else {
                try? FileManager.default.removeItem(at: file)
            }
            activeJobs -= 1
            onChange?()
        }

        do {
            try await process(file)
        } catch {
            report(failure: error)
        }
    }

    private func process(_ file: URL) async throws {
        let image = try ImagePreparer.prepare(fileAt: file)
        Self.log.notice("Captured \(image.pixelWidth)x\(image.pixelHeight) px, \(image.data.count) bytes")

        guard let apiKey = Keychain.get(.anthropicAPIKey), !apiKey.isEmpty else {
            lastSummary = "No API key yet"
            show(.needsAttention)
            notifier.post(
                title: "Screenshot captured, but there's no API key",
                body: "Got a \(image.pixelWidth)×\(image.pixelHeight) px image. Add your Anthropic API key in Settings to read events from it."
            )
            onNeedsAPIKey?()
            return
        }

        // A dead Google sign-in or a refused calendar permission ends the run
        // here, before the screenshot goes anywhere.
        let service = Preferences.calendarService
        let calendar = calendar(service)
        try await calendar.prepare()
        var calendarID = Preferences.calendarID(for: service)

        // "Ask every time" needs the calendars up front: their names go to
        // Claude with the screenshot, so it can suggest one.
        var choices: CalendarChoices?
        if Preferences.askForCalendar, calendar.savesEvents, chooseCalendar != nil {
            choices = CalendarChoices(try await calendar.calendars())
        }

        let now = Date()
        let timeZone = TimeZone.current
        let client = ClaudeClient(apiKey: apiKey, model: Preferences.modelID)
        let result = try await client.extractEvents(
            from: image, now: now, timeZone: timeZone, calendarNames: choices?.namesForClaude ?? []
        )

        lastJSON = JSONFormatting.pretty(result.rawJSON)
        // The event text stays out of the persistent log: .info is memory-only.
        Self.log.notice("Claude returned \(result.extraction.events.count) event(s)")
        Self.log.info("Claude returned: \(result.rawJSON, privacy: .public)")
        print(lastJSON ?? result.rawJSON)

        guard !result.extraction.events.isEmpty else {
            let reason = result.extraction.reasonIfNone ?? "The screenshot didn't contain an event with a clear date."
            lastSummary = "No event found"
            show(.needsAttention)
            notifier.post(title: "No event found", body: reason)
            return
        }

        let resolver = EventDateResolver(now: now, timeZone: timeZone)
        let events = try result.extraction.events.map(resolver.resolve)

        // One choice covers every event from the screenshot.
        var calendarName: String?
        if let choices, !choices.calendars.isEmpty, let chooseCalendar {
            let request = CalendarPickerRequest(
                title: Self.summary(of: events),
                details: Self.pickerDetails(for: events),
                choices: choices,
                preselected: choices.preselectedIndex(
                    suggestion: result.extraction.suggestedCalendar,
                    lastUsedID: Preferences.lastCalendarID(for: service),
                    defaultID: calendarID
                )
            )
            guard let chosen = await chooseCalendar(request) else {
                // Esc: nothing is created, and no notification is needed for
                // something the user just did.
                Self.log.notice("Calendar choice cancelled")
                lastSummary = "Not added: \(Self.summary(of: events))"
                onChange?()
                return
            }
            calendarID = chosen.id
            calendarName = choices.label(for: chosen)
            Preferences.setLastCalendarID(chosen.id, for: service)
        }

        var created: [CreatedEvent] = []
        for event in events {
            do {
                created.append(try await calendar.insert(event, into: calendarID))
            } catch where !created.isEmpty {
                // Some are already in the calendar; say which part worked.
                Self.log.error("Failed after \(created.count) of \(events.count): \(String(describing: error), privacy: .public)")
                lastSummary = "Added \(created.count) of \(events.count) events"
                // Undo removes the part that did get saved.
                let saved = SavedCapture(
                    service: service, summary: Self.summary(of: Array(events.prefix(created.count))), events: created
                )
                lastSaved = saved
                show(.needsAttention)
                notifier.post(
                    title: "Added \(created.count) of \(events.count) events",
                    body: "Stopped at \"\(event.title)\": \(error.localizedDescription)",
                    saved: saved
                )
                return
            }
        }
        Self.log.notice("\(calendar.savesEvents ? "Saved" : "Previewed") \(created.count) event(s)")
        announce(events, calendarName: calendarName, saved: calendar.savesEvents
            ? SavedCapture(service: service, summary: Self.summary(of: events), events: created)
            : nil)
    }

    /// The date lines under the picker's title: the time of a single event, or
    /// the first few of several.
    private static func pickerDetails(for events: [ResolvedEvent]) -> [String] {
        if events.count == 1, let event = events.first {
            return [EventFormatter.when(event)]
        }
        var lines = events.prefix(3).map { EventFormatter.line($0) }
        if events.count > 3 { lines.append("…and \(events.count - 3) more") }
        return lines
    }

    private static func summary(of events: [ResolvedEvent]) -> String {
        events.count == 1 ? events[0].title : "\(events.count) events"
    }

    /// `saved` is nil when the calendar was the stub and nothing was stored.
    /// `calendarName` is set when the user picked the calendar for this capture.
    private func announce(_ events: [ResolvedEvent], calendarName: String? = nil, saved: SavedCapture?) {
        let prefix = saved != nil ? "Added" : "Preview, not saved"
        // Without Google the run is only a preview; say how to change that.
        let hint = saved != nil
            ? calendarName.map { ["Calendar: \($0)"] } ?? []
            : ["Connect Google Calendar in Settings to save events."]
        if let saved { lastSaved = saved }
        show(.success)

        if events.count == 1, let event = events.first {
            lastSummary = "\(prefix): \(event.title)"
            let details = [EventFormatter.when(event), event.location].compactMap { $0 } + hint
            notifier.post(title: "\(prefix): \(event.title)", body: details.joined(separator: "\n"), saved: saved)
            return
        }

        lastSummary = "\(prefix): \(events.count) events"
        var lines = events.prefix(4).map { EventFormatter.line($0) }
        if events.count > 4 { lines.append("…and \(events.count - 4) more") }
        notifier.post(title: "\(prefix): \(events.count) events", body: (lines + hint).joined(separator: "\n"), saved: saved)
    }

    // MARK: - Undo

    /// Deletes what a capture saved. Works for any capture whose notification
    /// is still around, not only the latest.
    func undo(_ capture: SavedCapture) {
        Task {
            activeJobs += 1
            onChange?()
            defer {
                activeJobs -= 1
                onChange?()
            }
            do {
                // The service the events are in, whatever is selected now.
                let calendar = calendar(capture.service)
                // The stub would "delete" without touching Google.
                guard calendar.savesEvents else { throw GoogleAuthError.notConnected }
                for event in capture.events {
                    try await calendar.delete(event)
                }
                Self.log.notice("Removed \(capture.events.count) event(s)")
                if lastSaved == capture { lastSaved = nil }
                lastSummary = "Removed: \(capture.summary)"
                show(.success)
                notifier.post(title: "Removed: \(capture.summary)", body: "Deleted from your calendar.")
            } catch {
                Self.log.error("Undo failed: \(String(describing: error), privacy: .public)")
                lastSummary = "Couldn't remove: \(capture.summary)"
                show(.needsAttention)
                notifier.post(title: "Couldn't remove: \(capture.summary)", body: error.localizedDescription, saved: capture)
            }
        }
    }

    private func report(failure error: Error) {
        Self.log.error("Failed: \(String(describing: error), privacy: .public)")
        lastSummary = "Failed: \(error.localizedDescription)"
        notifier.post(title: "Couldn't add the event", body: error.localizedDescription)
        if case ClaudeError.missingAPIKey = error { onNeedsAPIKey?() }
        if let error = error as? AppleCalendarError, error.isAccessProblem { onNeedsCalendarAccess?() }
        show(.needsAttention)
    }

    private func show(_ outcome: Outcome) {
        recentOutcome = outcome
        onChange?()
        outcomeReset?.cancel()
        outcomeReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.recentOutcome = nil
            self?.onChange?()
        }
    }
}
