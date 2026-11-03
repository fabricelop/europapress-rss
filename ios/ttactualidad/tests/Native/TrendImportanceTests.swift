import XCTest

final class TrendImportanceTests: XCTestCase {
    func testCanonicalNameSurvivesRankAndAccentChangesWithoutDroppingHashtag() throws {
        XCTAssertEqual(TrendImportance.key("  JESÚS   de Miguel "), "jesus de miguel")
        XCTAssertNotEqual(TrendImportance.key("#Tema"), TrendImportance.key("Tema"))
    }
    func testFeedOnlyIncludesDeliberateTrueFlags() throws {
        let data = Data(#"{"schema_version":1,"project":"ttendencias","items":[{"name":"Paola","important":true},{"name":"Kico","important":false}]}"#.utf8)
        XCTAssertEqual(try TrendImportance.names(from:data), Set(["paola"]))
    }
    func testUnmarkAndExactReceiptAreConfirmed() throws {
        let data = Data(#"{"schema_version":1,"project":"ttendencias","item":{"name":"Paola","important":false}}"#.utf8)
        XCTAssertTrue(try TrendImportance.confirms(data,name:"Paola",important:false))
        XCTAssertFalse(try TrendImportance.confirms(data,name:"Kico",important:false))
        XCTAssertFalse(try TrendImportance.confirms(data,name:"Paola",important:true))
    }
    func testWrongProjectOrMalformedFlagCannotReplaceSavedState() throws {
        let bad = Data(#"{"schema_version":1,"project":"ttittulares","items":[]}"#.utf8)
        XCTAssertThrowsError(try TrendImportance.names(from:bad))
        let invalid = Data(#"{"schema_version":1,"project":"ttendencias","items":[{"name":"Paola","important":"true"}]}"#.utf8)
        XCTAssertThrowsError(try TrendImportance.names(from:invalid))
    }
}
