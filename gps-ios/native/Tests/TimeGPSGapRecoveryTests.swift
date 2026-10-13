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
    func testPastConfirmedGapIsAllowedWhileCurrentGPSIsInRestMode() throws {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        let gap=try XCTUnwrap(candidates(raw,fixes:[
            fix(200,home),fix(3380,home)]).first)
        // El usuario puede iniciar el modo pausa a las 15:30 y confirmar
        // una pérdida de GPS terminada a las 15:24.
        let rest=GPSRestSession(startedAt:Date(timeIntervalSince1970:3600),
            cell:home,latitude:Grid.center(home).latitude,
            longitude:Grid.center(home).longitude)
        XCTAssertTrue(TimeGPSGapRecovery.compatibleWithRest(gap,rest:rest))
        XCTAssertTrue(TimeGPSGapRecovery.compatibleWithRest(gap,rest:nil))
        XCTAssertTrue(candidates(raw,fixes:[
            fix(200,home),fix(3380,home)]).contains(gap))
    }
    func testCurrentRestOverlapIsNotCreditedTwice() throws {
        let raw=[interval(100,200,home),interval(3380,3500,home)]
        let gap=try XCTUnwrap(candidates(raw,fixes:[
            fix(200,home),fix(3380,home)]).first)
        let overlappingRest=GPSRestSession(startedAt:Date(timeIntervalSince1970:2500),
            cell:home,latitude:Grid.center(home).latitude,
            longitude:Grid.center(home).longitude)
        XCTAssertFalse(TimeGPSGapRecovery.compatibleWithRest(gap,rest:overlappingRest))
        XCTAssertFalse(TimeGPSGapConfirmationOutcome.overlapsCurrentRest.isSuccess)
        XCTAssertTrue(TimeGPSGapConfirmationOutcome.overlapsCurrentRest.message.contains("solapa"))
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
    func testIncrementalSQLiteConfirmationPersistsWithoutRewritingHistory() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db=try TimeSQLiteStore(url:folder.appendingPathComponent("gps.sqlite"))
        var initial=SavedState()
        let pre=interval(100,200,home)
        let post=interval(3380,3500,home)
        let a=fix(200,home),b=fix(3380,home)
        initial.intervals=[pre,post]
        initial.fixes=[a,b]
        initial.totals[home.id]=220
        initial.trackingEnabled=true
        try db.replaceAll(initial)
        let detected=TimeGPSGapRecovery.candidates(
            intervals:initial.intervals,fixes:initial.fixes,
            manualBreaks:[],events:[],cells:[home.id])
        let gap=try XCTUnwrap(detected.first)
        let repair=AssignedInterval(start:gap.start,end:gap.end,cell:gap.cell,
            quality:"asumido · confirmado por usuario",source:"confirmacion_usuario")
        var snapshot=initial
        snapshot.intervals.append(repair)
        snapshot.totals[home.id,default:0]+=gap.seconds
        try db.append(fixes:[],intervals:[repair],totals:[home.id:gap.seconds],
            header:TimeStoreHeader(snapshot))
        let restored=try db.load()
        XCTAssertEqual(restored.intervals.count,3)
        XCTAssertEqual(restored.fixes.count,2)
        XCTAssertEqual(restored.totals[home.id],3400)
        XCTAssertTrue(restored.trackingEnabled)
        XCTAssertEqual(TimeAttribution.totals(restored.intervals,cellIDs:[home.id]),3400)
        XCTAssertTrue(TimeGPSGapRecovery.candidates(
            intervals:restored.intervals,fixes:restored.fixes,
            manualBreaks:[],events:[],cells:[home.id]).isEmpty)
    }

    func testFeedbackOutcomeExplainsSuccessAndRefusal() {
        let saved=TimeGPSGapConfirmationOutcome.saved(3180)
        XCTAssertTrue(saved.isSuccess)
        XCTAssertTrue(saved.message.contains("53 min"))
        let stale=TimeGPSGapConfirmationOutcome.noLongerAvailable
        XCTAssertFalse(stale.isSuccess)
        XCTAssertTrue(stale.message.contains("No se ha añadido"))
        let failed=TimeGPSGapConfirmationOutcome.storageFailure("disco lleno")
        XCTAssertFalse(failed.isSuccess)
        XCTAssertTrue(failed.message.contains("disco lleno"))
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
