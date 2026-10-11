import XCTest
@testable import MiMapaDelTiempo

final class TimeV07Tests: XCTestCase {
    private func item(_ start:TimeInterval,_ end:TimeInterval,
                      _ cell:Cell) -> AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:1_000_000+start),
                         end:Date(timeIntervalSince1970:1_000_000+end),
                         cell:cell,quality:"observado",source:"test")
    }

    func testMontevalleOverlapDoesNotInflateEitherCellOrPlace() {
        let first=Cell(row:101,column:201),second=Cell(row:101,column:202)
        // Reproduce el defecto del JSON: los totales antiguos contenían
        // 161 segundos duplicados dentro de una sola cuadrícula.
        let original=[
            item(0,8000,first),
            item(100,261,first),
            item(8000,8075,second)
        ]
        let byCell=TimeAttribution.byCell(original)
        XCTAssertEqual(byCell[first.id],8000)
        XCTAssertEqual(byCell[second.id],75)
        let together=TimeAttribution.totals(original,cellIDs:[first.id,second.id])
        XCTAssertEqual(together,8075,accuracy:0.001)
        XCTAssertEqual(byCell.values.reduce(0,+),together,accuracy:0.001)
        XCTAssertEqual(original.reduce(0){$0+$1.seconds}-together,161,accuracy:0.001)
    }

    func testPeriodComparisonUsesSameCanonicalProjection() {
        let first=Cell(row:101,column:201),second=Cell(row:101,column:202)
        let original=[item(0,8000,first),item(100,261,first),item(8000,8075,second)]
        let actual=TimeAnalytics.totals(original,
                              from:Date(timeIntervalSince1970:1_000_000),
                              to:Date(timeIntervalSince1970:1_008_075))
        let expected=TimeAttribution.byCell(original)
        XCTAssertEqual(actual[first.id],expected[first.id])
        XCTAssertEqual(actual[second.id],expected[second.id])
    }

    func testOverlapsDoNotMutateOriginalIntervals() {
        let first=Cell(row:101,column:201)
        let original=[item(0,100,first),item(10,50,first)]
        let encodedBefore=try? JSONEncoder().encode(original)
        _ = TimeAttribution.byCell(original)
        _ = TimeAttribution.canonical(original)
        XCTAssertEqual(try? JSONEncoder().encode(original),encodedBefore)
    }

    func testOnePlaceWithTwoCellsRetainsSeparateVisitHistory() {
        let a=Cell(row:101,column:201),b=Cell(row:101,column:202)
        let intervals=[item(0,60,a),item(60,120,b)]
        let placeSeconds=TimeAttribution.totals(intervals,cellIDs:[a.id,b.id])
        let aSeconds=TimeAttribution.totals(intervals,cellIDs:[a.id])
        let bSeconds=TimeAttribution.totals(intervals,cellIDs:[b.id])
        XCTAssertEqual(placeSeconds,aSeconds+bSeconds,accuracy:0.001)
        XCTAssertEqual(TimeVisitIndex.visits(intervals,cells:[a.id,b.id]).count,1)
    }

    func testProvisionalIsNeverWrittenIntoHistoricalTotal() {
        let cell=Cell(row:101,column:201)
        let original=[item(0,60,cell)]
        XCTAssertEqual(TimeAttribution.byCell(original)[cell.id],60)
        XCTAssertEqual(TimeAttribution.totals(original,cellIDs:[cell.id]),60)
    }
}
