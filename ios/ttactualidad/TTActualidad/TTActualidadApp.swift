import SwiftUI

@main
struct TTActualidadApp: App {
    @UIApplicationDelegateAdaptor(TTQuickActionAppDelegate.self) private var appDelegate
    @StateObject private var store = EditorialStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TTDashboard()
                .environmentObject(store)
                .task {
                    store.updateHomeQuickActions()
                    await store.refreshIfStale(minInterval: 0)
                }
                .onOpenURL { url in
                    guard url.scheme == "ttactualidad" else { return }
                    if url.host == "noticias" { store.section = .news }
                    else { store.section = .trends }
                    store.trendFilter = .listas
                    Task { await store.refreshIfStale(minInterval: 90) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await store.refreshIfStale(minInterval: 120) }
                    } else if newPhase == .background {
                        store.updateHomeQuickActions()
                        store.markVisitComplete()
                    }
                }
        }
    }
}
