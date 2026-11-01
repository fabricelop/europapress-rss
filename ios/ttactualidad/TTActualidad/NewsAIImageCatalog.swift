import Foundation

/// Exact, read-only AI image assignments for TTiTTulares READY news.
/// The image is never selected by title, similarity, rank, or filename alone.
enum NewsAIImageCatalog {
    struct Entry: Decodable {
        let target_id: String
        let revision: Int
        let prepared_at: String
        let editorial_text: String
        let image_url: String
        let sha256: String
    }

    struct ValidatedImage {
        let url: URL
        let sha256: String
    }

    private struct Manifest: Decodable {
        let schema_version: Int
        let project: String
        let images: [Entry]
    }

    private static let memory = NewsAIImageMemory()
    private static let root = "/fabricelop/europapress-rss/main/ttittulares/generated-images/"
    private static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/site-ai-images.json")!

    private static func key(_ id: String, _ revision: Int) -> String {
        id + ":r" + String(revision)
    }

    private static func isSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{3,160}$", options: .regularExpression) != nil
    }

    private static func isRaster(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".jpg") ||
               lower.hasSuffix(".jpeg") || lower.hasSuffix(".webp")
    }

    private static func validAssignedURL(_ value: String, id: String,
                                         revision: Int, sha: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, isRaster(url.lastPathComponent)
        else { return nil }
        let hashPrefix = String(sha.prefix(12)).lowercased()
        let path = url.path
        let site = url.host?.lowercased() ==
            "ttactualidad-tendencias.rainyraven22.chatgpt.site" &&
            path.hasPrefix("/images/ttittulares/" + id + "-r" + String(revision) + "-") &&
            url.lastPathComponent.lowercased().contains(hashPrefix)
        let githubBase = url.host?.lowercased() == "raw.githubusercontent.com"
        let prefix = id + "-r" + String(revision)
        let githubManual = githubBase &&
            path.hasPrefix(root + prefix + "-manual-") &&
            url.lastPathComponent.lowercased().contains(hashPrefix)
        // TTImages-compatible image outbox writes a real SHA-verified original
        // as <event_id>-r<revision>-ai<attempt>.jpg. The SHA is persisted in
        // the authenticated manifest, not repeated in this filename.
        let aiPrefix = prefix + "-ai"
        let filename = url.lastPathComponent
        let aiSuffix = filename.hasPrefix(aiPrefix)
            ? String(filename.dropFirst(aiPrefix.count)) : ""
        let attempt = aiSuffix.prefix(while: { $0.isNumber })
        let extensionPart = String(aiSuffix.dropFirst(attempt.count)).lowercased()
        let githubPipeline = githubBase && path.hasPrefix(root + aiPrefix) &&
            !attempt.isEmpty &&
            [".png", ".jpg", ".jpeg", ".webp"].contains(extensionPart)
        return site || githubManual || githubPipeline ? url : nil
    }

    static func load() async -> [String: Entry] {
        if let cached = await memory.fresh() { return cached }
        let disk = FileManager.default.urls(for: .cachesDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("ttactualidad-news-ai-index-v1.json")
        let data: Data
        var network = false
        do {
            var request = URLRequest(url: manifestURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 12)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (received, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  received.count < 2_000_000 else { throw URLError(.badServerResponse) }
            data = received
            network = true
        } catch {
            guard let saved = try? Data(contentsOf: disk) else { return [:] }
            data = saved
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema_version == 1, manifest.project == "ttittulares",
              manifest.images.count <= 1_000 else { return [:] }
        var result: [String: Entry] = [:]
        for entry in manifest.images {
            guard validID(entry.target_id), entry.revision >= 1,
                  !entry.prepared_at.isEmpty, !entry.editorial_text.isEmpty,
                  isSHA(entry.sha256),
                  validAssignedURL(entry.image_url, id: entry.target_id,
                                   revision: entry.revision, sha: entry.sha256) != nil
            else { continue }
            let identity = key(entry.target_id, entry.revision)
            if result[identity] == nil { result[identity] = entry }
        }
        if network { try? data.write(to: disk, options: .atomic) }
        await memory.store(result)
        return result
    }

    static func assigned(id: String, revision: Int, editorialText: String,
                         preparedAt: String, catalog: [String: Entry]) -> ValidatedImage? {
        guard validID(id), revision >= 1,
              !editorialText.isEmpty, !preparedAt.isEmpty else { return nil }

        // Exact revision has priority. Never mix a stale manifest entry from
        // the same revision with a different editor-approved text or timestamp.
        if let current = catalog[key(id, revision)] {
            guard current.editorial_text == editorialText,
                  current.prepared_at == preparedAt,
                  let url = validAssignedURL(current.image_url, id: id,
                                             revision: revision, sha: current.sha256)
            else { return nil }
            return ValidatedImage(url: url, sha256: current.sha256)
        }

        // TTiTTulares event_id is stable across editorial revisions: a verified
        // original remains attached to that SAME story when its text is edited.
        // Do not use title similarity, other news IDs or a newer revision's art.
        let previous = catalog.values
            .filter { $0.target_id == id && $0.revision >= 1 && $0.revision < revision }
            .sorted { $0.revision > $1.revision }
        for record in previous {
            guard isSHA(record.sha256),
                  let url = validAssignedURL(record.image_url, id: id,
                                             revision: record.revision, sha: record.sha256)
            else { continue }
            return ValidatedImage(url: url, sha256: record.sha256)
        }
        return nil
    }

    /// Already-generated news IA from the existing editorial pipeline.
    /// Only the exact current READY event/revision and generated raster qualify.
    static func preparedImage(id: String, revision: Int,
                              item: [String: Any]) -> ValidatedImage? {
        guard validID(id), revision >= 1,
              (item["ai_image_status"] as? String)?.lowercased() == "ready",
              let ai = item["ai_image"] as? [String: Any],
              ai["generated"] as? Bool == true,
              ai["provider"] as? String == "chat-imagegen",
              let sha = ai["sha256"] as? String, isSHA(sha),
              let raw = ai["url"] as? String,
              let url = URL(string: raw), url.scheme == "https",
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              url.path.hasPrefix(root + id + "-r" + String(revision) + "-ai"),
              isRaster(url.lastPathComponent)
        else { return nil }
        if let guardData = ai["context_guard"] as? [String: Any] {
            guard guardData["event_id"] as? String == id,
                  (guardData["revision"] as? Int) == revision else { return nil }
        }
        return ValidatedImage(url: url, sha256: sha)
    }
}

private actor NewsAIImageMemory {
    private var stored: [String: NewsAIImageCatalog.Entry]?
    private var at = Date.distantPast

    func fresh() -> [String: NewsAIImageCatalog.Entry]? {
        guard Date().timeIntervalSince(at) < 90 else { return nil }
        return stored
    }

    func store(_ value: [String: NewsAIImageCatalog.Entry]) {
        stored = value
        at = Date()
    }
}
