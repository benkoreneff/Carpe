import SwiftUI
import UserNotifications

/// First-run walkthrough for the two permissions ShotCal needs.
struct PermissionsView: View {
    let notifier: Notifier

    @State private var hasScreenRecording = Permissions.hasScreenRecording
    @State private var askedForScreenRecording = false
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ShotCal needs two permissions")
                .font(.title2.weight(.semibold))

            step(
                granted: hasScreenRecording,
                title: "Screen Recording",
                detail: "Lets the region you select include other apps' windows. Without it the screenshot only shows your desktop picture."
            ) {
                if hasScreenRecording {
                    EmptyView()
                } else {
                    Button("Open Screen Recording Settings") {
                        // The request adds ShotCal to the list; the pane is where it gets switched on.
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                        askedForScreenRecording = true
                    }
                    if askedForScreenRecording {
                        Text("Switch ShotCal on in the list, then relaunch. macOS applies the change only to a fresh launch.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Relaunch ShotCal") { Permissions.relaunch() }
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
                    Text("Notifications are switched off for ShotCal.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Notification Settings") { Permissions.openNotificationSettings() }
                }
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .task { notifications = await notifier.authorizationStatus() }
        .onReceive(poll) { _ in
            hasScreenRecording = Permissions.hasScreenRecording
            Task { notifications = await notifier.authorizationStatus() }
        }
    }

    private func step<Controls: View>(
        granted: Bool, title: String, detail: String, @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
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
