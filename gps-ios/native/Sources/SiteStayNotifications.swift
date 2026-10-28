import Foundation
import UserNotifications

/// Local-only alerts. Site names, coordinates and the user's GPS history are
/// never sent to ntfy, GitHub or another server.
@MainActor
final class SiteStayNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SiteStayNotifications()

    private let center = UNUserNotificationCenter.current()
    private weak var model: TimeModel?
    private var lastCheckedAt = Date.distantPast
    private var inFlight: Set<String> = []
    private let enabledAtKey = "siteAlertsEnabledAtV78"
    private let sentKeysKey = "siteAlertsSentStaysV78"
    private let recentSiteKey = "siteAlertsRecentSiteV78"
    private let recentAtKey = "siteAlertsRecentAtV78"
    private let pendingActionsKey = "siteAlertsPendingActionsV78"

    private enum Action {
        static let category = "mimapa.site-stay.v1"
        static let confirm = "mimapa.site-stay.confirm"
        static let correct = "mimapa.site-stay.correct"
    }

    private override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Action.category,
                actions: [
                    UNNotificationAction(identifier: Action.confirm,
                                         title: "Confirmado", options: []),
                    UNNotificationAction(identifier: Action.correct,
                                         title: "Corregir", options: [.foreground])
                ],
                intentIdentifiers: [],
                options: [])
        ])
    }

    func activate(model: TimeModel) {
        self.model = model
        // Existing history is the baseline: never notify old visits on update.
        if UserDefaults.standard.object(forKey: enabledAtKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: enabledAtKey)
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        replayPendingActions()
    }

    /// Called from the normal GPS callback. At most once per minute, without
    /// involving the network, Apple Maps lookup or a history-wide refresh.
    func evaluate(model: TimeModel) {
        let now = Date()
        guard now.timeIntervalSince(lastCheckedAt) >= 50 else { return }
        lastCheckedAt = now
        guard model.storageIsHealthy, model.recording, !model.isResting,
              let cell = model.activeCell,
              let start = model.currentVisitStart,
              let fix = model.current?.date,
              now.timeIntervalSince(fix) <= 120,
              start.timeIntervalSince1970 >
                  UserDefaults.standard.double(forKey: enabledAtKey),
              model.staySeconds(now: now) > SiteStayHistory.minimumSeconds,
              model.preferredSiteID(for: cell.id) != nil else { return }

        // The historical screen uses SiteStayHistory plus SiteDayPartsIndex.
        // Reuse exactly those decisions, not an independent guessed label.
        // The tail bound avoids reprocessing years of GPS data every minute.
        let stays = SiteStayHistory.extract(Array(model.data.intervals.suffix(1500)))
        guard let stay = stays.first(where: {
            $0.cell == cell && $0.end >= fix.addingTimeInterval(-120) &&
            abs($0.start.timeIntervalSince(start)) < 180 &&
            $0.confirmedSeconds > SiteStayHistory.minimumSeconds
        }) else { return }

        let key = stay.id
        let sent = UserDefaults.standard.stringArray(forKey: sentKeysKey) ?? []
        guard !sent.contains(key), !inFlight.contains(key) else { return }
        let lookup = SiteDayPartsIndex(
            assignments: model.data.siteStayAssignments,
            parts: model.data.siteStayParts,
            sites: model.data.identifiedSites)
        let portions = lookup.parts(for: stay)
        guard portions.count == 1, let part = portions.first,
              part.kind == .place, !part.confirmed,
              let siteID = part.siteID,
              let site = model.siteNamed(siteID) else { return }

        // Consecutive adjacent 100m grid squares assigned to the SAME place
        // must not create a burst of repeated notifications.
        let lastSite = UserDefaults.standard.string(forKey: recentSiteKey)
        let lastAt = UserDefaults.standard.double(forKey: recentAtKey)
        if lastSite == siteID.uuidString && now.timeIntervalSince1970 - lastAt < 900 {
            remember(key)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Nuevo sitio en Histórico"
        content.subtitle = site.name
        let hour = DateFormatter()
        hour.locale = Locale(identifier: "es_ES")
        hour.timeStyle = .short
        hour.dateStyle = .none
        content.body = "Estancia iniciada a las " + hour.string(from: stay.start)
        content.sound = .default
        content.categoryIdentifier = Action.category
        content.userInfo = [
            "stayID": key,
            "siteID": siteID.uuidString
        ]

        let request = UNNotificationRequest(identifier: "mimapa-site-" + key,
                                             content: content, trigger: nil)
        inFlight.insert(key)
        center.add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(key)
                guard error == nil else { return }
                self.remember(key)
                UserDefaults.standard.set(siteID.uuidString, forKey: self.recentSiteKey)
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.recentAtKey)
            }
        }
    }

    private func remember(_ key: String) {
        var sent = UserDefaults.standard.stringArray(forKey: sentKeysKey) ?? []
        guard !sent.contains(key) else { return }
        sent.append(key)
        if sent.count > 800 { sent.removeFirst(sent.count - 800) }
        UserDefaults.standard.set(sent, forKey: sentKeysKey)
    }

    private func replayPendingActions() {
        let pending = UserDefaults.standard.array(forKey: pendingActionsKey)
            as? [[String: String]] ?? []
        guard !pending.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: pendingActionsKey)
        for entry in pending {
            processAction(entry["action"] ?? "", stayID: entry["stayID"] ?? "",
                          siteID: entry["siteID"] ?? "")
        }
    }

    private func processAction(_ action: String, stayID: String, siteID: String) {
        guard !stayID.isEmpty, let siteUUID = UUID(uuidString: siteID) else { return }
        guard let model else {
            var pending = UserDefaults.standard.array(forKey: pendingActionsKey)
                as? [[String: String]] ?? []
            pending.append(["action":action, "stayID":stayID, "siteID":siteID])
            UserDefaults.standard.set(Array(pending.suffix(60)), forKey: pendingActionsKey)
            return
        }
        if action == Action.confirm {
            // Never silently overwrite a later manual correction.
            _ = model.confirmNotifiedStay(stayID: stayID, expectedSiteID: siteUUID)
        } else if action == Action.correct ||
                    action == UNNotificationDefaultActionIdentifier {
            model.openNotifiedStay(stayID: stayID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A notification must appear even if MiMapaDelTiempo is already open.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let data = response.notification.request.content.userInfo
        let stay = data["stayID"] as? String ?? ""
        let site = data["siteID"] as? String ?? ""
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            self.processAction(action, stayID: stay, siteID: site)
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            completionHandler()
        }
    }
}
