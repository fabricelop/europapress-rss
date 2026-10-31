import Foundation

/// Public, read-only index of the exact PNGs already attached to ChatGPT Sites.
/// No AI generation, no PC listener, no new paid API and no archive-gallery mixing.
enum SiteAIImageCatalog {
    private static let memory = SiteAIImageMemory()
    private static let projectID = "appgprj_6ae4dcf7d7488191a574e5b649e67370"
    private static let siteHost = "ttactualidad-tendencias.rainyraven22.chatgpt.site"
    private static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/site-ai-images.json")!

    struct Entry: Decodable {
        let target_id: String
        let revision: Int
        let explained_at: String
        let explanation: String
        let image_url: String
        let sha256: String
    }

    private struct Manifest: Decodable {
        let schema_version: Int
        let project_id: String
        let images: [Entry]
    }

    private static func key(id: String, revision: Int) -> String {
        id + ":r" + String(revision)
    }

    static func load() async -> [String: Entry] {
        if let cached = await memory.fresh() { return cached }
        let disk = FileManager.default.urls(for: .cachesDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("ttactualidad-site-ai-index.json")
        var request = URLRequest(url: manifestURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 12)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let data: Data?
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  responseData.count < 2_000_000 else { throw URLError(.badServerResponse) }
            data = responseData
        } catch {
            data = try? Data(contentsOf: disk)
        }
        guard let data,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema_version == 1, manifest.project_id == projectID,
              manifest.images.count <= 1_000 else { return [:] }

        var result: [String: Entry] = [:]
        for entry in manifest.images {
            guard entry.target_id.range(of: "^[A-Za-z0-9_-]{3,160}$",
                                        options: .regularExpression) != nil,
                  entry.revision >= 0, !entry.explanation.isEmpty,
                  !entry.explained_at.isEmpty, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }),
                  let url = URL(string: entry.image_url),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == siteHost,
                  url.path.hasPrefix("/images/ttendencias/" + entry.target_id
                      + "-r" + String(entry.revision) + "-"),
                  url.path.hasSuffix(".png"),
                  url.lastPathComponent.contains(String(entry.sha256.prefix(12))),
                  url.query == nil, url.fragment == nil else { continue }
            let identity = key(id: entry.target_id, revision: entry.revision)
            // First matching record wins; never switch assets by ranking/name.
            if result[identity] == nil { result[identity] = entry }
        }
        // Only persist a validated, network-received manifest. Cached fallback
        // remains usable during a temporary GitHub outage.
        if let saved = try? Data(contentsOf: disk), saved == data {
            // Already cached; nothing to write.
        } else if !result.isEmpty {
            try? data.write(to: disk, options: .atomic)
        }
        await memory.store(result)
        return result
    }

    static func resolved(id: String, revision: Int, explanation: String,
                         explainedAt: String, catalog: [String: Entry]) -> URL? {
        guard !id.isEmpty, !explanation.isEmpty, !explainedAt.isEmpty,
              let record = catalog[key(id: id, revision: revision)],
              record.explanation == explanation,
              record.explained_at == explainedAt else { return nil }
        return URL(string: record.image_url)
    }
}

private actor SiteAIImageMemory {
    private var last: [String: SiteAIImageCatalog.Entry]?
    private var at = Date.distantPast

    func fresh() -> [String: SiteAIImageCatalog.Entry]? {
        guard Date().timeIntervalSince(at) < 90 else { return nil }
        return last
    }

    func store(_ value: [String: SiteAIImageCatalog.Entry]) {
        last = value
        at = Date()
    }
}
