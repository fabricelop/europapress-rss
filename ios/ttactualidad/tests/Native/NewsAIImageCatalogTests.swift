import XCTest
import Foundation

/// News art never leaks from a related headline or a different revision.
/// No network requests or image generation are performed by these tests.
final class NewsAIImageCatalogTests: XCTestCase {
    private let id = "a79e3b9ef206"
    private let text = "Noticia comprobada.\n\n#Actualidad #Zamora\n🌶️ Remate editorial."
    private let preparedAt = "2026-11-01T15:51:20.476557Z"
    private let sha = String(repeating: "a", count: 64)

    private func entry(revision: Int = 1, editorialText: String? = nil,
                       prepared: String? = nil, url: String? = nil)
        -> NewsAIImageCatalog.Entry {
        NewsAIImageCatalog.Entry(
            target_id: id, revision: revision, prepared_at: prepared ?? preparedAt,
            editorial_text: editorialText ?? text,
            image_url: url ?? "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttittulares/\(id)-r\(revision)-\(sha.prefix(12)).png",
            sha256: sha)
    }

    func testExactIdentityAndTimestampResolve() {
        let original = entry()
        let result = NewsAIImageCatalog.assigned(
            id: id, revision: 1, editorialText: text, preparedAt: preparedAt,
            catalog: ["\(id):r1": original])
        XCTAssertEqual(result?.url.absoluteString, original.image_url)
        XCTAssertEqual(result?.sha256, sha)
    }

    func testStableNewsIdKeepsArtworkWhenTextRevisionChanges() {
        let original = entry()
        let catalog = ["\(id):r1": original]
        XCTAssertNil(NewsAIImageCatalog.assigned(
            id: "othernews", revision: 2, editorialText: text,
            preparedAt: preparedAt, catalog: catalog))
        // Same stable event_id: the original illustration remains attached.
        XCTAssertEqual(NewsAIImageCatalog.assigned(
            id: id, revision: 2, editorialText: text + " Nueva información.",
            preparedAt: "2026-11-02T12:00:00Z", catalog: catalog)?.url.absoluteString,
            original.image_url)
        // A newly verified image for r2 takes precedence over the previous art.
        let updated = entry(revision: 2,
                            editorialText: text + " Nueva información.",
                            prepared: "2026-11-02T12:00:00Z")
        let newer = ["\(id):r1": original, "\(id):r2": updated]
        XCTAssertEqual(NewsAIImageCatalog.assigned(
            id: id, revision: 2, editorialText: updated.editorial_text,
            preparedAt: updated.prepared_at, catalog: newer)?.url.absoluteString,
            updated.image_url)
        // A current-revision record with mismatched exact text is NOT trusted.
        XCTAssertNil(NewsAIImageCatalog.assigned(
            id: id, revision: 2, editorialText: "Different content",
            preparedAt: updated.prepared_at, catalog: newer))
        XCTAssertNil(NewsAIImageCatalog.assigned(
            id: id, revision: 1, editorialText: text + " other",
            preparedAt: preparedAt, catalog: catalog))
    }

    func testManualGitHubPNGAssignmentRequiresSHAInFilename() {
        let valid = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/\(id)-r1-manual-\(sha.prefix(12)).png"
        XCTAssertNotNil(NewsAIImageCatalog.assigned(
            id: id, revision: 1, editorialText: text,
            preparedAt: preparedAt, catalog: ["\(id):r1": entry(url: valid)]))
        let wrong = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/othernews-r1-manual-\(sha.prefix(12)).png"
        XCTAssertNil(NewsAIImageCatalog.assigned(
            id: id, revision: 1, editorialText: text,
            preparedAt: preparedAt, catalog: ["\(id):r1": entry(url: wrong)]))
    }

    func testVerifiedTTImagesPipelineManifestPersistsWithStableNewsID() {
        let url = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/\(id)-r1-ai1.jpg"
        let original = entry(url: url)
        XCTAssertEqual(NewsAIImageCatalog.assigned(
            id: id, revision: 1, editorialText: text,
            preparedAt: preparedAt, catalog: ["\(id):r1": original])?.url.absoluteString,
            url)
        XCTAssertEqual(NewsAIImageCatalog.assigned(
            id: id, revision: 2, editorialText: text + " nueva revisión",
            preparedAt: "2026-11-02T12:00:00Z", catalog: ["\(id):r1": original])?.url.absoluteString,
            url)
        XCTAssertNil(NewsAIImageCatalog.assigned(
            id: "unrelated", revision: 2, editorialText: text,
            preparedAt: preparedAt, catalog: ["\(id):r1": original]))
    }

    func testOnlyPipelineVerifiedAIImageCanAppearAutomatically() {
        let imageURL = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/\(id)-r1-ai1.jpg"
        let ai: [String: Any] = [
            "generated": true, "provider": "chat-imagegen", "sha256": sha,
            "url": imageURL,
            "context_guard": ["event_id": id, "revision": 1]]
        let valid: [String: Any] = [
            "ai_image_status": "ready", "ai_image": ai]
        XCTAssertEqual(NewsAIImageCatalog.preparedImage(
            id: id, revision: 1, item: valid)?.url.absoluteString, imageURL)
        XCTAssertNil(NewsAIImageCatalog.preparedImage(
            id: id, revision: 2, item: valid))
        XCTAssertNil(NewsAIImageCatalog.preparedImage(
            id: id, revision: 1, item: ["ai_image_status": "failed", "ai_image": ai]))
        var fake = ai
        fake["provider"] = "unverified-provider"
        XCTAssertNil(NewsAIImageCatalog.preparedImage(
            id: id, revision: 1, item: ["ai_image_status": "ready", "ai_image": fake]))
    }
}
