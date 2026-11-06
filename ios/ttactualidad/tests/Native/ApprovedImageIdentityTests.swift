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
    func testHistoricalManualTrendRetainsExactEpisodeIdentity() {
        let text = "Texto de tendencia archivada que ya no está en Listas."
        let date = "2026-10-27T12:00:00Z"
        let image = SiteAIImageCatalog.Entry(target_id: "archived-trend", revision: 0,
            explained_at: date, explanation: text,
            image_url: "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/archived-trend-r0-manual-aaaaaaaaaaaa.png",
            sha256: sha)
        let data = ["archived-trend:r0": image]
        XCTAssertNotNil(SiteAIImageCatalog.resolved(id: "archived-trend", revision: 0,
            explanation: text, explainedAt: date, catalog: data))
        XCTAssertNil(SiteAIImageCatalog.resolved(id: "another-trend", revision: 0,
            explanation: text, explainedAt: date, catalog: data))
        XCTAssertNil(SiteAIImageCatalog.resolved(id: "archived-trend", revision: 1,
            explanation: text, explainedAt: date, catalog: data))
        XCTAssertNil(SiteAIImageCatalog.resolved(id: "archived-trend", revision: 0,
            explanation: "Otro suceso", explainedAt: date, catalog: data))
    }

    func testHistoricalManualNewsRetainsExactRevision() {
        let image = NewsAIImageCatalog.Entry(target_id: "archived-news", revision: 2,
            prepared_at: "2026-10-25T11:00:00Z", editorial_text: "Noticia archivada",
            image_url: "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/archived-news-r2-manual-aaaaaaaaaaaa.png",
            sha256: sha)
        let data = ["archived-news:r2": image]
        XCTAssertNotNil(NewsAIImageCatalog.assigned(id: "archived-news", revision: 2,
            editorialText: "Noticia archivada", preparedAt: image.prepared_at, catalog: data))
        XCTAssertNil(NewsAIImageCatalog.assigned(id: "unrelated-news", revision: 2,
            editorialText: "Noticia archivada", preparedAt: image.prepared_at, catalog: data))
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
