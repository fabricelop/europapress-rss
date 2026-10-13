import XCTest
@testable import MiMapaDelTiempo

final class TimeGPSGapRecoveryTests:XCTestCase {
    private let home=Cell(row:148000,column:143000)
    private let other=Cell(row:148000,column:143002)
    private func interval(_ start:Double,_ end:Double,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
            end:Date(timeIntervalSince1970:end),cell:cell,
            quality:"observado",source:"test")
    }
    private func fix(_ time:Double,_ cell:Cell,accuracy:Double=12)->GPSPoint {
        let point=Grid.center(cell)
        return GPSPoint(date:Date(timeIntervalSince1970:time),
            latitude:point.latitude,longitude:point.longitude,
            accuracy:accuracy,source:"gps")
    }
    private func candidates(_ raw:[AssignedInterval],fixes:[GPSPoint],
                            breaks:[Date]=[],events:[GPSPowerEvent]=[])
        ->[TimeGPSGapCandidate] {
        TimeGPSGapRecovery.candidates(intervals:raw,fixes:fixes,
            manualBreaks:breaks,events:events,cells:[home.id])
    }
    func testLongUnobservedStationaryGapRequiresManualReview() {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        let gaps=candidates(raw,fixes:[fix(200,home),fix(3380,home)])
        XCTAssertEqual(gaps.count,1)
        XCTAssertEqual(gaps[0].seconds,3180)
        // Solo detectar el hueco no modifica las sumas GPS.
        XCTAssertEqual(TimeAttribution.totals(raw,cellIDs:[home.id]),220)
    }
    func testDifferentCellCannotBeAttributedWithoutLocationProof() {
        let raw=[interval(100,200,home),interval(3380,3500,other)]
        XCTAssertTrue(candidates(raw,fixes:[fix(200,home),fix(3380,other)]).isEmpty)
    }
    func testNoRecommendationIfTrackingWasExplicitlyStopped() {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        let event=GPSPowerEvent(date:Date(timeIntervalSince1970:1000),
            mode:"Máxima precisión",cause:"Seguimiento detenido")
        XCTAssertTrue(candidates(raw,fixes:[fix(200,home),fix(3380,home)],
                                 events:[event]).isEmpty)
    }
    func testManualBreakPreventsGapRecovery() {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        XCTAssertTrue(candidates(raw,fixes:[fix(200,home),fix(3380,home)],
             breaks:[Date(timeIntervalSince1970:500)]).isEmpty)
    }
    func testReliableEvidenceOutsidePreventsRecovery() {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        XCTAssertTrue(candidates(raw,fixes:[
            fix(200,home),fix(1000,other),fix(3380,home)]).isEmpty)
    }
    func testNoSuggestionWithInaccurateOrMissingAnchors() {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        XCTAssertTrue(candidates(raw,fixes:[
            fix(200,home,accuracy:80),fix(3380,home)]).isEmpty)
        XCTAssertTrue(candidates(raw,fixes:[fix(3380,home)]).isEmpty)
    }
    func testConfirmedGapIsNoLongerOffered() {
        let raw=[interval(100,200,home),
            AssignedInterval(start:Date(timeIntervalSince1970:200),
                end:Date(timeIntervalSince1970:3380),cell:home,
                quality:"asumido · confirmado por usuario",
                source:"confirmacion_usuario"),
            interval(3380,3500,home)]
        XCTAssertTrue(candidates(raw,fixes:[fix(200,home),fix(3380,home)]).isEmpty)
        XCTAssertEqual(TimeAttribution.totals(raw,cellIDs:[home.id]),3400)
    }
}
