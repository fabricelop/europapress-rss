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

    static func resolvedSHA256(id: String, revision: Int, explanation: String,
                               explainedAt: String, catalog: [String: Entry]) -> String? {
        continuityAwareEntry(id: id, revision: revision, explanation: explanation,
                             explainedAt: explainedAt, catalog: catalog)?.sha256
    }

    // An editorial re-explanation can assign a new ID to effectively the SAME
    // story. Its already-stored PNG must not vanish from the UI just because
    // the text gained a filler word. This is display-only visual continuity:
    // it does not claim Site verified a new association or copy any file.
    // Never use name-only matches, other stories or sensitive incidents.
    private static let disallowedContinuityTopics = [
        "accidente", "falleci", "muert", "victima", "herid",
        "asesinat", "atentad", "violacion", "suicid", "desaparecid"
    ]

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "es_ES"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func moment(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    private struct ContinuityParts {
        let topic: [String]
        let tags: [String]
        let closer: [String]
        let tokens: Set<String>
    }

    private static func continuityParts(_ value: String) -> ContinuityParts? {
        let lines = value.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let heading = words(first)
        guard heading.count >= 8, heading[0] == "tt",
              Int(heading[1]) != nil else { return nil }
        let tags = lines.filter { $0.hasPrefix("#") }.map { words($0).joined(separator: " ") }.sorted()
        let closer = lines.filter { $0.hasPrefix("🌶") }.map { words($0).joined(separator: " ") }.sorted()
        let tokens = Set(words(value))
        let lower = words(value).joined(separator: " ")
        guard !tags.isEmpty, !closer.isEmpty, tokens.count >= 24,
              !disallowedContinuityTopics.contains(where: { lower.contains($0) }) else {
            return nil
        }
        return ContinuityParts(topic: Array(heading.dropFirst(2).prefix(4)),
                               tags: tags, closer: closer, tokens: tokens)
    }

    private static func continuityAwareEntry(id: String, revision: Int,
                                              explanation: String, explainedAt: String,
                                              catalog: [String: Entry]) -> Entry? {
        guard !id.isEmpty, !explanation.isEmpty, !explainedAt.isEmpty else { return nil }
        if let record = catalog[key(id: id, revision: revision)],
           record.explanation == explanation, record.explained_at == explainedAt {
            return record // Current exact association always wins.
        }
        guard let targetDate = moment(explainedAt),
              let target = continuityParts(explanation) else { return nil }
        var matches: [(Date, Entry)] = []
        for old in catalog.values where old.revision == revision {
            guard let oldDate = moment(old.explained_at) else { continue }
            let delta = targetDate.timeIntervalSince(oldDate)
            guard delta >= 0, delta <= 12 * 3600,
                  let previous = continuityParts(old.explanation),
                  previous.topic == target.topic,
                  previous.tags == target.tags,
                  previous.closer == target.closer else { continue }
            let overlap = target.tokens.intersection(previous.tokens).count
            let union = target.tokens.union(previous.tokens).count
            guard union > 0, Double(overlap) / Double(union) >= 0.96 else { continue }
            matches.append((oldDate, old))
        }
        matches.sort { $0.0 > $1.0 }
        guard let first = matches.first,
              matches.count == 1 || matches[1].0 != first.0 else { return nil }
        return first.1
    }

    // A verified remote deletion must not be undone by a 90-second memory
    // cache or an older disk manifest when the next refresh is offline.
    static func invalidateCache() async {
        await memory.invalidate()
        let disk = FileManager.default.urls(for: .cachesDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("ttactualidad-site-ai-index.json")
        try? FileManager.default.removeItem(at: disk)
    }

    static func resolved(id: String, revision: Int, explanation: String,
                         explainedAt: String, catalog: [String: Entry]) -> URL? {
        guard let record = continuityAwareEntry(
            id: id, revision: revision, explanation: explanation,
            explainedAt: explainedAt, catalog: catalog
        ) else { return nil }
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

    func invalidate() {
        last = nil
        at = .distantPast
    }
}
