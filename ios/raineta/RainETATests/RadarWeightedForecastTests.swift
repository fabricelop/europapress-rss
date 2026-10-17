import XCTest
@testable import RainETA

final class RadarWeightedForecastTests:XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)
    private func weather(_ rain:Bool) -> RainSnapshot {
        let fine=(1...16).map { n in
            RainSample(id:n,time:start.addingTimeInterval(Double(n*900)),
                       precipitation:rain ? 0.6:0,probability:rain ? 90:10)
        }
        return RainSnapshot(updatedAt:start,locationName:"Prueba",
            temperature:12,currentPrecipitation:rain ? 1.0:0.0,
            samples:fine,hours:[],days:[])
    }
    private func radar(_ observedEcho:Double,_ nowcastEcho:Double,
                       observedAt:Date?=nil)->RadarLocalTimeline {
        let stamp=observedAt ?? start
        let frames=[RadarLocalFrame(date:stamp.addingTimeInterval(-600),echo:observedEcho),
                    RadarLocalFrame(date:stamp,echo:observedEcho)] +
                   (1...6).map { n in
                       RadarLocalFrame(date:stamp.addingTimeInterval(Double(n*600)),
                                       echo:nowcastEcho)
                   }
        return RadarLocalTimeline(observedAt:stamp,fetchedAt:stamp,
                            frames:frames,coverageConfirmed:true)
    }
    func testRadarDryOverridesContraryRainingNowModel() {
        let wx=weather(true)
        let local=radar(0,0)
        let series=RadarWeightedForecast.make(snapshot:wx,models:[],
                                          radar:local,now:start,horizon:180)
        XCTAssertLessThan(series[0].rate,0.15)
        XCTAssertLessThan(series[30].rate,0.15)
        XCTAssertLessThan(series[55].rate,0.15)
        XCTAssertGreaterThan(series[95].rate,0.15)
        let estimate=RainShortFusion.estimateUsingLocal(weather:wx,
                              radar:local,models:[],now:start)
        XCTAssertFalse(estimate.rainingNow)
        XCTAssertTrue(estimate.radarBased)
        XCTAssertTrue(estimate.method.contains("Radar local"))
        XCTAssertNotNil(estimate.change)
        XCTAssertGreaterThan(estimate.change!.timeIntervalSince(start),60*60)
    }

    func testRadarWetOverridesDryModelsForFirstHour() {
        let wx=weather(false)
        let local=radar(0.8,0.8)
        let series=RadarWeightedForecast.make(snapshot:wx,models:[],
                                           radar:local,now:start,horizon:120)
        XCTAssertGreaterThan(series[0].rate,0.15)
        XCTAssertGreaterThan(series[25].rate,0.15)
        XCTAssertTrue(RainShortFusion.estimateUsingLocal(
            weather:wx,radar:local,models:[],now:start).rainingNow)
    }

    func testNowcastDetectsChangeDespiteCurrentContradictoryModel() {
        let wx=weather(true)
        let local=radar(0,0.8)
        let estimate=RainShortFusion.estimateUsingLocal(
            weather:wx,radar:local,models:[],now:start)
        XCTAssertFalse(estimate.rainingNow)
        XCTAssertNotNil(estimate.change)
        let seconds=estimate.change!.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(seconds,300)
        XCTAssertLessThan(seconds,20*60)
    }

    func testFadeToModelsNeverClaimsRadarAt120Minutes() {
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:0,radarAvailable:true),1)
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:60,radarAvailable:true),1)
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:75,radarAvailable:true),0.5)
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:90,radarAvailable:true),0)
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:120,radarAvailable:true),0)
        XCTAssertEqual(RadarWeightedForecast.radarWeight(at:30,radarAvailable:false),0)
    }

    func testStaleOrUnknownCoverageNeverOverridesModel() {
        let wx=weather(true)
        let stale=radar(0,0,observedAt:start.addingTimeInterval(-3600))
        XCTAssertFalse(stale.isFresh(at:start))
        let uncertain=RadarLocalTimeline(observedAt:start,fetchedAt:start,
                          frames:radar(0,0).frames,coverageConfirmed:false)
        XCTAssertFalse(uncertain.isFresh(at:start))
        XCTAssertTrue(RainShortFusion.estimateUsingLocal(
            weather:wx,radar:uncertain,models:[],now:start).rainingNow)
    }

    func testRadarPointInterpolationIsNearestSourceFrame() {
        let local=radar(0,1)
        XCTAssertEqual(local.echo(at:start),0)
        XCTAssertEqual(local.echo(at:start.addingTimeInterval(7*60)),1)
        XCTAssertEqual(local.echo(at:start.addingTimeInterval(13*60)),1)
    }
}
