import Foundation
import UserNotifications

/// Manages macOS notifications for usage threshold alerts.
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    /// Tracks which alerts have already been sent: "{provider}_{windowId}_{threshold}"
    private var sentAlerts: Set<String> = []

    /// Whether we have notification permission
    @Published private(set) var isAuthorized = false

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        checkAuthorization()
    }

    // MARK: - Permissions

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    private func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { [weak self] in
                self?.isAuthorized = authorized
            }
        }
    }

    // MARK: - Threshold checking

    /// Check all usage windows across all providers and send alerts for any that exceed thresholds.
    func checkThresholds(snapshots: [ProviderKind: ProviderSnapshot], settings: AlertSettings) {
        guard settings.enabled, isAuthorized else { return }

        for (provider, snapshot) in snapshots {
            guard snapshot.status != .error, !snapshot.windows.isEmpty else { continue }

            for window in snapshot.windows {
                guard let pct = window.resolvedPercentUsed else { continue }
                let pctInt = Int(pct * 100)

                for threshold in settings.thresholds.sorted() {
                    let alertKey = "\(provider.rawValue)_\(window.id)_\(threshold)"

                    if pctInt >= threshold {
                        // Only send if not already sent
                        if !sentAlerts.contains(alertKey) {
                            sentAlerts.insert(alertKey)
                            sendAlert(
                                provider: provider,
                                window: window,
                                threshold: threshold,
                                currentPct: pctInt
                            )
                        }
                    } else {
                        // Usage dropped below threshold (reset happened) — clear the alert
                        sentAlerts.remove(alertKey)
                    }
                }
            }
        }
    }

    /// Clear all sent alerts (e.g., on app launch or manual reset)
    func clearAllAlerts() {
        sentAlerts.removeAll()
    }

    // MARK: - Sending

    private nonisolated func sendAlert(provider: ProviderKind, window: UsageWindow, threshold: Int, currentPct: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) — \(window.label)"

        var body = "\(currentPct)% used (threshold: \(threshold)%)"
        if let resetDate = window.resetDate {
            let remaining = resetDate.timeIntervalSinceNow
            if remaining > 0 {
                body += " · Resets in \(formatDuration(remaining))"
            }
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "USAGE_ALERT"

        // Use threadIdentifier to group by provider
        content.threadIdentifier = provider.rawValue

        let id = "\(provider.rawValue)_\(window.id)_\(threshold)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request)
    }

    private nonisolated func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
