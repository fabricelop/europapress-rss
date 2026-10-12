import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class TimeLiveVisualizationTests:XCTestCase {
    private func interval(_ start:TimeInterval,_ end:TimeInterval,
                          row:Int,col:Int)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
                         end:Date(timeIntervalSince1970:end),
                         cell:Cell(row:row,column:col),
                         quality:"observado",source:"GPS")
    }
    func testNineCellsNorthAtTopAndCurrentInCenter() {
        let center=Cell(row:100,column:200)
        let sample=[Cell(row:101,column:199).id:3600,
                    center.id:7200,
                    Cell(row:99,column:201).id:900.0]
        let grid=TimeLiveVisualization.neighborhood(center:center,totals:sample)
        XCTAssertEqual(grid.count,9)
        XCTAssertGreaterThan(grid[0],0)
        XCTAssertEqual(grid[4],4)
        XCTAssertGreaterThan(grid[8],0)
        XCTAssertEqual(grid[2],0)
    }
    func testEmptyGridHasNoInventedPresence() {
        let grid=TimeLiveVisualization.neighborhood(
            center:Cell(row:0,column:0),totals:[:])
        XCTAssertEqual(grid,Array(repeating:0,count:9))
    }
    func testSixHoursOnlyCountsSelectedCellAndClipsWindow() {
        let end=Date(timeIntervalSince1970:21600)
        let entries=[interval(0,1800,row:1,col:2),
                     interval(3600,5400,row:1,col:2),
                     interval(10_800,14_400,row:5,col:2),
                     interval(18_000,21_600,row:1,col:2)]
        let bars=TimeLiveVisualization.hourlyPresence(
            intervals:entries,cellIDs:[Cell(row:1,column:2).id],endingAt:end)
        XCTAssertEqual(bars,[50,50,0,0,0,100])
    }
    func testNoPresenceDoesNotFabricateStays() {
        let end=Date(timeIntervalSince1970:21600)
        let bars=TimeLiveVisualization.hourlyPresence(
            intervals:[],cellIDs:[Cell(row:1,column:2).id],endingAt:end)
        XCTAssertEqual(bars,Array(repeating:0,count:6))
    }
    func testClampsPeriodsAcrossBoundary() {
        let end=Date(timeIntervalSince1970:21600)
        let bars=TimeLiveVisualization.hourlyPresence(
            intervals:[interval(-4000,1000,row:1,col:2)],
            cellIDs:[Cell(row:1,column:2).id],endingAt:end)
        XCTAssertEqual(bars[0],28)
        XCTAssertEqual(bars.reduce(0,+),28)
    }
}
