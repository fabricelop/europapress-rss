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

    /// Resolve the newest verified image for this editorial identity.
    /// A recent earlier revision can be reused ONLY for tiny copy edits.
    /// Exact current-revision images always win.
    private static func matchedEntry(id: String, revision: Int, explanation: String,
                                     explainedAt: String, catalog: [String: Entry]) -> Entry? {
        guard !id.isEmpty, !explanation.isEmpty, !explainedAt.isEmpty else { return nil }
        if let record = catalog[key(id: id, revision: revision)],
           record.explanation == explanation && record.explained_at == explainedAt {
            return record
        }
        // Do not carry art across a new topic, a different editorial ID, old
        // revisions, or a substantially changed text/closer/hashtags.
        guard revision > 0 else { return nil }
        return catalog.values
            .filter { $0.target_id == id && $0.revision < revision &&
                      revision - $0.revision <= 2 &&
                      minorEditorialEdit(old: $0.explanation, new: explanation) &&
                      recentEnough(old: $0.explained_at, new: explainedAt) }
            .max(by: { $0.revision < $1.revision })
    }

    private static func recentEnough(old: String, new: String) -> Bool {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ value: String) -> Date? {
            if let date = iso.date(from: value) { return date }
            iso.formatOptions = [.withInternetDateTime]
            defer { iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
            return iso.date(from: value)
        }
        guard let before = parse(old), let after = parse(new) else { return false }
        return after >= before && after.timeIntervalSince(before) <= 72 * 3600
    }

    private static func minorEditorialEdit(old: String, new: String) -> Bool {
        let a = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.count >= 65, b.count >= 65 else { return false }
        func hashtags(_ value: String) -> Set<String> {
            Set(value.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.hasPrefix("#") }
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) })
        }
        func closer(_ value: String) -> String {
            value.components(separatedBy: .newlines)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("🌶️") })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard hashtags(a) == hashtags(b), closer(a) == closer(b) else { return false }
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let aa = words(a), bb = words(b)
        guard !aa.isEmpty && !bb.isEmpty else { return false }
        var counts: [String: Int] = [:]
        for word in aa { counts[word, default: 0] += 1 }
        var common = 0
        for word in bb {
            if let count = counts[word], count > 0 {
                counts[word] = count - 1
                common += 1
            }
        }
        // Weighted multiset overlap: allow punctuation / tiny editorial copy
        // adjustments but not a changed event, outcome, score or new reporting.
        return Double(2 * common) / Double(aa.count + bb.count) >= 0.91
    }

    static func resolvedSHA256(id: String, revision: Int, explanation: String,
                               explainedAt: String, catalog: [String: Entry]) -> String? {
        matchedEntry(id: id, revision: revision, explanation: explanation,
                     explainedAt: explainedAt, catalog: catalog)?.sha256
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
        guard let record = matchedEntry(id: id, revision: revision,
                                        explanation: explanation,
                                        explainedAt: explainedAt, catalog: catalog) else { return nil }
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
