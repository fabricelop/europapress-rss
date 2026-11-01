import XCTest
import Foundation

/// Regression cases for the verified Site image continuity introduced before 0.4.44.
/// These tests use a local manifest and never contact the Site or generate images.
final class SiteAIContinuityTests: XCTestCase {
    private let original = """
    TT#12 El aeropuerto sigue siendo tendencia por el informe de movilidad     presentado hoy durante la reunión institucional y la publicación     de los últimos datos verificados.
    #Aeropuerto #Actualidad
    🌶️ El despegue también tuvo sus cifras.
    """

    private func entry(id: String = "trendabc", revision: Int = 1,
                       explainedAt: String = "2026-11-01T10:00:00Z",
                       explanation: String? = nil, marker: String = "a")
        -> SiteAIImageCatalog.Entry {
        let sha = String(repeating: marker, count: 64)
        return SiteAIImageCatalog.Entry(
            target_id: id, revision: revision,
            explained_at: explainedAt, explanation: explanation ?? original,
            image_url: "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/\(id)-r\(revision)-\(sha.prefix(12)).png",
            sha256: sha)
    }

    func testMinorUpdateRetainsVerifiedImageWithoutChangingIdentity() {
        let old = entry()
        let edited = original.replacingOccurrences(of: "el informe de movilidad",
                                                    with: "el documento de movilidad")
        let catalog = ["trendabc:r1": old]
        let result = SiteAIImageCatalog.resolved(
            id: "trendabc", revision: 2, explanation: edited,
            explainedAt: "2026-11-01T12:00:00Z", catalog: catalog)
        XCTAssertEqual(result?.absoluteString, old.image_url)
        XCTAssertEqual(SiteAIImageCatalog.resolvedSHA256(
            id: "trendabc", revision: 2, explanation: edited,
            explainedAt: "2026-11-01T12:00:00Z", catalog: catalog), old.sha256)
    }

    func testExactNewRevisionTakesPrecedenceOverOldImage() {
        let old = entry()
        let current = entry(revision: 2, explainedAt: "2026-11-01T12:00:00Z",
                            marker: "b")
        let catalog = ["trendabc:r1": old, "trendabc:r2": current]
        XCTAssertEqual(SiteAIImageCatalog.resolved(
            id: "trendabc", revision: 2, explanation: original,
            explainedAt: current.explained_at, catalog: catalog)?.absoluteString,
                       current.image_url)
    }

    func testChangedHashtagsOrCloserDoNotReuseOldArt() {
        let old = entry()
        let catalog = ["trendabc:r1": old]
        for edited in [
            original.replacingOccurrences(of: "#Actualidad", with: "#OtroTema"),
            original.replacingOccurrences(of: "El despegue también tuvo sus cifras.",
                                          with: "La situación dio un giro inesperado.")
        ] {
            XCTAssertNil(SiteAIImageCatalog.resolved(
                id: "trendabc", revision: 2, explanation: edited,
                explainedAt: "2026-11-01T12:00:00Z", catalog: catalog))
        }
    }

    func testDifferentIdOldRevisionAndStaleTimestampNeverMatch() {
        let old = entry()
        let catalog = ["trendabc:r1": old]
        XCTAssertNil(SiteAIImageCatalog.resolved(
            id: "otherabc", revision: 2, explanation: original,
            explainedAt: "2026-11-01T12:00:00Z", catalog: catalog))
        XCTAssertNil(SiteAIImageCatalog.resolved(
            id: "trendabc", revision: 4, explanation: original,
            explainedAt: "2026-11-01T12:00:00Z", catalog: catalog))
        XCTAssertNil(SiteAIImageCatalog.resolved(
            id: "trendabc", revision: 2, explanation: original,
            explainedAt: "2026-11-05T12:00:00Z", catalog: catalog))
    }
}
