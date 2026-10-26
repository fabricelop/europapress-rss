import Foundation

/// Archive-only image resolver. Never returns generated-images, AI image URLs,
/// ChatGPT Images assets, or TTImages media.
enum ArchivePhotoCatalog {
    private struct GitTree: Decodable {
        struct Node: Decodable { let path: String; let type: String }
        let tree: [Node]
        let truncated: Bool
    }

    /// List genuine archive photos in the public repository. A cached tree
    /// avoids losing the gallery when GitHub is temporarily unavailable.
    static func load() async -> [String: URL] {
        let cached = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ttactualidad-archive-paths.json")
        let endpoint = URL(string: "https://api.github.com/repos/fabricelop/europapress-rss/git/trees/main?recursive=1")!
        var data: Data?
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (received, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let tree = try? JSONDecoder().decode(GitTree.self, from: received),
               !tree.truncated {
                data = received
                try? received.write(to: cached, options: .atomic)
            }
        } catch { /* Recover the last verified archive listing. */ }
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
        return archive
    }

    static func resolved(project: String, id: String, revision: Int,
                         image: URL?, catalog: [String: URL]) -> URL? {
        let key = project + ":" + id + ":r" + String(revision)
        if let known = catalog[key] { return known }
        guard let image, image.scheme?.lowercased() == "https",
              let host = image.host?.lowercased(),
              !host.contains("chatgpt.com"),
              !image.path.lowercased().contains("generated-images"),
              !image.path.lowercased().contains("ai-image"),
              !image.path.lowercased().contains("/images/ai/")
        else { return nil }
        return image
    }
}
