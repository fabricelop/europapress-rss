import Foundation

/// Only user-approved originals are exposed here; pending images require editor authentication.
enum ApprovedImageFeed {
    static func merge(_ legacy: Data?, project: String) async -> Data? {
        let disk = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tt-approved-" + project + ".json")
        var approved: Data?
        do {
            guard let base = Bundle.main.object(forInfoDictionaryKey: "TTImageApprovalAPIBaseURL") as? String,
                  let url = URL(string: base + "/catalog?project=" + project),
                  url.scheme == "https", url.host == "ttactualidad.rainyraven22.chatgpt.site"
            else { return legacy }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["schema_version"] as? Int == 1,
                  value["project"] as? String == project,
                  value["project_id"] as? String == "appgprj_6ae4dcf7d7488191a574e5b649e67370",
                  let rows = value["images"] as? [[String: Any]], rows.count <= 1000,
                  rows.allSatisfy({ ($0["approval_id"] as? String)?.count == 64 })
            else { throw URLError(.badServerResponse) }
            approved = data
            try? data.write(to: disk, options: .atomic)
        } catch { approved = try? Data(contentsOf: disk) }
        guard let approved,
              let fresh = try? JSONSerialization.jsonObject(with: approved) as? [String: Any],
              let rows = fresh["images"] as? [[String: Any]] else { return legacy }
        var manifest = legacy.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [
            "schema_version": 1, "project": project,
            "project_id": "appgprj_6ae4dcf7d7488191a574e5b649e67370"
        ]
        let old = manifest["images"] as? [[String: Any]] ?? []
        manifest["images"] = rows + old.filter { $0["approval_id"] == nil }
        return try? JSONSerialization.data(withJSONObject: manifest)
    }
}
