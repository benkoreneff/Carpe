import SwiftUI

/// Everything the user can set: the two services, the shortcut, and launch at
/// login. Secrets go to the Keychain, the rest to UserDefaults.
struct SettingsView: View {
    let google: GoogleAccount
    let hotKeys: HotKeyCenter

    @State private var apiKey = Keychain.get(.anthropicAPIKey) ?? ""
    @State private var apiKeyStatus: String?
    @AppStorage(Preferences.Key.modelID) private var modelID = Preferences.defaultModelID

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
                TextField("Calendar ID", text: $calendarID, prompt: Text(Preferences.defaultCalendarID))
            } header: {
                Text("Google Calendar")
            } footer: {
                Text(googleMessage ?? "Events go to the calendar with this ID. \"primary\" is the account's main calendar.")
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
