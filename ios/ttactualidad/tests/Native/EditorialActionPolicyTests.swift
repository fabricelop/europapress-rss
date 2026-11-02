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
    func testXPayloadDoesNotAppendPortalLinkForEitherProject() {
        let text = "Noticia comprobada.\n\n#Actualidad\n🌶️ Remate."
        for news in [true, false] {
            XCTAssertEqual(TTActualidadXPost.payload(editorial: text, news: news), text)
        }
        XCTAssertEqual(TTActualidadXPost.payload(editorial: text + "\n\n" + TTActualidadXPost.newsURL, news: true), text)
        XCTAssertEqual(TTActualidadXPost.payload(editorial: text + "\n\n" + TTActualidadXPost.trendsURL, news: false), text)
    }

    func testXPayloadKeepsFull280BudgetAndEditorialSuffix() {
        let text = String(repeating: "a", count: 270)
        XCTAssertEqual(TTActualidadXPost.payload(editorial: text, news: true), text)
        let long = String(repeating: "a", count: 300) + "\n\n#Tema\n🌶️ Remate."
        let result = TTActualidadXPost.payload(editorial: long, news: true)
        XCTAssertLessThanOrEqual(TTActualidadXPost.weight(result), 280)
        XCTAssertTrue(result.hasSuffix("#Tema\n🌶️ Remate."))
    }
}
