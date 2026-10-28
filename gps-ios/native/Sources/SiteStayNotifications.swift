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
    private var evaluating = false
    private let enabledAtKey = "siteAlertsEnabledAtV78"
    private let sentKeysKey = "siteAlertsSentStaysV78"
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

    /// A notification belongs to ONE visible row of Histórico de sitios,
    /// not to a GPS grid. The expensive date grouping runs off-main.
    func evaluate(model: TimeModel) {
        let now = Date()
        guard now.timeIntervalSince(lastCheckedAt) >= 50, !evaluating else { return }
        lastCheckedAt = now
        let enabledAt = UserDefaults.standard.double(forKey: enabledAtKey)
        guard enabledAt > 0, model.storageIsHealthy,
              let latestFix = model.current?.date,
              now.timeIntervalSince(latestFix) <= 120 else { return }

        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding:.day,value:-1,
                                      to:calendar.startOfDay(for:now)) ?? now
        // Capturing Swift arrays is COW: no history-wide canonicalization
        // while the user is scrolling or the GPS callback needs to return.
        let intervals = model.data.intervals
        let assignments = model.data.siteStayAssignments
        let parts = model.data.siteStayParts
        let sites = model.data.identifiedSites
        evaluating = true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let recent = intervals.filter { $0.end > yesterday }
            let stays = SiteStayHistory.extract(recent)
            let lookup = SiteDayPartsIndex(assignments:assignments,
                                            parts:parts,sites:sites)
            let entries = stays.map {
                SiteDaySource(stay:$0,parts:lookup.parts(for:$0))
            }
            let names = Dictionary(uniqueKeysWithValues:sites.map { ($0.id,$0.name) })
            var candidates:[(String,UUID,String,Date)] = []
            for date in [yesterday,now] {
                let report = SiteDayPresentation.build(entries,on:date,calendar:calendar)
                for group in report.groups where !group.confirmed {
                    guard let siteID = group.siteID,
                          let name = names[siteID],
                          group.firstStart.timeIntervalSince1970 >= enabledAt,
                          group.recordedSeconds > SiteStayHistory.minimumSeconds
                          else { continue }
                    candidates.append((group.id,siteID,name,group.firstStart))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.evaluating = false
                let sent = Set(UserDefaults.standard.stringArray(
                    forKey:self.sentKeysKey) ?? [])
                for (groupID,siteID,name,start) in candidates {
                    guard !sent.contains(groupID),
                          !self.inFlight.contains(groupID) else { continue }
                    self.deliver(groupID:groupID,siteID:siteID,
                                 siteName:name,started:start)
                }
            }
        }
    }

    private func deliver(groupID: String,siteID: UUID,
                         siteName: String,started: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Nuevo sitio en Histórico"
        content.subtitle = siteName
        let hour = DateFormatter()
        hour.locale = Locale(identifier:"es_ES")
        hour.timeStyle = .short
        hour.dateStyle = .none
        content.body = "Estancia iniciada a las " + hour.string(from:started)
        content.sound = .default
        content.categoryIdentifier = Action.category
        content.userInfo = ["stayID":groupID,"siteID":siteID.uuidString]

        let request = UNNotificationRequest(identifier:"mimapa-site-" + groupID,
                                            content:content,trigger:nil)
        inFlight.insert(groupID)
        center.add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(groupID)
                if error == nil { self.remember(groupID) }
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
            // iOS may invoke a background action before the SwiftUI scene
            // has appeared. Commit Confirmado to local SQLite immediately,
            // then also replay on next activation in case that scene already
            // held an older in-memory snapshot.
            if action == Action.confirm {
                let backgroundModel = TimeModel()
                _ = backgroundModel.confirmNotifiedStay(
                    stayID:stayID, expectedSiteID:siteUUID)
            }
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
