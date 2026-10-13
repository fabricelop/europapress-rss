import XCTest
@testable import MiMapaDelTiempo

final class GPSGapReviewAndWatchdogTests:XCTestCase {
    private let home=Cell(row:148000,column:143000)
    private let away=Cell(row:148000,column:143002)
    private func segment(_ start:Double,_ end:Double,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
            end:Date(timeIntervalSince1970:end),
            cell:cell,quality:"observado",source:"test")
    }
    private func point(_ at:Double,_ cell:Cell,accuracy:Double=10)->GPSPoint {
        let coord=Grid.center(cell)
        return GPSPoint(date:Date(timeIntervalSince1970:at),
            latitude:coord.latitude,longitude:coord.longitude,
            accuracy:accuracy,source:"gps")
    }
    func testEveryUnassignedIntervalAppearsEvenWithDifferentCells() throws {
        let observations=[segment(100,200,home),segment(3800,3900,away),
                          segment(5000,5100,away)]
        let all=TimeGPSGapReviewIndex.scan(intervals:observations,
            fixes:[point(200,home),point(3800,away)],events:[])
        XCTAssertEqual(all.count,2)
        let long=try XCTUnwrap(all.first(where:{$0.start.timeIntervalSince1970==200}))
        XCTAssertFalse(long.sameCell)
        XCTAssertEqual(long.seconds,3600)
        XCTAssertEqual(long.previousCell,home)
        XCTAssertEqual(long.nextCell,away)
    }
    func testHalfSplitNeverCreatesOrDuplicatesSeconds() throws {
        let g=TimeGPSGapReviewIndex.scan(
            intervals:[segment(100,200,home),segment(800,900,away)],fixes:[],events:[])
        let gap=try XCTUnwrap(g.first)
        let pieces=TimeGPSGapReviewIndex.segments(for:gap,choice:.splitEqually)
        XCTAssertEqual(pieces.count,2)
        XCTAssertEqual(pieces[0].cell,home)
        XCTAssertEqual(pieces[1].cell,away)
        XCTAssertEqual(pieces.reduce(0){$0+$1.seconds},600,accuracy:0.001)
        let history=[segment(100,200,home),segment(800,900,away)]+pieces
        XCTAssertTrue(TimeGPSGapReviewIndex.scan(intervals:history,fixes:[],events:[]).isEmpty)
        XCTAssertEqual(TimeAttribution.totals(history,cellIDs:[home.id,away.id]),
            800,accuracy:0.001)
    }
    func testSingleCellEstimateRemovesPendingGap() throws {
        let raw=[segment(100,200,home),segment(800,900,home)]
        let gap=try XCTUnwrap(TimeGPSGapReviewIndex.scan(
            intervals:raw,fixes:[],events:[]).first)
        XCTAssertTrue(gap.sameCell)
        let assigned=TimeGPSGapReviewIndex.segments(for:gap,choice:.previous)
        XCTAssertEqual(assigned.count,1)
        XCTAssertEqual(TimeAttribution.totals(raw+assigned,cellIDs:[home.id]),800)
        XCTAssertTrue(TimeGPSGapReviewIndex.scan(
            intervals:raw+assigned,fixes:[],events:[]).isEmpty)
    }
    func testDiscardHidesWithoutDeletingHistoricalEvidence() throws {
        let raw=[segment(100,200,home),segment(800,900,home)]
        let gap=try XCTUnwrap(TimeGPSGapReviewIndex.scan(
            intervals:raw,fixes:[],events:[]).first)
        XCTAssertTrue(TimeGPSGapReviewIndex.scan(
            intervals:raw,fixes:[],events:[],dismissed:[gap.id]).isEmpty)
        XCTAssertEqual(TimeAttribution.totals(raw,cellIDs:[home.id]),200)
    }
    func testContradictoryFixBlocksBulkAssignmentButRemainsVisible() throws {
        let raw=[segment(100,200,home),segment(800,900,home)]
        let gap=try XCTUnwrap(TimeGPSGapReviewIndex.scan(intervals:raw,
            fixes:[point(500,away)],events:[]).first)
        XCTAssertTrue(gap.contradictoryGPS)
        XCTAssertFalse(gap.canManuallyAssign)
    }
    func testGapMapRegionContainsBothKnownCellFootprints() throws {
        let raw=[segment(100,200,home),segment(800,900,away)]
        let gap=try XCTUnwrap(TimeGPSGapReviewIndex.scan(
            intervals:raw,fixes:[],events:[]).first)
        let region=GPSGapMapLayout.region(gap)
        XCTAssertGreaterThan(region.span.latitudeDelta,0)
        XCTAssertGreaterThan(region.span.longitudeDelta,0)
        let vertices=Grid.polygon(home)+Grid.polygon(away)
        let lowerLatitude=region.center.latitude-region.span.latitudeDelta/2
        let upperLatitude=region.center.latitude+region.span.latitudeDelta/2
        let lowerLongitude=region.center.longitude-region.span.longitudeDelta/2
        let upperLongitude=region.center.longitude+region.span.longitudeDelta/2
        for vertex in vertices {
            XCTAssertGreaterThanOrEqual(vertex.latitude,lowerLatitude)
            XCTAssertLessThanOrEqual(vertex.latitude,upperLatitude)
            XCTAssertGreaterThanOrEqual(vertex.longitude,lowerLongitude)
            XCTAssertLessThanOrEqual(vertex.longitude,upperLongitude)
        }
        XCTAssertGreaterThan(GPSGapMapLayout.distance(gap),0)
    }
    func testSameCellGapHasZeroMapDistance() throws {
        let raw=[segment(100,200,home),segment(800,900,home)]
        let gap=try XCTUnwrap(TimeGPSGapReviewIndex.scan(
            intervals:raw,fixes:[],events:[]).first)
        XCTAssertTrue(gap.sameCell)
        XCTAssertEqual(GPSGapMapLayout.distance(gap),0,accuracy:0.001)
    }
    func testRestoringOneDismissalDoesNotAffectOtherGapIDs() throws {
        let observations=[segment(100,200,home),
                          segment(800,900,away),
                          segment(1700,1800,away)]
        let gaps=TimeGPSGapReviewIndex.scan(intervals:observations,
                                          fixes:[],events:[])
        XCTAssertEqual(gaps.count,2)
        let dismissed:Set<String>=Set(gaps.map(\.id))
        let restoreOnly=gaps[0].id
        let afterRestore=dismissed.subtracting([restoreOnly])
        let visible=TimeGPSGapReviewIndex.scan(intervals:observations,
                            fixes:[],events:[],dismissed:afterRestore)
        XCTAssertEqual(visible.count,1)
        XCTAssertEqual(visible[0].id,restoreOnly)
        XCTAssertEqual(TimeAttribution.totals(observations,
                            cellIDs:[home.id,away.id]),300)
    }
    func testStaleGPSAlarmRenewsOnlyOnFreshFixes() {
        let now=Date(timeIntervalSince1970:1000)
        XCTAssertTrue(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:true,resting:false,
            fix:now,now:now,lastArmed:nil,intervalMinutes:15))
        XCTAssertFalse(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:true,resting:false,
            fix:now,now:now,lastArmed:now.addingTimeInterval(-15),
            intervalMinutes:15))
        XCTAssertTrue(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:true,resting:false,
            fix:now,now:now,lastArmed:now.addingTimeInterval(-70),
            intervalMinutes:15))
        XCTAssertFalse(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:true,resting:true,
            fix:now,now:now,lastArmed:nil,intervalMinutes:15))
        XCTAssertFalse(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:false,resting:false,
            fix:now,now:now,lastArmed:nil,intervalMinutes:15))
        XCTAssertFalse(GPSStaleWatchdogPolicy.shouldRenew(
            enabled:true,tracking:true,resting:false,
            fix:now.addingTimeInterval(-500),now:now,lastArmed:nil,intervalMinutes:15))
    }
    func testNotificationExpiresOnlyOnceAndRequiresSustainedReadingsToRearm() {
        let armed=Date(timeIntervalSince1970:100)
        XCTAssertFalse(GPSStaleWatchdogPolicy.deadlinePassed(
            armedAt:armed,now:Date(timeIntervalSince1970:999),minutes:15))
        XCTAssertTrue(GPSStaleWatchdogPolicy.deadlinePassed(
            armedAt:armed,now:Date(timeIntervalSince1970:1000),minutes:15))
        // Lecturas sueltas cada 20 min NO constituyen una recuperación.
        XCTAssertFalse(GPSStaleWatchdogPolicy.recoveryConfirmed(
            first:Date(timeIntervalSince1970:1300),
            previous:Date(timeIntervalSince1970:1300),
            latest:Date(timeIntervalSince1970:2500)))
        // Un flujo sostenido de posiciones sí permite vigilar una nueva avería.
        XCTAssertTrue(GPSStaleWatchdogPolicy.recoveryConfirmed(
            first:Date(timeIntervalSince1970:1000),
            previous:Date(timeIntervalSince1970:1170),
            latest:Date(timeIntervalSince1970:1180)))
    }
    func testMovementIsNotRequiredForAFreshGPSTimestamp() {
        let now=Date(timeIntervalSince1970:2000)
        let sameLocationNewTimestamp=now
        XCTAssertTrue(GPSStaleWatchdogPolicy.isFresh(
            sameLocationNewTimestamp,at:now))
        XCTAssertFalse(GPSStaleWatchdogPolicy.isFresh(
            now.addingTimeInterval(-900),at:now))
    }
    func testLegacySavedStateStillDecodesWithoutDismissedGapField() throws {
        var state=SavedState()
        state.dismissedGPSGapIDs=["ignored"]
        let copy=try JSONDecoder().decode(SavedState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(copy.dismissedGPSGapIDs,["ignored"])
        let legacy=Data(#"{"fixes":[],"intervals":[],"totals":{},"names":{},"importedHashes":[],"camera":{"latitude":40.4,"longitude":-3.7,"latitudeDelta":0.009,"longitudeDelta":0.009},"missingSeconds":0}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(SavedState.self,from:legacy).dismissedGPSGapIDs.isEmpty)
    }
}