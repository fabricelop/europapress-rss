import XCTest
@testable import RainETA

final class RainInsightsTests: XCTestCase {
    private let anchor=Date(timeIntervalSince1970:1_800_000_000)

    private func samples(_ amounts:[Double]) -> [RainSample] {
        amounts.enumerated().map { index,value in
            RainSample(id:index,time:anchor.addingTimeInterval(Double(index*15*60)),
                       precipitation:value,probability:60)
        }
    }

    func testEveryMinuteIsInterpolatedNotIndependentSource() {
        let data=samples([0,0.4,0.8,0.4,0])
        let list=RainInsight.moments(samples:data,from:anchor,minutes:60)
        XCTAssertEqual(list.count,61)
        XCTAssertEqual(list[0].rateMMH,0,accuracy:0.0001)
        XCTAssertEqual(list[15].rateMMH,1.6,accuracy:0.0001)
        XCTAssertEqual(list[30].rateMMH,3.2,accuracy:0.0001)
        XCTAssertEqual(list[45].rateMMH,1.6,accuracy:0.0001)
        XCTAssertTrue(list.allSatisfy{$0.source.contains("interpolado")})
    }

    func testRejectsForecastOutsideKnownSampleWindow() {
        let data=samples([0.2,0.8])
        XCTAssertNil(RainInsight.interpolatedRate(
            at:anchor.addingTimeInterval(50*60),samples:data))
        XCTAssertNil(RainInsight.interpolatedRate(
            at:anchor.addingTimeInterval(-60*60),samples:data))
    }

    func testPeriodsNeedTwoDryReadingsToStop() {
        let data=samples([0,0.2,0.3,0.02,0.3,0.0,0.0,0.0,0.2,0.2,0.0,0.0])
        let result=RainInsight.periods(samples:data,after:anchor,
                                       until:anchor.addingTimeInterval(4*3600))
        XCTAssertEqual(result.count,2)
        XCTAssertEqual(result[0].start,anchor.addingTimeInterval(15*60))
        XCTAssertGreaterThan(result[0].end,result[0].start)
        XCTAssertEqual(result[1].start,anchor.addingTimeInterval(8*15*60))
    }

    func testCountdownAdvancesWithClockAndStopsAtZero() {
        let target=anchor.addingTimeInterval(90)
        XCTAssertEqual(RainInsight.countdown(to:target,at:anchor),"01:30")
        XCTAssertEqual(RainInsight.countdown(to:target,at:anchor.addingTimeInterval(30)),"01:00")
        XCTAssertEqual(RainInsight.countdown(to:target,at:anchor.addingTimeInterval(100)),"00:00")
        XCTAssertEqual(RainInsight.countdown(to:nil,at:anchor),"—")
    }

    func testRainRatePhysicalUnitsAndColorLabels() {
        XCTAssertEqual(RainInsight.rateFrom15(0.25),1.0,accuracy:0.0001)
        XCTAssertEqual(RainVisual.intensity(10),"Fuerte")
        XCTAssertEqual(RainVisual.intensity(0.01),"Sin lluvia")
    }

    func testDailyRainWindowsFromRealHourlySteps() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let midnight=calendar.startOfDay(for:anchor)
        let amounts:[Double]=[0,0,0.5,1,0,0,0.2,0.3,0]
        let hours=amounts.enumerated().map { i,mm in
            HourlyRain(id:i,time:midnight.addingTimeInterval(Double(i*3600)),
                       millimeters:mm,probability:mm>0 ? 70 : 10,temperature:15)
        }
        let wx=RainSnapshot(updatedAt:anchor,locationName:"Prueba",temperature:15,
                            currentPrecipitation:0,samples:[],hours:hours,days:[])
        let periods=RainInsight.dailyPeriods(wx,day:midnight,calendar:calendar)
        XCTAssertEqual(periods.count,2)
        XCTAssertEqual(periods[0].accumulationMM,1.5,accuracy:0.001)
        XCTAssertEqual(periods[1].accumulationMM,0.5,accuracy:0.001)
    }
}
