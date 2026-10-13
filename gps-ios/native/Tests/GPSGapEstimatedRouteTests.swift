import Foundation
import CoreLocation
import XCTest
@testable import MiMapaDelTiempo

final class GPSGapEstimatedRouteTests:XCTestCase {
    private let home=Cell(row:148000,column:143000)
    private let after=Cell(row:148000,column:143004)

    private func gap(_ start:Double=100,_ end:Double=760)->TimeGPSGapReview {
        TimeGPSGapReview(start:Date(timeIntervalSince1970:start),
            end:Date(timeIntervalSince1970:end),previousCell:home,
            nextCell:after,reliableGPSBefore:true,reliableGPSAfter:true,
            contradictoryGPS:false,trackingWasStopped:false)
    }

    private func plan(_ gap:TimeGPSGapReview,
                      via:[CLLocationCoordinate2D]=[])->GPSGapRoutePlan? {
        GPSGapRoutePlanner.preview(gap:gap,
            endpoints:[Grid.center(home),Grid.center(after)],via:via)
    }

    func testStraightRouteIncludesEveryCrossedGridWithExactTime() throws {
        let target=gap()
        let route=try XCTUnwrap(plan(target))
        XCTAssertGreaterThanOrEqual(route.cells.count,5)
        XCTAssertEqual(route.cells.first,home)
        XCTAssertEqual(route.cells.last,after)
        XCTAssertEqual(route.allocations.first?.start,target.start)
        XCTAssertEqual(route.allocations.last?.end,target.end)
        XCTAssertEqual(route.seconds,target.seconds,accuracy:0.00001)
        XCTAssertEqual(route.allocations.reduce(0) { $0+$1.meters },
            route.distanceMeters,accuracy:0.0001)
        XCTAssertTrue(route.allocations.allSatisfy{$0.seconds>0})
        XCTAssertTrue(route.intervals().allSatisfy{
            $0.source=="recorrido_estimado" &&
            $0.quality.contains("recorrido estimado")
        })
        let uniqueCells=Set(route.cells)
        XCTAssertEqual(uniqueCells.count,route.cells.count)
        XCTAssertTrue(route.cells.contains(where:{
            $0 != home && $0 != after
        }))
    }

    func testWaypointsChangeRouteAndAllowAdditionalIntermediateCells() throws {
        let target=gap()
        let direct=try XCTUnwrap(plan(target))
        let waypoint=CLLocationCoordinate2D(
            latitude:Grid.center(home).latitude + Grid.latitudeStep*3,
            longitude:Grid.center(home).longitude +
                (Grid.center(after).longitude-Grid.center(home).longitude)*0.5)
        let custom=try XCTUnwrap(plan(target,via:[waypoint]))
        XCTAssertGreaterThan(custom.distanceMeters,direct.distanceMeters)
        XCTAssertTrue(custom.cells.contains(where:{$0.row>home.row}))
        XCTAssertEqual(custom.seconds,target.seconds,accuracy:0.0001)
        XCTAssertEqual(custom.allocations.last?.end,target.end)
        XCTAssertEqual(custom.allocations.first?.start,target.start)
    }

    func testLongGapRejectsAutomaticRouteBeyondSafetyLimit() {
        let target=gap(100,100+GPSGapRoutePlanner.maxSeconds+1)
        XCTAssertNil(plan(target))
        XCTAssertGreaterThan(
            gap(100,100+GPSGapRoutePlanner.cautionSeconds+1).seconds,
            GPSGapRoutePlanner.cautionSeconds)
    }

    func testZeroDistanceRejectsRouteAndStationaryCaseUnchanged() {
        let stationary=TimeGPSGapReview(
            start:Date(timeIntervalSince1970:100),
            end:Date(timeIntervalSince1970:800),
            previousCell:home,nextCell:home,
            reliableGPSBefore:true,reliableGPSAfter:true,
            contradictoryGPS:false,trackingWasStopped:false)
        XCTAssertNil(GPSGapRoutePlanner.preview(gap:stationary,
            endpoints:[Grid.center(home),Grid.center(home)],via:[]))
    }

    func testContradictoryFixPreventsRouteEstimate() {
        let target=TimeGPSGapReview(
            start:Date(timeIntervalSince1970:100),
            end:Date(timeIntervalSince1970:760),
            previousCell:home,nextCell:after,
            reliableGPSBefore:true,reliableGPSAfter:true,
            contradictoryGPS:true,trackingWasStopped:false)
        XCTAssertNil(plan(target))
    }

    func testConfirmedRouteLeavesNoGapOnReindexAndPersistsEachCell() throws {
        let target=gap()
        let route=try XCTUnwrap(plan(target))
        let raw:[AssignedInterval]=[
            AssignedInterval(start:Date(timeIntervalSince1970:0),
                end:target.start,cell:home,quality:"observado",source:"gps"),
            AssignedInterval(start:target.end,
                end:Date(timeIntervalSince1970:900),
                cell:after,quality:"observado",source:"gps")
        ]
        let all=raw+route.intervals()
        let openings=TimeGPSGapReviewIndex.scan(intervals:all,fixes:[],events:[])
        XCTAssertTrue(openings.isEmpty)
        XCTAssertEqual(TimeAttribution.totals(all,cellIDs:Set(route.cells.map(\.id))),
            900,accuracy:0.0001)
        let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:d)}
        let db=try TimeSQLiteStore(url:d.appendingPathComponent("map.sqlite"))
        var state=SavedState()
        state.intervals=raw
        state.totals[home.id]=target.start.timeIntervalSince1970
        state.totals[after.id]=140
        try db.replaceAll(state)
        for allocation in route.allocations {
            state.totals[allocation.cell.id,default:0]+=allocation.seconds
        }
        var delta:[String:Double]=[:]
        for allocation in route.allocations {
            delta[allocation.cell.id,default:0]+=allocation.seconds
        }
        try db.append(fixes:[],intervals:route.intervals(),totals:delta,
                      header:TimeStoreHeader(state))
        let loaded=try db.load()
        XCTAssertEqual(loaded.intervals.count,2+route.allocations.count)
        XCTAssertEqual(loaded.totals.values.reduce(0,+),900,accuracy:0.0001)
        XCTAssertTrue(TimeGPSGapReviewIndex.scan(
            intervals:loaded.intervals,fixes:[],events:[]).isEmpty)
    }
}
