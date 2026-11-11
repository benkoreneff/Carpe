import SwiftUI

/// Everything the user can set: Claude, the calendar service, the shortcut,
/// and launch at login. Secrets go to the Keychain, the rest to UserDefaults.
struct SettingsView: View {
    let google: GoogleAccount
    let apple: AppleCalendarService
    let hotKeys: HotKeyCenter
    /// The calendars of the connected Google account.
    let googleCalendars: () async throws -> [CalendarInfo]

    @State private var apiKey = Keychain.get(.anthropicAPIKey) ?? ""
    @State private var apiKeyStatus: String?
    @AppStorage(Preferences.Key.modelID) private var modelID = Preferences.defaultModelID

    /// Empty until a service has been chosen; shared with the welcome window.
    @AppStorage(Preferences.Key.calendarService) private var storedService = ""

    @State private var appleAccess = AppleCalendarAccess.notDetermined
    @State private var appleCalendars: [CalendarInfo] = []
    @State private var appleMessage: String?
    @AppStorage(Preferences.Key.appleCalendarID) private var appleCalendarID = ""
    @AppStorage(Preferences.Key.askForCalendar) private var askForCalendar = false

    @State private var googleCalendarList: [CalendarInfo] = []
    /// Why the Google calendars can't be listed, when they can't.
    @State private var googleListProblem: String?

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var googleMessage: String?
    @AppStorage(Preferences.Key.calendarID) private var calendarID = Preferences.defaultCalendarID

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var generalMessage: String?

    var body: some View {
        Form {
            Section("Claude") {
                SecureField("Anthropic API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onSubmit(saveAPIKey)
                HStack {
                    Button("Save Key", action: saveAPIKey)
                    if let apiKeyStatus {
                        Text(apiKeyStatus).foregroundStyle(.secondary)
                    }
                }
                TextField("Model ID", text: $modelID, prompt: Text(Preferences.defaultModelID))
            }

            Section {
                Picker("Calendar service", selection: service) {
                    ForEach(CalendarServiceKind.allCases) { Text($0.displayName).tag($0) }
                }
                // Only the selected service's settings are shown.
                switch service.wrappedValue {
                case .apple: appleRows
                case .google: googleRows
                }
                Toggle("Ask which calendar every time", isOn: $askForCalendar)
            } header: {
                Text("Calendar")
            } footer: {
                Text(calendarFooter)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Capture shortcut") {
                    ShortcutRecorder(hotKeys: hotKeys, message: $generalMessage)
                }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            } header: {
                Text("General")
            } footer: {
                if let generalMessage {
                    Text(generalMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            clientID = google.clientID
            clientSecret = google.clientSecret
        }
        .task(id: service.wrappedValue) { await refreshApple() }
        .task(id: googleListKey) { await refreshGoogleCalendars() }
        // Back from System Settings: the calendar permission may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshApple() }
        }
    }

    // MARK: - Calendar service

    private var service: Binding<CalendarServiceKind> {
        Binding(
            get: { CalendarServiceKind(rawValue: storedService) ?? Preferences.calendarService },
            set: { storedService = $0.rawValue }
        )
    }

    private var calendarFooter: String {
        let asking = "After reading a screenshot, ShotCal shows your calendars with Claude's suggestion selected, "
            + "or else the one used last. The calendar names are sent to Claude along with the screenshot."
        switch service.wrappedValue {
        case .apple:
            return appleMessage ?? (askForCalendar
                ? asking
                : "Events go to the default calendar. Calendars that can't be changed aren't listed.")
        case .google:
            if let message = googleMessage ?? googleListProblem { return message }
            if askForCalendar { return asking }
            return googleCalendarList.isEmpty
                ? "Events go to the calendar with this ID. \"primary\" is the account's main calendar."
                : "Events go to the default calendar."
        }
    }

    // MARK: - Apple Calendar

    @ViewBuilder private var appleRows: some View {
        LabeledContent("Access") {
            HStack {
                Text(appleAccessText).foregroundStyle(appleAccess == .granted ? Color.secondary : Color.orange)
                Spacer()
                switch appleAccess {
                case .granted, .restricted:
                    EmptyView()
                case .notDetermined:
                    Button("Allow Access") {
                        Task {
                            await apple.requestAccess()
                            await refreshApple()
                        }
                    }
                case .denied, .addOnly:
                    Button("Open Calendar Settings") { Permissions.openCalendarSettings() }
                }
            }
        }
        if appleAccess == .granted, !appleCalendars.isEmpty {
            Picker("Default calendar", selection: appleCalendar) {
                ForEach(appleCalendars) { calendar in
                    Text(calendar.account.map { "\(calendar.title) (\($0))" } ?? calendar.title).tag(calendar.id)
                }
            }
        }
    }

    private var appleAccessText: String {
        switch appleAccess {
        case .notDetermined: "Not allowed yet"
        case .granted: "Allowed"
        case .addOnly: "Add Only; ShotCal needs Full Access"
        case .denied: "Switched off"
        case .restricted: "Restricted on this Mac"
        }
    }

    /// Shows the Calendar app's default until a calendar has been picked.
    private var appleCalendar: Binding<String> {
        Binding(
            get: {
                if !appleCalendarID.isEmpty { return appleCalendarID }
                return (appleCalendars.first(where: \.isDefault) ?? appleCalendars.first)?.id ?? ""
            },
            set: { appleCalendarID = $0 }
        )
    }

    private func refreshApple() async {
        appleAccess = apple.access
        guard service.wrappedValue == .apple, appleAccess == .granted else {
            appleCalendars = []
            return
        }
        do {
            appleCalendars = try await apple.calendars()
            appleMessage = nil
            // A deleted calendar would make every capture fail; go back to the default.
            if !appleCalendarID.isEmpty, !appleCalendars.contains(where: { $0.id == appleCalendarID }) {
                appleCalendarID = ""
                appleMessage = "The calendar chosen earlier no longer exists, so events go to the default one for now."
            }
        } catch {
            appleCalendars = []
            appleMessage = error.localizedDescription
        }
    }

    // MARK: - Claude

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.set(trimmed.isEmpty ? nil : trimmed, for: .anthropicAPIKey)
            apiKey = trimmed
            apiKeyStatus = trimmed.isEmpty ? "Removed from the Keychain" : "Saved in the Keychain"
        } catch {
            apiKeyStatus = error.localizedDescription
        }
    }

    // MARK: - General

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            generalMessage = nil
            if enabled, LoginItem.needsApproval {
                generalMessage = "Allow ShotCal under System Settings > General > Login Items."
                LoginItem.openSystemSettings()
            } else if enabled, !LoginItem.runsFromApplications {
                generalMessage = "This copy of ShotCal runs from the build folder, so the login item breaks when "
                    + "the folder is cleaned. Run \"make install\" and switch this on in the installed copy."
            }
        } catch {
            generalMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled || (enabled && LoginItem.needsApproval)
    }

    // MARK: - Google

    @ViewBuilder private var googleRows: some View {
        TextField("Client ID", text: $clientID, prompt: Text("….apps.googleusercontent.com"))
            .disabled(credentialsLocked)
        SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
            .disabled(credentialsLocked)
        LabeledContent("Status") {
            HStack {
                Text(statusText).foregroundStyle(google.status == .needsReconnect ? .orange : .secondary)
                Spacer()
                googleButton
            }
        }
        if googleCalendarList.isEmpty {
            // Not connected, or a sign-in that can't list calendars: the ID
            // can still be typed.
            TextField("Calendar ID", text: $calendarID, prompt: Text(Preferences.defaultCalendarID))
        } else {
            Picker("Default calendar", selection: googleCalendar) {
                ForEach(googleCalendarList) { Text($0.title).tag($0.id) }
                // A typed ID that isn't in the account's list is kept as it is.
                if !googleCalendarList.contains(where: { $0.id == googleCalendar.wrappedValue }) {
                    Text(googleCalendar.wrappedValue).tag(googleCalendar.wrappedValue)
                }
            }
        }
    }

    /// "primary" and an empty field both mean the account's main calendar.
    private var googleCalendar: Binding<String> {
        Binding(
            get: {
                let stored = calendarID.trimmingCharacters(in: .whitespacesAndNewlines)
                if stored.isEmpty || stored == Preferences.defaultCalendarID {
                    return googleCalendarList.first(where: \.isDefault)?.id ?? Preferences.defaultCalendarID
                }
                return stored
            },
            set: { calendarID = $0 }
        )
    }

    /// Reload the list when the service or the connection changes.
    private var googleListKey: String { "\(service.wrappedValue.rawValue) \(google.status)" }

    private func refreshGoogleCalendars() async {
        googleListProblem = nil
        guard service.wrappedValue == .google, google.status == .connected else {
            googleCalendarList = []
            return
        }
        do {
            googleCalendarList = try await googleCalendars()
        } catch {
            googleCalendarList = []
            googleListProblem = error.localizedDescription
        }
    }

    /// The client can't change under a live connection; disconnect first.
    private var credentialsLocked: Bool {
        google.status == .connecting || google.status == .connected
    }

    private var statusText: String {
        switch google.status {
        case .notConfigured: "Not set up"
        case .disconnected: "Not connected"
        case .connecting: "Waiting for the browser…"
        case .connected: "Connected"
        case .needsReconnect: "Sign-in expired"
        }
    }

    @ViewBuilder private var googleButton: some View {
        switch google.status {
        case .connecting:
            Button("Cancel") { google.cancelConnect() }
        case .connected:
            Button("Disconnect") {
                googleMessage = nil
                Task { await google.disconnect() }
            }
        case .needsReconnect:
            Button("Reconnect Google", action: connect)
        case .notConfigured, .disconnected:
            Button("Connect Google", action: connect)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty
                    || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Saves the two fields to the Keychain, then runs the sign-in.
    private func connect() {
        googleMessage = nil
        do {
            try google.saveCredentials(clientID: clientID, clientSecret: clientSecret)
        } catch {
            googleMessage = error.localizedDescription
            return
        }
        Task {
            do {
                try await google.connect()
                googleMessage = "Connected. New captures are saved to your calendar."
            } catch is CancellationError {
                googleMessage = "Sign-in cancelled."
            } catch {
                googleMessage = error.localizedDescription
            }
            // The browser is in front after the sign-in; come back.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
