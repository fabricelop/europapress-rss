import SwiftUI

@main
struct TTActualidadApp: App {
    @StateObject private var store = EditorialStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            EditorialView()
                .environmentObject(store)
                .task { await store.refresh() }
                .onOpenURL { url in
                    guard url.scheme == "ttactualidad" else { return }
                    if url.host == "noticias" { store.section = .news }
                    else { store.section = .trends }
                    store.trendFilter = .listas
                    Task { await store.refresh() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await store.refresh() }
                    }
                }
        }
    }
}
