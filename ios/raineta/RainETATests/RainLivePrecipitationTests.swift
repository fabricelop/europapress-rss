import XCTest
@testable import RainETA

final class RainLivePrecipitationTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)

    func testSnowWeatherCodeIsModelPhaseNotRadarClassification() {
        XCTAssertEqual(RainPrecipitationPhase.classify(weatherCode:71,snowfallCM:0),.snow)
        XCTAssertEqual(RainPrecipitationPhase.classify(weatherCode:85,snowfallCM:0),.snow)
        XCTAssertEqual(RainPrecipitationPhase.classify(weatherCode:66,snowfallCM:0),.mixed)
        XCTAssertEqual(RainPrecipitationPhase.classify(weatherCode:3,snowfallCM:0.3),.snow)
        XCTAssertEqual(RainPrecipitationPhase.classify(weatherCode:3,snowfallCM:0),.rain)
        XCTAssertTrue(RainLiveDisplay.title(wet:true,kind:.snow,hasReliableTime:false)
                       .contains("según modelo"))
    }

    func testHourlySnowForecastDoesNotGetReplacedByCurrentCloudCode() {
        let wx=RainSnapshot(
            updatedAt:now,locationName:"Sierra de Madrid",temperature:1,
            currentPrecipitation:0,
            samples:[],hours:[],days:[],
            currentSnowfallCM:0,currentWeatherCode:3,
            snowHours:[HourlySnow(end:now.addingTimeInterval(3600),centimeters:0.7)]
        )
        XCTAssertEqual(wx.phase(at:now),.rain)
        XCTAssertEqual(wx.phase(at:now.addingTimeInterval(40*60)),.snow)
    }

    func testLivePulseClampsIntensityAndNeverCallsMissingDataDry() {
        let levels=RainLiveDisplay.pulseLevels([
            Double.nan,0,0.14,0.15,0.6,2.5,7.5,100,-1,0.7,1,4,50,50
        ])
        XCTAssertEqual(levels.count,12)
        XCTAssertEqual(levels[0],-1)
        XCTAssertEqual(levels[1],0)
        XCTAssertEqual(levels[3],1)
        XCTAssertEqual(levels[4],2)
        XCTAssertEqual(levels[5],3)
        XCTAssertEqual(levels[6],4)
    }

    func testLiveActivityContentStateKeepsNewMetadataOptional() {
        let old=RainETAAttributes.ContentState(
            arrival:nil,rainingNow:false,intensity:"Sin precipitación",
            updatedAt:now,summary:"Sin precipitación próxima confirmada",
            locationName:"Madrid"
        )
        XCTAssertNil(old.precipitationKind)
        XCTAssertNil(old.radarObservedAt)
        XCTAssertNil(old.nextHourBars)

        let new=RainETAAttributes.ContentState(
            arrival:now.addingTimeInterval(600),rainingNow:false,
            intensity:"Sin precipitación",updatedAt:now,
            summary:"Se prevé nieve",locationName:"Navacerrada",
            precipitationKind:"snow",sourceLabel:"Modelo · sin confirmar",
            confidenceLabel:"Orientativo",radarObservedAt:nil,
            nextHourBars:[0,0,1,2,2,4,3,1,0,-1,0,0],
            temperatureC:-1.5
        )
        XCTAssertEqual(new.precipitationKind,"snow")
        XCTAssertEqual(new.nextHourBars?.count,12)
        XCTAssertEqual(new.temperatureC,-1.5)
    }
}
