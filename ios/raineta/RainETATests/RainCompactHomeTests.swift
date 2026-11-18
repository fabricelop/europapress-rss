import XCTest
@testable import RainETA

final class RainCompactHomeTests: XCTestCase {
    private func bin(_ start: Int, rate: Double?, rainy: Int = 0) -> RainOverviewBin {
        RainOverviewBin(startMinute:start,meanRate:rate,peakRate:rate,
                        rainyMinutes:rainy,radarMinutes:0,snow:false)
    }

    func testHomeHasFourRainSectionsAndPreservesExistingAdvancedViews() {
        XCTAssertEqual(RainCompactSection.ordered(RainCompactSection.defaultOrder),
                       [.hours,.day,.days,.radar])
        XCTAssertEqual(RainCompactSection.ordered("radar,radar,unknown,day"),
                       [.radar,.day,.hours,.days])
        XCTAssertEqual(RainCompactSection.visible(order:"hours,day,days,radar",
                                                  hidden:"day,unknown,radar"),
                       [.hours,.days])
    }

    func testDryWindowIsNeverBridgedAcrossUnknownOrRainyBin() {
        let points = [
            bin(0,rate:0),bin(15,rate:0),
            bin(30,rate:nil),bin(45,rate:0),
            bin(60,rate:0.6,rainy:15),bin(75,rate:0),
            bin(90,rate:0),bin(105,rate:0)
        ]
        let result = RainCompactData.bestDryRange(points)
        XCTAssertEqual(result?.lowerBound,5)
        XCTAssertEqual(result?.upperBound,8)
    }

    func testDryWindowRequiresAtLeastTwoQuarterHours() {
        XCTAssertNil(RainCompactData.bestDryRange([bin(0,rate:0)]))
        XCTAssertNil(RainCompactData.bestDryRange([bin(0,rate:0),bin(30,rate:0)]))
        XCTAssertEqual(RainCompactData.bestDryRange([bin(0,rate:0),bin(15,rate:0)])?.count,2)
    }

    func testUnknownRainBinIsNotPresentedAsDry() {
        XCTAssertEqual(RainCompactData.label(bin(0,rate:nil)), "Datos insuficientes")
        XCTAssertEqual(RainCompactData.label(bin(0,rate:0)), "Sin lluvia relevante prevista")
    }

    func testTenDaysForecastRequested() {
        XCTAssertEqual(RainAPI.forecastDays,10)
    }

    func testDailyHistogramNeverTurnsMissingHourIntoZero() {
        var cal = Calendar(identifier:.gregorian)
        cal.timeZone = TimeZone(secondsFromGMT:0)!
        let date = Date(timeIntervalSince1970:1_790_000_000)
        let start = cal.startOfDay(for:date)
        let day = DailyRain(id:0,date:start,totalMM:1.4,probability:80,
                            minTemperature:nil,maxTemperature:nil)
        let hours = [
            HourlyRain(id:1,time:start.addingTimeInterval(3600),
                       millimeters:0.4,probability:70,temperature:nil),
            HourlyRain(id:3,time:start.addingTimeInterval(3*3600),
                       millimeters:1.0,probability:80,temperature:nil)
        ]
        let values = RainTenDayData.hourly(day:day,hours:hours,calendar:cal)
        XCTAssertEqual(values.count,24)
        XCTAssertEqual(values[0].amount,0.4)
        XCTAssertNil(values[1].amount)
        XCTAssertNil(values[1].probability)
        XCTAssertEqual(values[2].amount,1.0)
    }

    func testDailyHistogramRespectsDaylightSavings() {
        var cal = Calendar(identifier:.gregorian)
        cal.timeZone = TimeZone(identifier:"Europe/Madrid")!
        let components = DateComponents(year:2026,month:3,day:29)
        let spring = cal.date(from:components)!
        let day = DailyRain(id:0,date:spring,totalMM:0,probability:0,
                            minTemperature:nil,maxTemperature:nil)
        XCTAssertEqual(RainTenDayData.hourly(day:day,hours:[],calendar:cal).count,23)
    }

    func testRainiestDayUsesActualAccumulationNotProbability() {
        let t = Date(timeIntervalSince1970:1_790_000_000)
        let days = [
            DailyRain(id:0,date:t,totalMM:0.1,probability:95,
                      minTemperature:nil,maxTemperature:nil),
            DailyRain(id:1,date:t.addingTimeInterval(86400),totalMM:8.1,probability:30,
                      minTemperature:nil,maxTemperature:nil)
        ]
        XCTAssertEqual(RainTenDayData.wettest(days)?.id,1)
        XCTAssertNil(RainTenDayData.wettest([]))
    }
}
