import SwiftUI
import UserNotifications

/// First-run walkthrough: where events are saved, and the permissions Carpe
/// needs. Also under Permissions… in the menu.
struct PermissionsView: View {
    let notifier: Notifier
    let apple: AppleCalendarService
    let google: GoogleAccount
    let showSettings: () -> Void

    /// Empty until a service has been chosen; shared with Settings.
    @AppStorage(Preferences.Key.calendarService) private var storedService = ""
    @State private var calendarAccess = AppleCalendarAccess.notDetermined
    @State private var hasScreenRecording = Permissions.hasScreenRecording
    @State private var askedForScreenRecording = false
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up Carpe")
                .font(.title2.weight(.semibold))

            step(
                granted: calendarReady,
                title: "Calendar",
                detail: "Choose where the events you capture are saved."
            ) {
                Picker("Calendar service", selection: $storedService) {
                    ForEach(CalendarServiceKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch service {
                case .apple: appleControls
                case .google: googleControls
                case nil: EmptyView()
                }
            }

            step(
                granted: hasScreenRecording,
                title: "Screen Recording",
                detail: "Lets the region you select include other apps' windows. Without it the screenshot only shows your desktop picture."
            ) {
                if hasScreenRecording {
                    EmptyView()
                } else {
                    Button("Open Screen Recording Settings") {
                        // The request adds Carpe to the list; the pane is where it gets switched on.
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                        askedForScreenRecording = true
                    }
                    if askedForScreenRecording {
                        note("Switch Carpe on in the list, then relaunch. macOS applies the change only to a fresh launch.")
                        Button("Relaunch Carpe") { Permissions.relaunch() }
                    }
                }
            }

            step(
                granted: notifications == .authorized || notifications == .provisional,
                title: "Notifications",
                detail: "Each capture ends with a notification that shows the event, or says what went wrong."
            ) {
                switch notifications {
                case .authorized, .provisional:
                    EmptyView()
                case .notDetermined:
                    Button("Allow Notifications") {
                        Task {
                            await notifier.requestAuthorization()
                            notifications = await notifier.authorizationStatus()
                        }
                    }
                default:
                    note("Notifications are switched off for Carpe.")
                    Button("Open Notification Settings") { Permissions.openNotificationSettings() }
                }
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .task {
            calendarAccess = apple.access
            notifications = await notifier.authorizationStatus()
        }
        .onReceive(poll) { _ in
            calendarAccess = apple.access
            hasScreenRecording = Permissions.hasScreenRecording
            Task { notifications = await notifier.authorizationStatus() }
        }
    }

    // MARK: - Calendar

    private var service: CalendarServiceKind? { CalendarServiceKind(rawValue: storedService) }

    private var calendarReady: Bool {
        switch service {
        case .apple: calendarAccess == .granted
        case .google: google.status == .connected
        case nil: false
        }
    }

    @ViewBuilder private var appleControls: some View {
        switch calendarAccess {
        case .granted:
            EmptyView()
        case .notDetermined:
            note("Carpe needs full access: it lists your calendars, adds events, and removes one when you choose Undo.")
            Button("Allow Calendar Access") {
                Task { calendarAccess = await apple.requestAccess() }
            }
        case .denied:
            note("Calendar access is switched off for Carpe.")
            Button("Open Calendar Settings") { Permissions.openCalendarSettings() }
        case .addOnly:
            note("Carpe is set to Add Only. Change it to Full Access so it can list your calendars and undo.")
            Button("Open Calendar Settings") { Permissions.openCalendarSettings() }
        case .restricted:
            note("Calendar access is restricted on this Mac, so Apple Calendar can't be used here.")
        }
    }

    @ViewBuilder private var googleControls: some View {
        switch google.status {
        case .connected:
            EmptyView()
        case .needsReconnect:
            note("The Google sign-in has expired.")
            Button("Open Settings", action: showSettings)
        case .notConfigured, .disconnected, .connecting:
            note("Google Calendar needs your own Google client ID and a sign-in.")
            Button("Open Settings", action: showSettings)
        }
    }

    // MARK: - Layout

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step<Controls: View>(
        granted: Bool, title: String, detail: String, @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                controls()
            }
        }
    }
}
