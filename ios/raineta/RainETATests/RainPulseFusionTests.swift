import XCTest
@testable import RainETA

final class RainPulseFusionTests: XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)

    private func model(_ name:String,_ first:Double,_ second:Double) -> RainShortModel {
        RainShortModel(name:name,hours:[
            (end:start.addingTimeInterval(3600),mm:first),
            (end:start.addingTimeInterval(7200),mm:second),
            (end:start.addingTimeInterval(10800),mm:second)
        ])
    }
    private func fineSamples() -> [RainSample] {
        (0...12).map {
            RainSample(id:$0,time:start.addingTimeInterval(Double($0*15*60)),
                       precipitation:0.25,probability:60)
        }
    }

    func testMedianAndUncertaintyUseOnlyAvailableSources() {
        let models=[model("ECMWF",0,2),model("ICON",1,2),
                    model("GFS",2,4),model("ARPEGE",3,4)]
        let points=RainPulseFusion.points(samples:fineSamples(),models:models,
                                          now:start,horizon:120,step:1)
        XCTAssertEqual(points.count,121)
        XCTAssertEqual(points[0].rateMMH,1,accuracy:0.0001)
        XCTAssertEqual(points[0].automaticMMH ?? -1,1,accuracy:0.0001)
        XCTAssertEqual(points[0].lowMMH,0,accuracy:0.0001)
        XCTAssertEqual(points[0].highMMH,3,accuracy:0.0001)
        XCTAssertEqual(points[0].availableModels,4)
        XCTAssertEqual(points[0].rainyModels,3)
        XCTAssertTrue(points[0].usesModelMedian)
        XCTAssertTrue(points[0].disagreement)
        XCTAssertEqual(points[61].rateMMH,1,accuracy:0.0001)
    }

    func testMinuteGridIsRepeatedHourlyMeanNotInventedIndependentMinuteValues() {
        let models=[model("ECMWF",0,2),model("ICON",0,3)]
        let minutes=RainPulseFusion.individual(models:models,now:start,horizon:120)
        XCTAssertEqual(minutes.count,242)
        let ecmwf=minutes.filter{$0.name=="ECMWF"}
        XCTAssertEqual(ecmwf[5].mmh,ecmwf[45].mmh)
        XCTAssertEqual(ecmwf[59].mmh,0)
        XCTAssertEqual(ecmwf[60].mmh,2)
        XCTAssertEqual(ecmwf[61].mmh,2)
        XCTAssertEqual(ecmwf[120].mmh,2)
    }

    func testMinutePulseUsesPreceding15MinuteBucketsWithoutMakingUpIntermediateRain() {
        let samples=[
            RainSample(id:0,time:start.addingTimeInterval(15*60),
                       precipitation:0,probability:15),
            RainSample(id:1,time:start.addingTimeInterval(30*60),
                       precipitation:0.5,probability:70),
            RainSample(id:2,time:start.addingTimeInterval(45*60),
                       precipitation:0,probability:20)
        ]
        let rows=RainPulseFusion.points(samples:samples,models:[
            model("ECMWF",2,2),model("ICON",2,2)],now:start,horizon:45)
        XCTAssertEqual(rows[0].rateMMH,0,accuracy:0.0001)
        XCTAssertEqual(rows[14].rateMMH,0,accuracy:0.0001)
        XCTAssertEqual(rows[15].rateMMH,2,accuracy:0.0001)
        XCTAssertEqual(rows[29].rateMMH,2,accuracy:0.0001)
        XCTAssertEqual(rows[30].rateMMH,0,accuracy:0.0001)
        // Without a 15-minute slot, use the hourly ensemble only.
        XCTAssertEqual(rows[45].rateMMH,2,accuracy:0.0001)
    }

    func testSingleModelDoesNotOverrideExistingFineForecast() {
        let samples=fineSamples()
        let single=[model("ICON",4,4)]
        let points=RainPulseFusion.points(samples:samples,models:single,
                                          now:start,horizon:30)
        XCTAssertEqual(points.count,31)
        XCTAssertEqual(points[0].rateMMH,1,accuracy:0.0001)
        XCTAssertFalse(points[0].usesModelMedian)
    }

    func testMissingModelsExcludedRatherThanCountedAsDry() {
        let empty=RainShortModel(name:"no-data",hours:[])
        let models=[model("ECMWF",0,1),model("GFS",1,1),empty]
        let points=RainPulseFusion.points(samples:[],models:models,
                                          now:start,horizon:10)
        XCTAssertEqual(points[0].availableModels,2)
        XCTAssertEqual(points[0].rainyModels,1)
        XCTAssertTrue(points[0].disagreement)
    }

    func testParseUnixTimestampsPreservesHourBoundary() {
        let t=Int(start.timeIntervalSince1970)
        let json="""
        {"hourly":{"time":[\(t+3600),\(t+7200)],"precipitation":[0,1.5]}}
        """.data(using:.utf8)!
        let parsed=RainShortModelAPI.parse(name:"ARPEGE",data:json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.rateMMH(at:start),0)
        XCTAssertEqual(parsed?.rateMMH(at:start.addingTimeInterval(3599)),0)
        XCTAssertEqual(parsed?.rateMMH(at:start.addingTimeInterval(3600)),1.5)
        XCTAssertNil(parsed?.rateMMH(at:start.addingTimeInterval(7200)))
    }

    func testModelSummaryIndicatesDisagreementOnlyWhenAvailable() {
        let mixed=[model("ECMWF",0,0),model("ICON",0.8,0.8)]
        let points=RainPulseFusion.points(samples:[],models:mixed,
                                          now:start,horizon:15)
        XCTAssertTrue((RainPulseFusion.summary(points) ?? "").contains("discrepan"))
        XCTAssertNil(RainPulseFusion.summary(
            RainPulseFusion.points(samples:fineSamples(),models:[],
                                   now:start,horizon:30)))
    }
}
