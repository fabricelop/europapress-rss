import XCTest

final class EditorialActionPolicyTests: XCTestCase {
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
}
