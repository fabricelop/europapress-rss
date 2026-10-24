import XCTest
@testable import MiMapaDelTiempo

final class TimeZoneLabelTextTests:XCTestCase {
    func testInitialsIgnoreShortConnectors() {
        XCTAssertEqual(TimeZoneLabelText.initials("Parque del Retiro"),"PR")
        XCTAssertEqual(TimeZoneLabelText.initials("Casa de Mamá"),"CM")
        XCTAssertEqual(TimeZoneLabelText.initials("Polideportivo la Masó"),"PM")
    }
    func testShortAndEmptyNames() {
        XCTAssertEqual(TimeZoneLabelText.initials("SAP España"),"SE")
        XCTAssertEqual(TimeZoneLabelText.initials("Retiro"),"R")
        XCTAssertEqual(TimeZoneLabelText.initials(""),"Z")
    }
    func testLongNamesRemainTiny() {
        XCTAssertEqual(TimeZoneLabelText.initials("Centro Deportivo Municipal La Masó Madrid"),"CDMM")
    }
}
