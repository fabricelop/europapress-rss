import Foundation\nimport SwiftUI

@main
struct TTiTTularesApp: App {
    @State private var destination = Router.webURL(for: .listas)

    var body: some Scene {
        WindowGroup {
            WebContainer(url: $destination)
                .ignoresSafeArea()
                .onOpenURL { url in
                    if let next = Router.webURL(from: url) {
                        destination = next
                    }
                }
        }
    }
}

enum WidgetDestination: String {
    case listas
    case elaboracion
    case creciendo
    case tendencias
}

enum Router {
    private static let baseURL = URL(string: "https://europapress-rss.vercel.app/ttittulares/")!

    static func webURL(for destination: WidgetDestination) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let view: String
        switch destination {
        case .listas: view = "ready"
        case .elaboracion: view = "processing"
        case .creciendo: view = "growing"
        case .tendencias: view = "problematic"
        }
        components.queryItems = [URLQueryItem(name: "view", value: view)]
        return components.url!
    }

    static func webURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "ttittulares" else { return nil }
        let host = url.host ?? ""
        let key = (host.isEmpty ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : host).lowercased()
        guard let destination = WidgetDestination(rawValue: key) else { return nil }
        return webURL(for: destination)
    }
}
