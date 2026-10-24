import Foundation
import UserNotifications

/// Local notifications. Content is only ever created from work that actually
/// finished — never predicted or promised.
@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private let preferences: PreferencesStore

    static let morningReportID = "morning-report"
    static let discoveryCompletedID = "discovery-completed"

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Requests permission. Called only when the user turns on a notification.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Posts after a background run that genuinely completed or made progress.
    func discoveryFinished(_ result: DiscoveryRunResult, now: Date = .now) async {
        guard result.photosAnalyzed > 0 else { return }
        let found = result.newCandidates

        if preferences.notifyMorningReport, let deliverAt = Self.morningDeliveryDate(after: now) {
            let content = UNMutableNotificationContent()
            content.title = "Good morning"
            content.body = found > 0
                ? "Your discovery review is ready. \(Self.itemsPhrase(found)) to look at."
                : "Your discovery review is ready. \(Formatting.count(result.photosAnalyzed)) photos were analysed."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: deliverAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.morningReportID, content: content, trigger: trigger))
        } else if preferences.notifyDiscoveryCompleted, found > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Discovery complete"
            content.body = "\(Self.itemsPhrase(found)) found in \(Formatting.count(result.photosAnalyzed)) photos. Confirm which ones you still own."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: Self.discoveryCompletedID, content: content, trigger: nil))
        }
    }

    func scheduleListingReminder(draftID: UUID, title: String, after interval: TimeInterval = 3 * 24 * 3600) async {
        guard preferences.notifyListingReminders else { return }
        let content = UNMutableNotificationContent()
        content.title = "Finish your listing"
        content.body = "“\(title)” is ready for a few final details."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.reminderID(draftID), content: content, trigger: trigger))
    }

    func cancelListingReminder(draftID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID(draftID)])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    /// Overnight work (9pm–7am) is reported at 8am; otherwise returns nil.
    nonisolated static func morningDeliveryDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let hour = calendar.component(.hour, from: date)
        guard hour >= 21 || hour < 7 else { return nil }
        let day = hour >= 21 ? calendar.date(byAdding: .day, value: 1, to: date) ?? date : date
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)
    }

    private static func reminderID(_ id: UUID) -> String { "listing-reminder-\(id.uuidString)" }

    private static func itemsPhrase(_ count: Int) -> String {
        count == 1 ? "1 potential item" : "\(count) potential items"
    }
}
