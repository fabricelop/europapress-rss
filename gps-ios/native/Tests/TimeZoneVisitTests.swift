import XCTest
@testable import MiMapaDelTiempo

final class TimeZoneVisitTests:XCTestCase {
    private func segment(_ a:TimeInterval,_ b:TimeInterval,_ cell:Cell) -> AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:a),
                         end:Date(timeIntervalSince1970:b),
                         cell:cell,quality:"observado",source:"gps")
    }
    func testVisitAcrossSeveralCellsOfOneZoneKeepsOriginalStart() {
        let a=Cell(row:40,column:10),b=Cell(row:40,column:11),c=Cell(row:40,column:12)
        let chunks=[segment(100,200,a),segment(200,310,b),segment(310,400,c)]
        let start=TimeZoneVisit.beginning(in:chunks,zoneIDs:[a.id,b.id,c.id],
            recentCell:c,now:Date(timeIntervalSince1970:410),
            fallback:Date(timeIntervalSince1970:310))
        XCTAssertEqual(start,Date(timeIntervalSince1970:100))
    }
    func testLeavingZoneStartsNewStayOnReturn() {
        let a=Cell(row:40,column:10),b=Cell(row:40,column:11),outside=Cell(row:44,column:10)
        let chunks=[segment(100,200,a),segment(200,300,outside),segment(300,350,b)]
        let start=TimeZoneVisit.beginning(in:chunks,zoneIDs:[a.id,b.id],
            recentCell:b,now:Date(timeIntervalSince1970:350),
            fallback:Date(timeIntervalSince1970:300))
        XCTAssertEqual(start,Date(timeIntervalSince1970:300))
    }
    func testMissingGPSGapDoesNotInventContinuousVisit() {
        let a=Cell(row:40,column:10),b=Cell(row:40,column:11)
        let chunks=[segment(100,200,a),segment(600,700,b)]
        let start=TimeZoneVisit.beginning(in:chunks,zoneIDs:[a.id,b.id],
            recentCell:b,now:Date(timeIntervalSince1970:705),
            fallback:Date(timeIntervalSince1970:600))
        XCTAssertEqual(start,Date(timeIntervalSince1970:600))
        XCTAssertEqual(TimeZoneVisit.duration(start:Date(timeIntervalSince1970:600),
            currentFix:Date(timeIntervalSince1970:700),resting:false,
            now:Date(timeIntervalSince1970:1000)),220)
    }
    func testVoluntaryRestKeepsClockRunning() {
        XCTAssertEqual(TimeZoneVisit.duration(start:Date(timeIntervalSince1970:100),
            currentFix:nil,resting:true,now:Date(timeIntervalSince1970:3600)),3500)
    }
    func testNoZoneStayIfThereIsNoStart() {
        XCTAssertEqual(TimeZoneVisit.duration(start:nil,currentFix:nil,
            resting:false,now:Date(timeIntervalSince1970:3600)),0)
    }
}
