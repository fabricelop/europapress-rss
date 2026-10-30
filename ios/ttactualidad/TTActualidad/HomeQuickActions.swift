import UIKit
import Combine

enum TTQuickAction: String, CaseIterable {
    case news = "com.fabricelop.ttactualidad.news-ready"
    case trends = "com.fabricelop.ttactualidad.trends-ready"
    case working = "com.fabricelop.ttactualidad.working"
    case pending = "com.fabricelop.ttactualidad.pending"

    var title: String {
        switch self {
        case .news: return "Noticias listas"
        case .trends: return "Tendencias listas"
        case .working: return "En elaboración"
        case .pending: return "Órdenes por confirmar"
        }
    }

    var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .trends: return "chart.bar"
        case .working: return "square.and.pencil"
        case .pending: return "clock.arrow.circlepath"
        }
    }
}

// These are last-read counts, never background/live promises or publication
// totals inferred from opening X. Nil means no successful data read yet.
struct TTQuickActionSummary: Codable, Equatable {
    var newsReady: Int? = nil
    var trendsReady: Int? = nil
    var newsWorking: Int? = nil
    var trendsWorking: Int? = nil
    var pending: Int = 0
    var checkedAt: Date? = nil
    var partial = false

    func count(for action: TTQuickAction) -> Int? {
        switch action {
        case .news: return newsReady
        case .trends: return trendsReady
        case .working:
            guard let newsWorking, let trendsWorking else { return nil }
            return newsWorking + trendsWorking
        case .pending: return pending
        }
    }

    func subtitle(for action: TTQuickAction) -> String {
        guard let checkedAt else {
            return action == .pending ? "Órdenes de este iPhone" : "Abre para sincronizar"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "dd/MM HH:mm"
        let prefix = action == .pending ? "En este iPhone" :
            partial ? "Datos parciales" : "Última consulta"
        return prefix + " · " + formatter.string(from: checkedAt)
    }
}

@MainActor
enum HomeQuickActions {
    private static let storageKey = "TTActualidad.home-quick-actions.v1"

    static func savedSummary() -> TTQuickActionSummary? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(TTQuickActionSummary.self, from: data)
    }

    static func items(for summary: TTQuickActionSummary) -> [UIApplicationShortcutItem] {
        TTQuickAction.allCases.map { action in
            let title = summary.count(for: action).map { action.title + " (\($0))" } ?? action.title
            return UIApplicationShortcutItem(
                type: action.rawValue, localizedTitle: title,
                localizedSubtitle: summary.subtitle(for: action),
                icon: UIApplicationShortcutIcon(systemImageName: action.symbol))
        }
    }

    static func update(_ summary: TTQuickActionSummary) {
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UIApplication.shared.shortcutItems = items(for: summary)
    }
}

// A retained, one-shot request survives a cold launch before SwiftUI subscribes.
// Unknown shortcuts are rejected, and consuming an older request never clears
// a newer selection. The callbacks only navigate; they issue no editorial write.
@MainActor
final class HomeQuickActionRouter: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let action: TTQuickAction
    }
    static let shared = HomeQuickActionRouter()
    @Published private(set) var request: Request?

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = TTQuickAction(rawValue: item.type) else { return false }
        request = Request(action: action)
        return true
    }

    func consume(_ value: Request) {
        if request?.id == value.id { request = nil }
    }
}

@MainActor
final class TTQuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = TTQuickActionSceneDelegate.self
        return configuration
    }
}

@MainActor
final class TTQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    // Also runs when iOS reconnects an existing scene after terminating the
    // process. A restored scene may reuse its configuration, so cold-launch
    // delivery belongs here rather than only in the app configuration method.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            HomeQuickActionRouter.shared.handle(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeQuickActionRouter.shared.handle(shortcutItem))
    }
}
