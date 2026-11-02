import XCTest

final class EditorialActionPolicyTests: XCTestCase {
    func testCluesAndFreshRewriteTrackTheNewRevision() {
        XCTAssertEqual(EditorialActionPolicy.targetRevision(decision: "hints", current: 4), 5)
        XCTAssertEqual(EditorialActionPolicy.targetRevision(decision: "rework", current: 4), 5)
        XCTAssertEqual(EditorialActionPolicy.targetRevision(decision: "prepare", current: 4), 4)
    }

    func testCopiesOnlyTheExplicitlySelectedImageSource() {
        let archive = URL(string: "https://example.org/archive.jpg")!
        let ai = URL(string: "https://example.org/original.png")!
        XCTAssertEqual(EditorialActionPolicy.imageURL(ai: false, archive: archive, generated: ai), archive)
        XCTAssertEqual(EditorialActionPolicy.imageURL(ai: true, archive: archive, generated: ai), ai)
        XCTAssertNil(EditorialActionPolicy.imageURL(ai: true, archive: archive, generated: nil))
        XCTAssertNil(EditorialActionPolicy.imageURL(ai: false, archive: nil, generated: ai))
    }

    func testImagesPromptNeverIncludesTheProjectAssociationInstructions() {
        XCTAssertEqual(EditorialActionPolicy.prompt(visual: "HECHOS Y DIRECCIÓN VISUAL", association: "ASOCIAR ESTE ORIGINAL", associate: false), "HECHOS Y DIRECCIÓN VISUAL")
        XCTAssertEqual(EditorialActionPolicy.prompt(visual: "VISUAL", association: "ASOCIAR ESTE ORIGINAL", associate: true), "VISUAL\n\nASOCIAR ESTE ORIGINAL")
    }
    func testXPayloadAppendsExactlyOneSectionLinkForEachProject() {
        let text = "Noticia comprobada.\n\n#Actualidad\n🌶️ Remate."
        for news in [true, false] {
            let site = news ? TTActualidadXPost.newsURL : TTActualidadXPost.trendsURL
            let payload = TTActualidadXPost.payload(editorial: text, news: news)
            XCTAssertEqual(payload, text + "\n\n" + site)
            XCTAssertEqual(TTActualidadXPost.payload(
                editorial: text + "\n\n" + site, news: news), payload)
            XCTAssertEqual(payload.components(separatedBy: site).count, 2)
        }
    }

    func testXPayloadReservesTcoWeightAndPreservesHashtagsAndRemate() {
        let text = String(repeating: "a", count: 270)
        for news in [true, false] {
            let site = news ? TTActualidadXPost.newsURL : TTActualidadXPost.trendsURL
            let payload = TTActualidadXPost.payload(editorial: text, news: news)
            XCTAssertTrue(payload.hasSuffix("\n\n" + site))
            let editorial = String(payload.dropLast(site.count + 2))
            XCTAssertLessThanOrEqual(TTActualidadXPost.weight(editorial) + 2 + 23, 280)
            XCTAssertTrue(editorial.hasSuffix("…"))
        }
        let long = String(repeating: "a", count: 300) + "\n\n#Tema\n🌶️ Remate."
        let result = TTActualidadXPost.payload(editorial: long, news: true)
        XCTAssertTrue(result.hasSuffix("#Tema\n🌶️ Remate.\n\n" + TTActualidadXPost.newsURL))
        let editorial = String(result.dropLast(TTActualidadXPost.newsURL.count + 2))
        XCTAssertLessThanOrEqual(TTActualidadXPost.weight(editorial) + 2 + 23, 280)
    }

    func testXPayloadDoesNotMutateEditorialUrlsOtherThanDuplicateSectionSuffix() {
        let text = "Consulta https://example.com/prueba y la noticia."
        let payload = TTActualidadXPost.payload(editorial: text, news: false)
        XCTAssertEqual(payload, text + "\n\n" + TTActualidadXPost.trendsURL)
    }
}
