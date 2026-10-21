import XCTest
import UIKit
import MapKit
@testable import RainETA

final class Rain08RegressionTests: XCTestCase {
    let midnight=Date(timeIntervalSince1970:1_800_057_600)

    private func hourly(_ minute:Int,_ mm:Double,_ chance:Int=20)->HourlyRain {
        HourlyRain(id:minute,time:midnight.addingTimeInterval(Double(minute*60)),
                   millimeters:mm,probability:chance,temperature:12)
    }

    private func snapshot(_ hours:[HourlyRain])->RainSnapshot {
        RainSnapshot(updatedAt:midnight,locationName:"Prueba",temperature:12,
                     currentPrecipitation:0,samples:[],hours:hours,days:[])
    }

    func testHourlyRainLabelShowsPrecedingHourNotTheFollowingHour() {
        let at7=midnight.addingTimeInterval(7*3600)
        XCTAssertEqual(RainInsight.hourlyStart(at7),midnight.addingTimeInterval(6*3600))
        let runs=RainInsight.dailyPeriods(snapshot([hourly(420,0.2),
                                                   hourly(480,0.4),hourly(540,0)]),
                                           day:midnight,calendar:utcCalendar())
        XCTAssertEqual(runs.count,1)
        XCTAssertEqual(runs[0].start,midnight.addingTimeInterval(6*3600))
        XCTAssertEqual(runs[0].end,midnight.addingTimeInterval(8*3600))
        XCTAssertEqual(runs[0].accumulationMM,0.6,accuracy:0.001)
    }

    func testNextMidnightRainBelongsToPreviousDay() {
        let next=midnight.addingTimeInterval(86400)
        let rows=[hourly(23*60,0.4),hourly(24*60,0.5),hourly(25*60,0.0)]
        let today=RainInsight.dailyPeriods(snapshot(rows),day:midnight,
                                           calendar:utcCalendar())
        let tomorrow=RainInsight.dailyPeriods(snapshot(rows),day:next,
                                              calendar:utcCalendar())
        XCTAssertEqual(today.count,1)
        XCTAssertEqual(today[0].start,midnight.addingTimeInterval(22*3600))
        XCTAssertEqual(today[0].end,next)
        XCTAssertTrue(tomorrow.isEmpty)
    }

    func testProbabilityAndAmountMismatchIsVisibleNotSuppressed() {
        let day=midnight
        let samples=[hourly(420,0.25,8),hourly(480,0.3,12),
                     hourly(900,0,60)]
        XCTAssertTrue(RainInsight.precipitationUncertainty(hours:samples,day:day,
                                                            calendar:utcCalendar()))
        XCTAssertEqual(RainInsight.dailyPeriods(snapshot(samples),day:day,
                             calendar:utcCalendar()).first?.accumulationMM ?? 0,
                       0.55,accuracy:0.001)
    }

    func testObservedPastIsActualWithinTwoHours() {
        let now=midnight.addingTimeInterval(10_800)
        let ages=[-155,-120,-110,-20,-5,3]
        let frames=ages.enumerated().map {i,lag in
            RadarFrame(timestamp:Int(now.addingTimeInterval(Double(lag*60))
                                     .timeIntervalSince1970),path:"/\(i)")
        }
        let result=RainAPI.availableHistory(frames,now:now)
        XCTAssertEqual(result.count,4)
        XCTAssertTrue(result.allSatisfy {
            $0.date <= now && $0.date >= now.addingTimeInterval(-7200)
        })
    }

    func testFiveMinuteWMSFramesNeverClaimIndependentModelRuns() {
        let now=midnight.addingTimeInterval(7*3600)
        let a=ICONForecastTiles.period(leadMinutes:5,now:now)
        let b=ICONForecastTiles.period(leadMinutes:10,now:now)
        XCTAssertEqual(a.upper,a.lower.addingTimeInterval(3600))
        XCTAssertEqual(b.target.timeIntervalSince(a.target),300,accuracy:0.001)
        XCTAssertEqual(a.lower,b.lower)
        XCTAssertEqual(a.upper,b.upper)
    }

    private func utcCalendar()->Calendar {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        return calendar
    }
}
