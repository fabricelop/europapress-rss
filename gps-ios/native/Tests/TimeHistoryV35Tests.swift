import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class TimeHistoryV35Tests:XCTestCase {
    private let home=Cell(row:148000,column:143000)
    private let near=Cell(row:148000,column:143001)
    private func interval(_ a:Double,_ b:Double,_ cell:Cell,
                          quality:String="observado",source:String="gps")->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:a),
                         end:Date(timeIntervalSince1970:b),
                         cell:cell,quality:quality,source:source)
    }
    private func fix(_ time:Double,_ cell:Cell,precision:Double=10)->GPSPoint {
        let center=Grid.center(cell)
        return GPSPoint(date:Date(timeIntervalSince1970:time),
                        latitude:center.latitude,longitude:center.longitude,
                        accuracy:precision,source:"gps")
    }
    func testContinuityAnchorsMergeVisitButDoNotCreditGap() {
        let pieces=[interval(0,300,home),interval(1200,1600,home)]
        let visits=TimeVisitIndex.visits(pieces,cells:[home.id],
            fixes:[fix(299,home),fix(1201,home)])
        XCTAssertEqual(visits.count,1)
        XCTAssertEqual(visits[0].confirmedSeconds,700)
        XCTAssertEqual(visits[0].unconfirmedSeconds,900)
        XCTAssertEqual(visits[0].mergedSessions,2)
    }
    func testUnverifiedHalfHourGapStaysSeparate() {
        let pieces=[interval(0,300,home),interval(1200,1600,home)]
        XCTAssertEqual(TimeVisitIndex.visits(pieces,cells:[home.id]).count,2)
        let contradicted=[fix(299,home),fix(750,near),fix(1201,home)]
        XCTAssertEqual(TimeVisitIndex.visits(pieces,cells:[home.id],
            fixes:contradicted).count,2)
    }
    func testManualSplitWorksEvenInsideLongRecordedSegment() {
        let a=interval(0,7200,home)
        let original=TimeVisitIndex.visits([a],cells:[home.id])
        XCTAssertEqual(original.count,1)
        let split=TimeVisitIndex.visits([a],cells:[home.id],
            manualBreaks:[Date(timeIntervalSince1970:3600)])
        XCTAssertEqual(split.count,2)
        XCTAssertEqual(split[0].confirmedSeconds,3600)
        XCTAssertEqual(split[1].confirmedSeconds,3600)
        XCTAssertEqual(split.reduce(0){$0+$1.confirmedSeconds},7200)
    }
    func testCoverageSeparatesEstimatedAndObservedAndPending() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let day=Date(timeIntervalSince1970:0)
        let intervals=[
            interval(0,3600,home),
            interval(3600,5400,home,
                     quality:"asumido · confirmado por usuario",
                     source:"confirmacion_usuario"),
            interval(5400,7200,near,quality:"reconstruido",source:"gpxtest")
        ]
        let quality=TimeDayCoverageIndex.build(intervals,day:day,
            calendar:calendar,now:Date(timeIntervalSince1970:86400))
        XCTAssertEqual(quality.observed,3600)
        XCTAssertEqual(quality.estimated,1800)
        XCTAssertEqual(quality.reconstructed,1800)
        XCTAssertEqual(quality.pending,86400-7200)
        XCTAssertEqual(quality.coveragePercent,8)
        XCTAssertEqual(TimeDayCoverageIndex.visualBuckets(quality).count,96)
    }
    func testCompactTimelinePreservesQualityWithoutExtraInteractions() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let day=Date(timeIntervalSince1970:0)
        let pieces=[
            interval(0,3600,home),
            interval(3600,5400,home,quality:"asumido",source:"revision_huecos")
        ]
        let summary=TimeDayCoverageIndex.build(pieces,day:day,
            calendar:calendar,now:Date(timeIntervalSince1970:7200))
        let bars=TimeDayCoverageIndex.visualBuckets(summary,count:48)
        XCTAssertEqual(bars.count,48)
        XCTAssertTrue(bars.contains(.observed))
        XCTAssertTrue(bars.contains(.estimated))
        XCTAssertTrue(bars.contains(.pending))
        XCTAssertEqual(summary.covered+summary.pending,summary.dayDuration,
            accuracy:0.0001)
        XCTAssertEqual(summary.coveragePercent,75)
    }
    func testCurrentDayDoesNotCountFutureAsGPSError() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let one=interval(0,1800,home)
        let quality=TimeDayCoverageIndex.build([one],
            day:Date(timeIntervalSince1970:0),
            calendar:calendar,now:Date(timeIntervalSince1970:1800))
        XCTAssertEqual(quality.dayDuration,1800)
        XCTAssertEqual(quality.coveragePercent,100)
        XCTAssertEqual(quality.pending,0)
    }
    func testReassignAndUndoPreserveOriginalGPSIntervals() {
        let a=interval(0,200,home)
        let b=interval(800,1000,near)
        let estimate=interval(200,800,home,
            quality:"asumido · confirmado por usuario",
            source:"confirmacion_usuario")
        let original=[a,estimate,b]
        let group=TimeRecoveryIndex.groups(original)
        XCTAssertEqual(group.count,1)
        XCTAssertEqual(group[0].seconds,600)
        let corrected=TimeRecoveryIndex.without(original,group:group[0]) +
            TimeRecoveryIndex.reassigned(group[0],cell:near)
        XCTAssertEqual(TimeAttribution.totals(corrected,
            cellIDs:[home.id,near.id]),1000)
        XCTAssertTrue(corrected.contains(where:{$0.id==a.id}))
        XCTAssertTrue(corrected.contains(where:{$0.id==b.id}))
        let removed=TimeRecoveryIndex.without(original,group:group[0])
        XCTAssertEqual(removed.count,2)
        XCTAssertEqual(TimeAttribution.totals(removed,
            cellIDs:[home.id,near.id]),400)
    }
    func testUndoIsTransactionalAndPersistedAfterSQLiteReload() throws {
        let folder=FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,
                                                withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let store=try TimeSQLiteStore(url:folder.appendingPathComponent("history.sqlite"))
        var state=SavedState()
        state.intervals=[
            interval(0,100,home),
            interval(100,300,home,quality:"asumido",source:"revision_huecos"),
            interval(300,400,near)]
        state.totals=TimeAttribution.byCell(state.intervals)
        try store.replaceAll(state)
        let group=try XCTUnwrap(TimeRecoveryIndex.groups(state.intervals).first)
        state.intervals=TimeRecoveryIndex.without(state.intervals,group:group)
        state.totals=TimeAttribution.byCell(state.intervals)
        try store.replaceAll(state)
        let loaded=try store.load()
        XCTAssertEqual(loaded.intervals.count,2)
        XCTAssertEqual(loaded.totals.values.reduce(0,+),200)
        XCTAssertTrue(TimeRecoveryIndex.groups(loaded.intervals).isEmpty)
    }
}
