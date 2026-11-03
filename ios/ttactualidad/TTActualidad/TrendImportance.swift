import Foundation

/// Shared editorial flag, independent of rank, explanation revision and imagery.
enum TrendImportance {
    static let endpoint = URL(string: "https://ttactualidad.rainyraven22.chatgpt.site/api/trend-importance")!
    static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    struct Entry: Decodable {
        let name: String
        let important: Bool
    }
    struct Feed: Decodable {
        let schema_version: Int
        let project: String
        let items: [Entry]
    }
    struct Receipt: Decodable {
        let schema_version: Int
        let project: String
        let item: Entry
    }
    static func names(from data: Data) throws -> Set<String> {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard feed.schema_version == 1, feed.project == "ttendencias",
              feed.items.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 200 })
        else { throw URLError(.cannotParseResponse) }
        return Set(feed.items.filter(\.important).map { key($0.name) })
    }
    static func confirms(_ data: Data, name: String, important: Bool) throws -> Bool {
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        return receipt.schema_version == 1 && receipt.project == "ttendencias" &&
            key(receipt.item.name) == key(name) && receipt.item.important == important
    }
    static func load() async -> Set<String>? {
        do {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 12)
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("TTActualidad/0.4.51", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000
            else { return nil }
            return try names(from: data)
        } catch { return nil } // The store retains its last confirmed flags offline.
    }
}
