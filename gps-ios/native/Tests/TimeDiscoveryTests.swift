import XCTest
@testable import MiMapaDelTiempo

final class TimeDiscoveryTests:XCTestCase {
    private func interval(_ start:TimeInterval,_ end:TimeInterval,
                          row:Int = 1000,col:Int = 200)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
                         end:Date(timeIntervalSince1970:end),
                         cell:Cell(row:row,column:col),
                         quality:"observado",source:"prueba")
    }
    func testWhereWasIClipsRangeWithoutChangingOriginal() {
        let original=[interval(10,60)]
        let found=TimeWhereWasIIndex.slices(original,
            from:Date(timeIntervalSince1970:20),to:Date(timeIntervalSince1970:40))
        XCTAssertEqual(found.count,1)
        XCTAssertEqual(found.first?.seconds,20)
        XCTAssertEqual(original.first?.seconds,50)
    }
    func testWhereWasIInvalidIntervalHasNoResult() {
        let t=Date(timeIntervalSince1970:80)
        XCTAssertTrue(TimeWhereWasIIndex.slices([interval(10,70)],from:t,to:t).isEmpty)
    }
    func testWhereWasIPreservesUnlocatedGap() {
        let pieces=[interval(0,20),interval(70,80)]
        let found=TimeWhereWasIIndex.slices(pieces,
            from:Date(timeIntervalSince1970:0),to:Date(timeIntervalSince1970:100))
        XCTAssertEqual(found.reduce(0){$0+$1.seconds},30)
    }
    func testMilestonesHaveThresholdAndNoFakeUnlock() {
        let r=TimeMilestones.calculate(cells:1,zones:0,cities:0,countries:0,hours:0)
        XCTAssertEqual(r.filter(\.reached).count,0)
        XCTAssertTrue(r.contains(where:{$0.title=="10 cuadrículas" && $0.target==10}))
    }
}
