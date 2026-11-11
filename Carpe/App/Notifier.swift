import Foundation
import UserNotifications

/// Posts the result notifications and routes their Open and Undo buttons.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let savedCategory = "EVENT_SAVED"
    private nonisolated static let openAction = "OPEN"
    private nonisolated static let undoAction = "UNDO"
    private nonisolated static let captureKey = "capture"

    /// Open was chosen, or the notification itself was clicked.
    var onOpen: ((SavedCapture) -> Void)?
    var onUndo: ((SavedCapture) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    /// Call once at launch, before any notification can arrive. Responses to
    /// notifications from an earlier run are delivered here too.
    func activate() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.savedCategory,
                actions: [
                    UNNotificationAction(identifier: Self.openAction, title: "Open"),
                    UNNotificationAction(identifier: Self.undoAction, title: "Undo"),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Shows the system prompt the first time. Afterwards it only reports the
    /// existing answer, and a denial has to be reversed in System Settings.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// With `saved`, the notification gets the Open and Undo buttons.
    func post(title: String, body: String, saved: SavedCapture? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let saved {
            content.categoryIdentifier = Self.savedCategory
            content.userInfo = [Self.captureKey: saved.encoded]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            // If the welcome window was skipped, ask now rather than drop the result.
            if await authorizationStatus() == .notDetermined {
                await requestAuthorization()
            }
            try? await center.add(request)
        }
    }

    // Without this, macOS hides banners from the app that is posting them.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard let encoded = response.notification.request.content.userInfo[Self.captureKey] as? String else { return }
        await MainActor.run {
            guard let capture = SavedCapture(encoded: encoded) else { return }
            switch action {
            case Self.undoAction: self.onUndo?(capture)
            case Self.openAction, UNNotificationDefaultActionIdentifier: self.onOpen?(capture)
            default: break // dismissed
            }
        }
    }
}
