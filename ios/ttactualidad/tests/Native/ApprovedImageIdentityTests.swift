import XCTest

final class ApprovedImageIdentityTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)
    func testApprovedTrendCannotCarryAcrossRevisionOrDate() {
        let text = "Texto editorial suficientemente largo para probar que ni una corrección pequeña permite reutilizar una aprobación antigua."
        var image = SiteAIImageCatalog.Entry(target_id: "trend-abc", revision: 1,
            explained_at: "2026-11-02T12:00:00Z", explanation: text,
            image_url: "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/trend-abc-r1-aaaaaaaaaaaa.png", sha256: sha)
        image.approval_id = String(repeating: "b", count: 64)
        let catalog = ["trend-abc:r1": image]
        XCTAssertNotNil(SiteAIImageCatalog.resolved(id: "trend-abc", revision: 1,
            explanation: text, explainedAt: image.explained_at, catalog: catalog))
        XCTAssertNil(SiteAIImageCatalog.resolved(id: "trend-abc", revision: 1,
            explanation: text, explainedAt: "2026-11-03T12:00:00Z", catalog: catalog))
        XCTAssertNil(SiteAIImageCatalog.resolved(id: "trend-abc", revision: 2,
            explanation: text + ".", explainedAt: image.explained_at, catalog: catalog))
    }
    @MainActor
    func testNoApprovalPostAfterFritzWasDeletedWhileImageWasPending() {
        let records: [[String: Any]] = [[
            "id": "4d9e4930d09c", "revision": 0, "status": "deleted",
            "updated_at": "2026-11-04T20:04:12.549166+00:00"
        ]]
        XCTAssertTrue(GitHubEditor.imageApprovalBlockedByClosure(
            project: "ttendencias", editorialID: "4d9e4930d09c", revision: 0,
            imageCreatedAt: "2026-11-04T19:58:00Z", records: records))
        XCTAssertFalse(GitHubEditor.imageApprovalBlockedByClosure(
            project: "ttendencias", editorialID: "another-trend", revision: 0,
            imageCreatedAt: "2026-11-04T19:58:00Z", records: records))
        XCTAssertFalse(GitHubEditor.imageApprovalBlockedByClosure(
            project: "ttendencias", editorialID: "4d9e4930d09c", revision: 1,
            imageCreatedAt: "2026-11-04T19:58:00Z", records: records))
        XCTAssertFalse(GitHubEditor.imageApprovalBlockedByClosure(
            project: "ttendencias", editorialID: "4d9e4930d09c", revision: 0,
            imageCreatedAt: "2026-11-04T20:20:00Z", records: records))
    }

    func testApprovedNewsRequiresLiteralTextDateAndRevision() {
        var image = NewsAIImageCatalog.Entry(target_id: "news-abc", revision: 1,
            prepared_at: "2026-11-02T12:00:00Z", editorial_text: "Texto exacto",
            image_url: "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttittulares/news-abc-r1-aaaaaaaaaaaa.png", sha256: sha)
        image.approval_id = String(repeating: "b", count: 64)
        let catalog = ["news-abc:r1": image]
        XCTAssertNotNil(NewsAIImageCatalog.assigned(id: "news-abc", revision: 1,
            editorialText: "Texto exacto", preparedAt: image.prepared_at, catalog: catalog))
        XCTAssertNil(NewsAIImageCatalog.assigned(id: "news-abc", revision: 1,
            editorialText: "Texto cambiado", preparedAt: image.prepared_at, catalog: catalog))
        XCTAssertNil(NewsAIImageCatalog.assigned(id: "news-abc", revision: 1,
            editorialText: "Texto exacto", preparedAt: "2026-11-03T12:00:00Z", catalog: catalog))
        XCTAssertNil(NewsAIImageCatalog.assigned(id: "news-abc", revision: 2,
            editorialText: "Texto exacto", preparedAt: image.prepared_at, catalog: catalog))
    }
}
