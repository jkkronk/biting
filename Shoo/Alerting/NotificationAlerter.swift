import Foundation
import UserNotifications

/// Posts a local `UNUserNotifications` banner as an optional alert channel.
///
/// Needs **no** sandbox entitlement — only runtime authorization. Uses a fixed identifier
/// so repeated reminders replace rather than stack. Notifications are suppressed by Focus
/// modes (acceptable: the overlay is the primary channel).
@MainActor
final class NotificationAlerter {
    /// Fixed id so a new reminder replaces the previous banner instead of piling up.
    private static let identifier = "com.shoo.Shoo.reminder"

    private let center: UNUserNotificationCenter
    /// Set once we know the user granted permission, to skip needless re-requests.
    private var isAuthorized = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Request authorization if it hasn't been granted yet.
    ///
    /// Returns whether notifications are authorized afterward, so the caller (plan 04's
    /// Settings UI) can flip `notificationEnabled` back off on denial.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
            return true
        case .denied:
            isAuthorized = false
            return false
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            isAuthorized = granted
            return granted
        @unknown default:
            isAuthorized = false
            return false
        }
    }

    /// Post (or replace) the reminder banner. No-op if not authorized.
    func post() {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hands down ✋"
        content.body = "You reached for your face."

        // Replace any previously delivered banner so they don't stack.
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])

        let request = UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: nil  // deliver immediately
        )
        center.add(request) { error in
            if let error {
                AppLogger.alerting.error("Notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
