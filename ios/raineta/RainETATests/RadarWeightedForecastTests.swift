import XCTest
import UIKit
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
    func testMadridCoordinateMapsToSameTileAsVisibleRadar() {
        let point=RadarLocalAPI.tilePoint(latitude:40.4168,longitude:-3.7038)
        XCTAssertNotNil(point)
        XCTAssertEqual(point?.x,62)
        XCTAssertEqual(point?.y,48)
        XCTAssertEqual(point?.pixelX,174)
        XCTAssertEqual(point?.pixelY,67)
        let url=RadarLocalAPI.tileURL(host:"https://api.librewxr.net",
                          path:"/v2/radar/1792269600",point:point!)
        XCTAssertEqual(url?.absoluteString,
           "https://api.librewxr.net/v2/radar/1792269600/256/7/62/48/2/1_1.png")
        XCTAssertNil(RadarLocalAPI.tilePoint(latitude:Double.nan,longitude:0))
        XCTAssertNil(RadarLocalAPI.tileURL(host:"https://api.librewxr.net",
                      path:"/v2/coverage/0",point:point!))
    }

    func testTransparentRadarTileIsDryOnlyWhenActuallyDownloaded() {
        guard let point=RadarLocalAPI.tilePoint(latitude:40.4168,
                                               longitude:-3.7038) else {
            XCTFail("Madrid projection failed");return
        }
        let format=UIGraphicsImageRendererFormat()
        format.opaque=false
        format.scale=1
        let transparent=UIGraphicsImageRenderer(size:CGSize(width:256,height:256),
                      format:format).image {_ in}
        let dry=RadarLocalAPI.wetFraction(transparent.pngData()!,point:point)
        XCTAssertEqual(dry ?? -1,0,accuracy:0.001)

        let rainy=UIGraphicsImageRenderer(size:CGSize(width:256,height:256),
                      format:format).image {ctx in
            UIColor.cyan.setFill()
            ctx.fill(CGRect(x:point.pixelX-5,y:point.pixelY-5,
                            width:11,height:11))
        }
        XCTAssertGreaterThan(RadarLocalAPI.wetFraction(rainy.pngData()!,point:point) ?? 0,0.6)
        let distant=UIGraphicsImageRenderer(size:CGSize(width:256,height:256),
                      format:format).image {ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x:128,y:128,width:10,height:10))
        }
        XCTAssertEqual(RadarLocalAPI.wetFraction(distant.pngData()!,point:point) ?? -1,
                       0,accuracy:0.001)
        XCTAssertNil(RadarLocalAPI.wetFraction(Data("not png".utf8),point:point))
    }

    func testObservedOnlyRadarOverridesWetModelForCurrentConditions() {
        let now=start.addingTimeInterval(8*60)
        let local=RadarLocalTimeline(
            observedAt:start,fetchedAt:now,
            frames:[RadarLocalFrame(date:start.addingTimeInterval(-600),echo:0),
                    RadarLocalFrame(date:start,echo:0)],
            coverageConfirmed:true)
        XCTAssertTrue(local.isFresh(at:now))
        XCTAssertFalse(local.hasFutureFrames)
        let series=RadarWeightedForecast.make(snapshot:weather(true),models:[],
                                       radar:local,now:now,horizon:120)
        XCTAssertLessThan(series[0].rate,0.15)
        XCTAssertLessThan(series[5].rate,0.15)
        let state=RainShortFusion.estimateUsingLocal(weather:weather(true),
                                                     radar:local,models:[],now:now)
        XCTAssertFalse(state.rainingNow)
        XCTAssertTrue(state.method.contains("observado"))
        XCTAssertTrue(state.method.contains("modelos"))
    }

    func testObservedDryDoesNotBecomeNowcastWetAtCurrentMinute() {
        let now=start.addingTimeInterval(10*60)
        let timeline=radar(0,0.9)
        let series=RadarWeightedForecast.make(snapshot:weather(true),models:[],
                                      radar:timeline,now:now,horizon:60)
        XCTAssertEqual(series[0].rate,0,accuracy:0.0001)
        XCTAssertGreaterThan(series[7].rate,0.15)
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
        XCTAssertTrue(estimate.method.contains("Radar observado"))
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
