import Foundation
import HeadroomCore
import os
import UserNotifications

/// Delivers usage and cache notifications. nil outside an app bundle (`swift run`), where
/// `UNUserNotificationCenter` can't be used.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared: Notifier? = Bundle.main.bundleIdentifier == nil ? nil : Notifier()

    private let center = UNUserNotificationCenter.current()
    /// Cache alerts scheduled by this process, by session ID.
    private var scheduled: [String: Date] = [:]
    private var clearedStale = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func deliver(_ outcome: LimitAlerts.Outcome) {
        for alert in outcome.crossed {
            post(id: "limit-\(LimitAlerts.key(alert.accountKey, alert.window))", title: "\(alert.label): \(Formatting.percent(alert.used)) of \(alert.window.rawValue) limit",
                 body: "Resets \(alert.resetsAt.formatted(date: .omitted, time: .shortened)).")
        }
        for alert in outcome.reset {
            post(id: "reset-\(LimitAlerts.key(alert.accountKey, alert.window))", title: "\(alert.label): \(alert.window.rawValue) limit reset",
                 body: "Back to 0%.")
        }
    }

    func schedule(_ alerts: [CacheAlerts.Alert], sessions: [SessionSnapshot]) {
        let wanted = Dictionary(alerts.map { ($0.sessionId, $0.fireAt) }, uniquingKeysWith: { first, _ in first })
        if !clearedStale {
            clearedStale = true
            // Cache alerts left over from a previous run. Only these: an immediate usage alert
            // counts as pending until it's shown, so clearing everything would drop it.
            let keep = Set(wanted.keys.map(Self.cacheID))
            center.getPendingNotificationRequests { requests in
                let stale = requests.map(\.identifier).filter { $0.hasPrefix("cache-") && !keep.contains($0) }
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
        let dropped = scheduled.keys.filter { wanted[$0] == nil }
        center.removePendingNotificationRequests(withIdentifiers: dropped.map(Self.cacheID))
        for (id, fireAt) in wanted where scheduled[id] != fireAt {
            guard let session = sessions.first(where: { $0.sessionId == id }) else { continue }
            let recache = session.recacheTokens.map { "re-reads \(Formatting.tokens($0)) tokens" } ?? "re-reads the conversation"
            post(id: Self.cacheID(id), title: "\(session.displayName): cache goes cold in 5 minutes",
                 body: "After that, the next message \(recache) at full price.", at: fireAt)
        }
        scheduled = wanted
    }

    private static func cacheID(_ sessionId: String) -> String { "cache-\(sessionId)" }

    private func post(id: String, title: String, body: String, at date: Date? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0.timeIntervalSinceNow, 1), repeats: false) }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
            if let error { Self.log.error("Couldn't post \(id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated private static let log = Logger(subsystem: "io.github.danpurdy.headroom", category: "notifications")

    /// Show banners even though a menu bar app counts as frontmost while its panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
