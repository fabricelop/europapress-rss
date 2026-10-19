import XCTest
@testable import RainETA

final class RainVisualForecastTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)

    private func snapshot() -> RainSnapshot {
        let hours=(1...30).map { i in
            HourlyRain(id:i,time:now.addingTimeInterval(Double(i*3600)),
                       millimeters:i==2 ? 2.4 : i==3 ? 0.5 : 0,
                       probability:i==2 ? 85 : i==3 ? 60 : 8,
                       temperature:Double(10+i%4))
        }
        let snow=[HourlySnow(end:now.addingTimeInterval(3*3600),
                             centimeters:0.7)]
        return RainSnapshot(updatedAt:now,locationName:"Navacerrada",
                            temperature:8,currentPrecipitation:0,
                            samples:[],hours:hours,days:[],
                            currentSnowfallCM:0,currentWeatherCode:3,
                            snowHours:snow)
    }

    private func minute(_ minute:Int,_ rate:Double,
                        radar:Bool=false)->RadarWeightedMinute {
        RadarWeightedMinute(minute:minute,
            at:now.addingTimeInterval(Double(minute*60)),
            rate:rate,radarInformed:radar,radarEcho:radar ? 0.8:nil)
    }

    func testTwoHourOverviewUsesSame120MinuteRadarAndModelInput() {
        let values=(0..<120).map { minute in
            self.minute(minute,minute < 30 ? 0 :
                        minute < 60 ? 0.5 :
                        minute < 90 ? 1.0 : 0,
                        radar:minute<60)
        }
        let bins=RainVisualForecast.overview(values,weather:nil)
        XCTAssertEqual(bins.count,12)
        XCTAssertEqual(bins[0].rainyMinutes,0)
        XCTAssertEqual(bins[3].rainyMinutes,10)
        XCTAssertEqual(bins[6].rainyMinutes,10)
        XCTAssertEqual(bins[9].rainyMinutes,0)
        XCTAssertEqual(bins[3].radarMinutes,10)
        XCTAssertEqual(bins[6].radarMinutes,0)
        XCTAssertEqual(RainVisualForecast.rainyMinutes(bins),60)
        XCTAssertEqual(RainVisualForecast.estimatedNextChange(bins,rainingNow:false),30)
        let wetFirst=(0..<120).map { minute in
            self.minute(minute,minute<90 ? 1.0:0,radar:minute<60)
        }
        XCTAssertEqual(RainVisualForecast.estimatedNextChange(
            RainVisualForecast.overview(wetFirst,weather:nil),rainingNow:true),90)
        XCTAssertEqual(RainVisualForecast.liquidEquivalent(values),0.75,accuracy:0.0001)
    }

    func testIncompletePeriodIsUnknownNeverForcedDry() {
        let values=(0..<4).map{minute($0,0,radar:true)}
        let bins=RainVisualForecast.overview(values,weather:nil,horizon:20)
        XCTAssertEqual(bins.count,2)
        XCTAssertNil(bins[0].meanRate)
        XCTAssertNil(bins[1].meanRate)
        XCTAssertNil(RainVisualForecast.estimatedNextChange(bins,rainingNow:false))
    }

    func testSnowIsFlaggedSeparatelyFromEquivalentRainfall() {
        let hours=[HourlyRain(id:1,time:now.addingTimeInterval(3600),
                              millimeters:2,probability:75,temperature:0)]
        let wx=RainSnapshot(updatedAt:now,locationName:"Sierra",temperature:0,
                            currentPrecipitation:0,samples:[],hours:hours,days:[],
                            currentSnowfallCM:0,currentWeatherCode:3,
                            snowHours:[HourlySnow(end:now.addingTimeInterval(3600),
                                                 centimeters:0.8)])
        let values=(0..<10).map{minute($0,0.5)}
        let bins=RainVisualForecast.overview(values,weather:wx,horizon:10)
        XCTAssertEqual(bins.count,1)
        XCTAssertTrue(bins[0].snow)
        let result=RainVisualForecast.daily24(wx,now:now)
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result[0].snowCM,0.8,accuracy:0.0001)
        XCTAssertEqual(result[0].probability,75)
    }

    func testDailyViewShows24HourlyAccrualsAndProbabilityBoundaries() {
        let wx=snapshot()
        let data=RainVisualForecast.daily24(wx,now:now)
        XCTAssertEqual(data.count,24)
        XCTAssertEqual(data[1].millimeters,2.4,accuracy:0.0001)
        XCTAssertEqual(data[1].probability,85)
        XCTAssertEqual(data[2].snowCM,0.7,accuracy:0.0001)
        XCTAssertTrue(data[2].isWet)
        XCTAssertFalse(data[0].isWet)
        XCTAssertEqual(data.reduce(0.0){$0+$1.millimeters},2.9,accuracy:0.0001)
    }

    func testInsufficientInputsProduceBlankInsteadOfFakeDryForecast() {
        let wx=RainSnapshot(updatedAt:now,locationName:"Madrid",
                            temperature:nil,currentPrecipitation:0,
                            samples:[],hours:[],days:[])
        XCTAssertTrue(RainVisualForecast.daily24(wx,now:now).isEmpty)
        XCTAssertTrue(RainVisualForecast.overview([],weather:wx).allSatisfy{
            $0.meanRate==nil
        })
    }
}
