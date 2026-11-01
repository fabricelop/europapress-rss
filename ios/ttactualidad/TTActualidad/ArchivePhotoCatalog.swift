import Foundation

/// Archive-only image resolver. Never returns generated-images, AI image URLs,
/// ChatGPT Images assets, or TTImages media.
enum ArchivePhotoCatalog {
    private static let memory = ArchivePhotoMemory()

    private struct GitTree: Decodable {
        struct Node: Decodable { let path: String; let type: String }
        let tree: [Node]
        let truncated: Bool
    }

    /// List genuine archive photos in the public repository. A cached tree
    /// avoids losing the gallery when GitHub is temporarily unavailable.
    static func load() async -> [String: URL] {
        // A full recursive repository tree is expensive to deserialize.
        // Reuse the resolved archive map for ten minutes per app session.
        if let fresh = await memory.fresh() { return fresh }
        let cached = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ttactualidad-archive-paths.json")
        let endpoint = URL(string: "https://api.github.com/repos/fabricelop/europapress-rss/git/trees/main?recursive=1")!
        var data: Data?
        // Avoid refetching the entire tree on every foreground/receipt poll.
        // Failures still recover the last verified archive listing.
        let modified = (try? FileManager.default.attributesOfItem(
            atPath: cached.path)[.modificationDate]) as? Date
        if let modified, Date().timeIntervalSince(modified) < 600 {
            data = try? Data(contentsOf: cached)
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if data == nil {
            do {
                let (received, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let tree = try? JSONDecoder().decode(GitTree.self, from: received),
                   !tree.truncated {
                    data = received
                    try? received.write(to: cached, options: .atomic)
                }
            } catch { /* Recover the last verified archive listing. */ }
        }
        if data == nil { data = try? Data(contentsOf: cached) }
        guard let data, let tree = try? JSONDecoder().decode(GitTree.self, from: data),
              !tree.truncated else { return [:] }
        var archive: [String: URL] = [:]
        for node in tree.tree where node.type == "blob" {
            guard (node.path.hasPrefix("trends/archive-images/") ||
                   node.path.hasPrefix("ttittulares/archive-images/")),
                  let name = node.path.split(separator: "/").last.map(String.init),
                  let revisionMark = name.range(of: "-r", options: .backwards),
                  let hyphen = name[revisionMark.upperBound...].firstIndex(of: "-")
            else { continue }
            let eventID = String(name[..<revisionMark.lowerBound])
            let revision = String(name[revisionMark.upperBound..<hyphen])
            guard !eventID.isEmpty, Int(revision) != nil,
                  (name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") ||
                   name.hasSuffix(".png") || name.hasSuffix(".webp")),
                  let url = URL(string: "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" + node.path)
            else { continue }
            let project = node.path.hasPrefix("trends/") ? "ttendencias" : "ttittulares"
            let key = project + ":" + eventID + ":r" + revision
            // The file name is content-addressed. Any file for the exact
            // editorial revision is valid; never guess paths from an ID alone.
            archive[key] = url
        }
        await memory.store(archive)
        return archive
    }

    static func resolved(project: String, id: String, revision: Int,
                         image: URL?, catalog: [String: URL]) -> URL? {
        let prefix = project + ":" + id + ":r"
        if let known = catalog[prefix + String(revision)] { return known }
        // Editorial feeds can contain a valid original that was not copied to
        // GitHub. This is distinct from the AI image.
        if let image, image.scheme?.lowercased() == "https",
           let host = image.host?.lowercased(),
           !host.contains("chatgpt.com"),
           !image.path.lowercased().contains("generated-images"),
           !image.path.lowercased().contains("ai-image"),
           !image.path.lowercased().contains("/images/ai/") {
            return image
        }
        // The event_id of a TTiTTulares article never changes when its
        // editorial revision changes. Retain the last archived real photo
        // from that SAME event instead of silently losing it.
        var bestRevision = -1
        var bestURL: URL?
        for (key, url) in catalog where key.hasPrefix(prefix) {
            guard let old = Int(key.dropFirst(prefix.count)),
                  old <= revision, old > bestRevision else { continue }
            bestRevision = old
            bestURL = url
        }
        return bestURL
    }

}


/// Protects the parsed, archive-only map from unnecessary full-tree parsing
/// while the user switches sections or checks pending editorial operations.
private actor ArchivePhotoMemory {
    private var value: [String: URL]?
    private var createdAt = Date.distantPast

    func fresh() -> [String: URL]? {
        guard Date().timeIntervalSince(createdAt) < 600 else { return nil }
        return value
    }

    func store(_ map: [String: URL]) {
        value = map
        createdAt = Date()
    }
}
