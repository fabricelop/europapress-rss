import XCTest
@testable import MiMapaDelTiempo

final class SiteDayPresentationTests: XCTestCase {
    private let a = Cell(row: 100, column: 500)
    private let b = Cell(row: 100, column: 501)
    private let c = Cell(row: 100, column: 502)
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    private func stay(_ from: Double, _ to: Double, _ cell: Cell,
                      siteID: UUID? = nil, confirmed: Bool = true) -> SiteDaySource {
        let fragment = AssignedInterval(start: Date(timeIntervalSince1970: from),
                           end: Date(timeIntervalSince1970: to),
                           cell: cell, quality: "observado", source: "gps")
        let s = SiteStayHistory.extract([fragment]).first!
        var part = SiteStayHistory.defaultPart(for: s, suggested: siteID)
        part.confirmed = siteID != nil && confirmed
        return SiteDaySource(stay: s, parts: [part])
    }

    func testPreviousAndNextCrossDSTExactlyOneCivilDay() {
        let october24 = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22))!
        let october25 = SiteCalendarDay.addingDays(1, to: october24, calendar: cal)
        let october26 = SiteCalendarDay.addingDays(1, to: october25, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: october25), 25)
        XCTAssertEqual(cal.component(.day, from: october26), 26)
        XCTAssertEqual(cal.component(.day, from: SiteCalendarDay.addingDays(-2,
                                    to: october26, calendar: cal)), 24)
        XCTAssertEqual(cal.component(.hour, from: october25), 12)
        XCTAssertEqual(SiteCalendarDay.interval(for: october25, calendar: cal).duration, 90000)
        let march28 = cal.date(from:DateComponents(year:2027,month:3,day:28,hour:6))!
        XCTAssertEqual(SiteCalendarDay.interval(for:march28,calendar:cal).duration,82800)
    }

    func testRepeatedNextPreviousDoesNotToggleOrResetDate() {
        let start=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:16,
                                                minute:17))!
        var chosen=SiteCalendarDay.normalized(start,calendar:cal)
        for day in 12...25 {
            chosen=SiteCalendarDay.addingDays(1,to:chosen,calendar:cal)
            XCTAssertEqual(cal.component(.day,from:chosen),day)
            XCTAssertEqual(cal.component(.month,from:chosen),10)
        }
        // This crosses the 25 October daylight-saving clock change.
        for day in (11...24).reversed() {
            chosen=SiteCalendarDay.addingDays(-1,to:chosen,calendar:cal)
            XCTAssertEqual(cal.component(.day,from:chosen),day)
        }
        XCTAssertEqual(cal.component(.hour,from:chosen),12)
        let last=SiteCalendarDay.addingDays(-1,to:chosen,calendar:cal)
        XCTAssertEqual(cal.component(.day,from:last),10)
    }

    func testSameSiteAcrossSquaresCollapsesWithoutLosingMinutes() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:24,hour:10))!
                 .timeIntervalSince1970
        let park=UUID()
        let entries=[
            stay(base, base+420, a, siteID:park),
            stay(base+425, base+1025, b, siteID:park),
            stay(base+1050, base+1410, c, siteID:park)
        ]
        let report=SiteDayPresentation.build(entries, on:Date(timeIntervalSince1970:base),
                                             calendar:cal)
        XCTAssertEqual(report.groups.count,1)
        XCTAssertEqual(report.groups[0].entries.count,3)
        XCTAssertEqual(report.groups[0].uniqueCells,3)
        XCTAssertEqual(report.groups[0].recordedSeconds,1380, accuracy:0.01)
        XCTAssertEqual(report.confirmedSiteCount,1)
        XCTAssertTrue(report.isFullyReviewed)
    }

    func testNonconsecutiveSitesDoNotMerge() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:24,hour:11))!
                 .timeIntervalSince1970
        let park=UUID()
        let cafe=UUID()
        let entries=[
            stay(base,base+360,a,siteID:park),
            stay(base+400,base+760,b,siteID:cafe),
            stay(base+800,base+1160,a,siteID:park)
        ]
        let report=SiteDayPresentation.build(entries,on:Date(timeIntervalSince1970:base),
                                             calendar:cal)
        XCTAssertEqual(report.groups.count,3)
        XCTAssertEqual(report.groups.map(\.siteID),[park,cafe,park])
    }

    func testSuggestionsRemainSeparateFromConfirmedAndFromPassing() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:24,hour:10))!
                 .timeIntervalSince1970
        let park=UUID()
        let first=stay(base,base+350,a,siteID:park,confirmed:true)
        let second=stay(base+400,base+900,b,siteID:park,confirmed:false)
        var passing=stay(base+950,base+1350,c)
        passing.parts[0].kind = .passing
        let report=SiteDayPresentation.build([first,second,passing],
                                              on:Date(timeIntervalSince1970:base),
                                              calendar:cal)
        XCTAssertEqual(report.groups.count,3)
        XCTAssertTrue(report.isFullyClassified)
        XCTAssertEqual(report.classifiedFraction,1,accuracy:0.00001)
        XCTAssertEqual(report.pendingStaysCount,0)
        XCTAssertEqual(report.proposedStaysCount,1)
        XCTAssertEqual(report.confirmedGPS,350)
        XCTAssertEqual(report.suggestedGPS,500)
        XCTAssertEqual(report.passingGPS,400)
    }

    func testOnlyProposedSiteIsOneHundredPercentClassifiedButNotConfirmed() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:8))!
                    .timeIntervalSince1970
        let site=UUID()
        let item=stay(base,base+720,a,siteID:site,confirmed:false)
        let report=SiteDayPresentation.build([item],
              on:Date(timeIntervalSince1970:base),calendar:cal)
        XCTAssertEqual(report.classifiedFraction,1,accuracy:0.00001)
        XCTAssertTrue(report.isFullyClassified)
        XCTAssertEqual(report.pendingStaysCount,0)
        XCTAssertEqual(report.proposedStaysCount,1)
        XCTAssertEqual(report.confirmedGPS,0)
        XCTAssertEqual(report.suggestedGPS,720)
        XCTAssertEqual(report.siteTotals.first?.confirmedSeconds,0)
        XCTAssertEqual(report.siteTotals.first?.proposedSeconds,720)
    }

    func testUnassignedSubperiodKeepsStayPendingEvenWithAnotherProposedSite() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:12))!
                    .timeIntervalSince1970
        var item=stay(base,base+900,a)
        let site=UUID()
        item.parts=[
            SiteStayPart(stayID:item.stay.id,from:item.stay.start,
                         to:item.stay.start.addingTimeInterval(600),kind:.place,
                         siteID:site,confirmed:false),
            SiteStayPart(stayID:item.stay.id,
                         from:item.stay.start.addingTimeInterval(600),
                         to:item.stay.end,kind:.unassigned,siteID:nil)
        ]
        let report=SiteDayPresentation.build([item],
              on:Date(timeIntervalSince1970:base),calendar:cal)
        XCTAssertEqual(report.classifiedFraction,2.0/3.0,accuracy:0.00001)
        XCTAssertFalse(report.isFullyClassified)
        XCTAssertEqual(report.pendingStaysCount,1)
        XCTAssertTrue(report.pendingStayIDs.contains(item.stay.id))
        XCTAssertEqual(report.proposedStaysCount,1)
        XCTAssertEqual(report.unidentifiedGPS,300)
    }

    func testProposedStayDoesNotBecomeManualConfirmation() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:17))!
                    .timeIntervalSince1970
        let site=UUID()
        let item=stay(base,base+360,a,siteID:site,confirmed:false)
        let original=item.parts
        let report=SiteDayPresentation.build([item],
              on:Date(timeIntervalSince1970:base),calendar:cal)
        XCTAssertTrue(report.isFullyClassified)
        XCTAssertEqual(item.parts,original)
        XCTAssertFalse(item.parts[0].confirmed)
    }

    func testPartsCanAssignTwoSitesWithoutDuplicatingRecordedTime() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:24,hour:10))!
                 .timeIntervalSince1970
        var item=stay(base,base+1200,a)
        let cafe=UUID()
        let park=UUID()
        item.parts=[
            SiteStayPart(stayID:item.stay.id,from:item.stay.start,
                  to:Date(timeIntervalSince1970:base+500),kind:.place,
                  siteID:cafe,confirmed:true),
            SiteStayPart(stayID:item.stay.id,from:Date(timeIntervalSince1970:base+500),
                  to:item.stay.end,kind:.place,siteID:park,confirmed:true)
        ]
        let report=SiteDayPresentation.build([item],on:Date(timeIntervalSince1970:base),
                                             calendar:cal)
        XCTAssertEqual(report.groups.count,1)
        XCTAssertNil(report.groups[0].siteID)
        XCTAssertEqual(report.confirmedGPS,1200)
        XCTAssertEqual(report.siteTotals.count,2)
        XCTAssertEqual(report.siteTotals.map(\.confirmedSeconds).reduce(0,+),1200)
    }

    func testHistoricalMidnightBoundaryDoesNotCountTomorrow() {
        let base=cal.date(from:DateComponents(year:2026,month:10,day:24,hour:23,
                                              minute:55))!.timeIntervalSince1970
        let park=UUID()
        let item=stay(base,base+900,a,siteID:park)
        let saturday=SiteDayPresentation.build([item],on:Date(timeIntervalSince1970:base),
                                                calendar:cal)
        let sunday=SiteDayPresentation.build([item],
                on:SiteCalendarDay.addingDays(1,to:Date(timeIntervalSince1970:base),calendar:cal),
                calendar:cal)
        XCTAssertEqual(saturday.totalGPS,300)
        XCTAssertEqual(sunday.totalGPS,600)
    }
}
