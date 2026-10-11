import XCTest
@testable import MiMapaDelTiempo

final class TimeV06Tests: XCTestCase {
    private let base = Date(timeIntervalSince1970:1_000_000)
    private func cell(_ row:Int,_ col:Int) -> Cell { Cell(row:row,column:col) }
    private func interval(_ start:TimeInterval,_ end:TimeInterval,_ c:Cell) -> AssignedInterval {
        AssignedInterval(start:base.addingTimeInterval(start),
                         end:base.addingTimeInterval(end),cell:c,
                         quality:"observado",source:"test")
    }

    func testManyGpsSegmentsBecomeOneVisit() {
        let a=cell(150000,150000)
        let rows=(0..<500).map { i in interval(Double(i)*5,Double(i+1)*5,a) }
        let visits=TimeVisitIndex.visits(rows,cells:[a.id])
        XCTAssertEqual(visits.count,1)
        XCTAssertEqual(visits[0].confirmedSeconds,2500,accuracy:0.01)
        XCTAssertEqual(visits[0].fragments.count,500)
    }

    func testPassingBetweenCellsOfSameNamedPlaceKeepsOneVisit() {
        let a=cell(150000,150000), b=cell(150000,150001)
        let rows=[interval(0,60,a),interval(60,120,b),interval(120,180,a)]
        XCTAssertEqual(TimeVisitIndex.visits(rows,cells:[a.id,b.id]).count,1)
        XCTAssertEqual(TimeVisitIndex.visits(rows,cells:[a.id]).count,2)
    }

    func testLeavingAndReturningCreatesTwoVisits() {
        let a=cell(150000,150000), b=cell(150000,150010)
        let rows=[interval(0,60,a),interval(60,120,b),interval(120,180,a)]
        XCTAssertEqual(TimeVisitIndex.visits(rows,cells:[a.id]).count,2)
    }

    func testGpsGapIsNotCountedAsConfirmedSeconds() {
        let c=cell(150000,150000)
        let visits=TimeVisitIndex.visits(
            [interval(0,30,c),interval(100,130,c)],cells:[c.id])
        XCTAssertEqual(visits.count,1)
        XCTAssertEqual(visits[0].duration,130)
        XCTAssertEqual(visits[0].confirmedSeconds,60)
    }

    func testLongGapCreatesAnotherVisit() {
        let c=cell(150000,150000)
        XCTAssertEqual(TimeVisitIndex.visits([interval(0,30,c),interval(500,530,c)],
                                             cells:[c.id]).count,2)
    }

    func testDailySegmentsRespectExactSecondsAcrossMidnight() {
        var cal=Calendar(identifier:.gregorian)
        cal.timeZone=TimeZone(secondsFromGMT:0)!
        let midnight=Date(timeIntervalSince1970:86400*22)
        let a=cell(123,456)
        let pieces=[
            AssignedInterval(start:midnight.addingTimeInterval(-70),
                             end:midnight.addingTimeInterval(-10),cell:a,quality:"observado",source:"test"),
            AssignedInterval(start:midnight.addingTimeInterval(10),
                             end:midnight.addingTimeInterval(80),cell:a,quality:"observado",source:"test")]
        let visits=TimeVisitIndex.visits(pieces,cells:[a.id])
        let daily=TimeVisitIndex.daily(visits,calendar:cal)
        XCTAssertEqual(daily.count,2)
        XCTAssertEqual(daily.reduce(0){$0+$1.seconds},130,accuracy:0.01)
    }

    func testOverlappingDataDoesNotInflateQuality() {
        let a=cell(1,2)
        let q=TimeQualitySummary.calculate([interval(0,100,a),interval(80,130,a)],missing:12)
        XCTAssertEqual(q.assigned,130)
        XCTAssertEqual(q.overlapSeconds,20)
        XCTAssertEqual(q.uncertain,12)
    }

    func testSameNameNearMergesAndRemoteAsks() {
        let a=cell(150000,150000)
        let adjacent=cell(150000,150001)
        let remote=cell(150900,151900)
        let named=UserPlace(name:"Montevalle",cellIDs:[a.id])
        switch NamedPlaces.proposal(cell:adjacent,name:"MONTEVALLE",places:[named]) {
        case .assign(let id): XCTAssertEqual(id,named.id)
        default: XCTFail("Quadrículas próximas con nombre igual deben unirse")
        }
        switch NamedPlaces.proposal(cell:remote,name:"Montevalle",places:[named]) {
        case .distant(let id,_,_): XCTAssertEqual(id,named.id)
        default: XCTFail("Un homónimo lejano requiere confirmación")
        }
    }

    func testLegacyNamesCreatePlacesWithoutTouchingTime() {
        let a=cell(150000,150000),b=cell(150000,150001)
        let remote=cell(151800,150000)
        var names=[a.id:"Casa",b.id:"Casa",remote.id:"Casa"]
        var places:[UserPlace]=[]
        NamedPlaces.migrate(names:&names,places:&places)
        XCTAssertEqual(places.count,2)
        XCTAssertEqual(places.map{$0.cellIDs.count}.sorted(),[1,2])
        XCTAssertEqual(names.count,3)
    }

    func testMigrationKeepsOldUserPlaceUUID() {
        let a=cell(150000,150000),b=cell(150000,150001)
        let old=UserPlace(name:"Trabajo",cellIDs:[a.id,b.id])
        var names:[String:String]=[:],places=[old]
        NamedPlaces.migrate(names:&names,places:&places)
        XCTAssertEqual(places.count,1)
        XCTAssertEqual(places[0].id,old.id)
        XCTAssertEqual(names[b.id],"Trabajo")
    }
}
