import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class TimeZonePerformanceTests: XCTestCase {
    func testHugeZoneKeepsAllCellsAndContoursInsteadOfBoundingRectangle() {
        let base=Grid.cell(latitude:40.4,longitude:-3.7)
        let ids=(0..<1000).map { n in
            Cell(row:base.row + n / 20,column:base.column + n % 20).id
        }
        let zone=TimeCustomZone(name:"Parque del Retiro",cellIDs:ids)
        let border=TimeZoneOutline.renderSegments(for:zone)
        let paths=TimeZoneOutline.contours(for:zone)
        XCTAssertGreaterThan(border.count,4)
        XCTAssertFalse(paths.isEmpty)
        XCTAssertLessThan(paths.count,150)
        XCTAssertGreaterThan(paths.reduce(0) { $0 + $1.coordinates.count },4)
        XCTAssertEqual(zone.cellIDs.count,1000)
        XCTAssertEqual(zone.cells.count,1000)
    }

    func testSmallZonePreservesPreciseBorders() {
        let a=Cell(row:500,column:500)
        let b=Cell(row:500,column:501)
        let zone=TimeCustomZone(name:"Montevalle",cellIDs:[a.id,b.id])
        XCTAssertEqual(TimeZoneOutline.renderSegments(for:zone).count,
                       TimeZoneOutline.segments(for:zone).count)
    }

    func testNamesKeepZonePriorityWhenOverlapping() {
        let area=TimeCustomZone(name:"Parque del Retiro",
            cellIDs:(0..<100).map { Cell(row:600,column:800+$0).id })
        let selected=Cell(row:600,column:803)
        let small=TimeCustomZone(name:"Zona pequeña",cellIDs:[selected.id])
        XCTAssertEqual(TimeZoneCatalog.primary(for:selected.id,zones:[area,small])?.name,
                       "Zona pequeña")
    }
}
