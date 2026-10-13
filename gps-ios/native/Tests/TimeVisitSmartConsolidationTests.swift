import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class TimeVisitSmartConsolidationTests:XCTestCase {
    private let home=Cell(row:150000,column:149000)
    private let away=Cell(row:150000,column:149002)
    private func slice(_ start:Double,_ end:Double,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
            end:Date(timeIntervalSince1970:end),cell:cell,
            quality:"observado",source:"test")
    }
    private func event(_ at:Double,_ cause:String)->GPSPowerEvent {
        GPSPowerEvent(date:Date(timeIntervalSince1970:at),
            mode:"Máxima precisión",cause:cause)
    }
    private func fix(_ at:Double,_ cell:Cell)->GPSPoint {
        let location=Grid.center(cell)
        return GPSPoint(date:Date(timeIntervalSince1970:at),
            latitude:location.latitude,longitude:location.longitude,
            accuracy:8,source:"gps")
    }
    func testMinuteFragmentsAppearAsOneVisitWithoutInventingSeconds() {
        let raw=[slice(100,120,home),slice(130,135,away),slice(135,190,home)]
        let merged=TimeVisitIndex.visits(raw,cells:[home.id])
        XCTAssertEqual(merged.count,1)
        XCTAssertEqual(merged[0].confirmedSeconds,75)
        XCTAssertEqual(merged[0].mergedSessions,2)
        XCTAssertEqual(merged[0].unconfirmedSeconds,15)
    }
    func testKnownExitNeverGetsMergedEvenWhenItTakesSeconds() {
        let raw=[slice(100,120,home),slice(130,135,away),slice(135,190,home)]
        let visits=TimeVisitIndex.visits(raw,cells:[home.id],
            fixes:[fix(132,away)])
        XCTAssertEqual(visits.count,2)
    }
    func testLongInterruptionWithDocumentedStopAndResumeMergesWithoutTime() {
        let raw=[slice(0,120,home),slice(3900,4020,home)]
        let events=[event(130,"Seguimiento detenido"),
                    event(3890,"Inicio GPS continuo · sin pausa automática")]
        let visits=TimeVisitIndex.visits(raw,cells:[home.id],powerEvents:events)
        XCTAssertEqual(visits.count,1)
        XCTAssertTrue(visits[0].hasTrackingPause)
        XCTAssertEqual(visits[0].confirmedSeconds,240)
        XCTAssertEqual(visits[0].unconfirmedSeconds,3780)
    }
    func testLongUnexplainedGapRemainsTwoVisits() {
        let raw=[slice(0,120,home),slice(3900,4020,home)]
        XCTAssertEqual(TimeVisitIndex.visits(raw,cells:[home.id]).count,2)
    }
    func testManualSplitAlwaysWins() {
        let raw=[slice(0,120,home),slice(150,180,home)]
        let visits=TimeVisitIndex.visits(raw,cells:[home.id],
            manualBreaks:[Date(timeIntervalSince1970:135)])
        XCTAssertEqual(visits.count,2)
    }
    func testOutsideIntervalBlocksEvenAcrossTrackingRestart() {
        let raw=[slice(0,120,home),slice(200,400,away),slice(3900,4020,home)]
        let events=[event(410,"Seguimiento detenido"),
                    event(3890,"Inicio GPS continuo")]
        let visits=TimeVisitIndex.visits(raw,cells:[home.id],powerEvents:events)
        XCTAssertEqual(visits.count,2)
    }
    func testNoPresenceAssignedToEmptyMiddleDay() {
        let first=Date(timeIntervalSince1970:100*86400)
        let start=first.addingTimeInterval(86400-100)
        let end=first.addingTimeInterval(86400+10*3600)
        let raw=[
            AssignedInterval(start:start,end:start.addingTimeInterval(30),
                cell:home,quality:"observado",source:"test"),
            AssignedInterval(start:end,end:end.addingTimeInterval(30),
                cell:home,quality:"observado",source:"test")
        ]
        let events=[GPSPowerEvent(date:start.addingTimeInterval(45),
                           mode:"Máxima precisión",cause:"Seguimiento detenido"),
                    GPSPowerEvent(date:end.addingTimeInterval(-30),
                           mode:"Máxima precisión",cause:"Inicio GPS continuo")]
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let visits=TimeVisitIndex.visits(raw,cells:[home.id],powerEvents:events)
        XCTAssertEqual(visits.count,1)
        let days=TimeVisitIndex.daily(visits,calendar:calendar)
        XCTAssertEqual(days.reduce(0){$0+$1.seconds},60)
        XCTAssertEqual(days.count,2)
    }
    func testDayBasedClock() {
        XCTAssertEqual(TimeMapCardClock.display(32*3600+45*60+56),"1d 8h 45min")
        XCTAssertEqual(TimeMapCardClock.display(24*3600),"1d")
        XCTAssertEqual(TimeMapCardClock.display(3599),"00:59:59")
    }
}
