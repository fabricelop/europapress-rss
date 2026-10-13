import XCTest
@testable import RainETA

final class RainShortNowcastTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func weather(_ raining: Bool = false) -> RainSnapshot {
        let values = (0...100).map { index in
            RainSample(id: index, time: start.addingTimeInterval(Double(index*15*60)),
                       precipitation: raining ? 0.3 : 0, probability: raining ? 90 : 10)
        }
        return RainSnapshot(updatedAt:start, locationName:"Prueba", temperature:15,
                            currentPrecipitation:raining ? 0.6 : 0,
                            samples:values, hours:[], days:[])
    }

    private func radar(wet: (Int)->Bool, confidence:Double = 0.85,
                       time:Date? = nil) -> RainRadarEvidence {
        RainRadarEvidence(observedAt:time ?? start,
                          movementConfidence:confidence,
                          points:(0...120).map {
            RadarMinute(minute:$0,signal:wet($0) ? 0.7 : 0.0,
                        confidence:confidence)
        })
    }

    private func models(_ wet:Bool = true) -> [RainShortModel] {
        ["ECMWF","ICON","GFS"].map {
            RainShortModel(name:$0,hours:[
                (end:start.addingTimeInterval(3600),mm:wet ? 1.2 : 0.0),
                (end:start.addingTimeInterval(7200),mm:wet ? 1.2 : 0.0),
                (end:start.addingTimeInterval(10800),mm:wet ? 1.2 : 0.0)
            ])
        }
    }

    func testRadarArrivingMaintainsCountdownAndUncertainty() {
        let now=start.addingTimeInterval(3*60)
        let forecast=radar(wet:{ $0 >= 24 })
        let result=RainShortFusion.estimate(weather:weather(),radar:forecast,
                                            models:models(),now:now)
        XCTAssertTrue(result.radarBased)
        XCTAssertFalse(result.rainingNow)
        XCTAssertTrue(result.method.contains("Radar + modelos"))
        XCTAssertNotNil(result.change)
        let minutes=result.change!.timeIntervalSince(now)/60
        XCTAssertGreaterThanOrEqual(minutes,15)
        XCTAssertLessThanOrEqual(minutes,25)
        XCTAssertLessThan(result.windowStart!,result.change!)
        XCTAssertGreaterThan(result.windowEnd!,result.change!)
        XCTAssertTrue(result.isUsable(at:now))
    }

    func testRadarDryingCanCountDownToEndOfRain() {
        let result=RainShortFusion.estimate(
            weather:weather(true),radar:radar(wet:{ $0 < 35 }),
            models:models(false),now:start)
        XCTAssertTrue(result.radarBased)
        XCTAssertTrue(result.rainingNow)
        XCTAssertNotNil(result.change)
    }

    func testStaleOrUnreliableRadarFallsBackTo15MinuteModel() {
        let old=radar(wet:{$0 >= 22},time:start.addingTimeInterval(-20*60))
        let stale=RainShortFusion.estimate(weather:weather(),radar:old,
                                          models:models(),now:start)
        XCTAssertFalse(stale.radarBased)
        let weak=RainShortFusion.estimate(
            weather:weather(),radar:radar(wet:{$0 >= 22},confidence:0.12),
            models:models(),now:start)
        XCTAssertFalse(weak.radarBased)
        XCTAssertEqual(weak.method,"Modelo · intervalos de 15 min")
    }

    func testContraryModelsDoNotConfirmWeakRadarMotion() {
        let result=RainShortFusion.estimate(
            weather:weather(),radar:radar(wet:{$0 >= 20},confidence:0.5),
            models:models(false),now:start)
        XCTAssertFalse(result.radarBased)
    }

    func testRadarNoSustainedTransitionIsNotInvented() {
        let spike=radar(wet:{ $0 == 23 || $0 == 25 })
        let result=RainShortFusion.estimate(weather:weather(),radar:spike,
                                            models:models(),now:start)
        XCTAssertFalse(result.radarBased)
    }

    func testHourlyModelUsesPrecedingHourAndParsesUTC() {
        let example = """
        {"hourly":{"time":["2027-01-15T12:00","2027-01-15T13:00"],"precipitation":[0.0,0.3]}}
        """.data(using:.utf8)!
        let result=RainShortModelAPI.parse(name:"ICON",data:example)
        XCTAssertEqual(result?.hours.count,2)
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let one=calendar.date(from:DateComponents(year:2027,month:1,day:15,hour:12,minute:30))!
        XCTAssertEqual(result?.predictsRain(at:one),true)
        XCTAssertEqual(result?.predictsRain(at:one.addingTimeInterval(-3600)),false)
    }

    func testEstimateExpiresAndCannotLeaveZeroCountdownOnScreenForever() {
        let result=RainShortFusion.estimate(weather:weather(),
                        radar:radar(wet:{$0 >= 20}),models:models(),now:start)
        XCTAssertTrue(result.isUsable(at:start))
        XCTAssertFalse(result.isUsable(at:start.addingTimeInterval(13*60)))
    }
}
