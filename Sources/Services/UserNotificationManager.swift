import Foundation
@preconcurrency import UserNotifications

actor UserNotificationManager: UserNotifying {
    private var center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        self.center = center
    }

    func notifyLowQuotaRecommendation(
        identifier: String,
        title: String,
        body: String
    ) async {
        let center = notificationCenter()
        guard await ensureAuthorizationIfNeeded(center: center) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex.low-quota.\(identifier)",
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    private func notificationCenter() -> UNUserNotificationCenter {
        if let center {
            return center
        }
        let center = UNUserNotificationCenter.current()
        self.center = center
        return center
    }

    private func ensureAuthorizationIfNeeded(center: UNUserNotificationCenter) async -> Bool {
        switch await authorizationStatus(center: center) {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization(center: center)
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func authorizationStatus(center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestAuthorization(center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}
