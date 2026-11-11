import XCTest
@testable import RainETA

/// Native visual tests: the wave must never turn missing or uncertain data
/// into a confirmed dry/rainy episode. No weather authority is changed here.
final class RainWaveTests: XCTestCase {
    private func p(_ minute:Int,_ rate:Double?,probability:Double?=nil,
                   snow:Bool=false)->RainWavePoint {
        RainWavePoint(minute:minute,rate:rate,probability:probability,snow:snow)
    }

    func testWetPossibleDryAndUnknownStayDistinct() {
        XCTAssertEqual(RainWaveForecast.signal(p(0,nil)),.unknown)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0)),.dry)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0.04)),.possible)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0.8)),.wet)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0.8,probability:32)),.possible)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0.8,probability:70)),.wet)
        XCTAssertEqual(RainWaveForecast.signal(p(0,0,probability:35)),.possible)
        XCTAssertEqual(RainWaveForecast.signal(p(0,-1)),.unknown)
        XCTAssertEqual(RainWaveForecast.signal(p(0,.infinity)),.unknown)
        XCTAssertEqual(RainWaveForecast.signal(p(0,1.2,probability:60,snow:true)),.wet)
    }

    func testWindowsKeepRealDryGapsAndPossibleRisk() {
        let points=[
            p(0,0),p(5,0),p(10,0.06),p(15,1.2),
            p(20,2.8),p(25,0),p(30,nil)
        ]
        let spans=RainWaveForecast.spans(points)
        XCTAssertEqual(spans.map(\.signal),[.dry,.possible,.wet,.dry,.unknown])
        XCTAssertEqual(spans.map(\.count),[2,1,2,1,1])
        XCTAssertEqual(spans[2].peak,2.8,accuracy:0.001)
        XCTAssertEqual(spans[2].first,3)
        XCTAssertEqual(spans[2].end,5)
    }

    func testUnknownCannotBeCountedAsDryOrZeroPeak() {
        let partial=[p(0,0),p(5,nil),p(10,0)]
        XCTAssertFalse(RainWaveForecast.fullyCovered(partial,expected:3))
        XCTAssertEqual(RainWaveForecast.spans(partial).map(\.signal),[.dry,.unknown,.dry])
        XCTAssertNil(RainWaveForecast.firstRain(partial))
        XCTAssertEqual(RainWaveForecast.peak(partial),0,accuracy:0.001)
        XCTAssertTrue(RainWaveForecast.fullyCovered([p(0,0),p(5,0)],expected:2))
    }

    func testWaveDoesNotPromoteHighRateWithLowProbability() {
        let data=[
            p(0,0),p(60,8.0,probability:25),
            p(120,1.8,probability:45),p(180,0)
        ]
        XCTAssertEqual(RainWaveForecast.peak(data),1.8,accuracy:0.001)
        XCTAssertEqual(RainWaveForecast.firstRain(data)?.first,2)
        XCTAssertEqual(RainWaveForecast.spans(data)[1].signal,.possible)
    }

    func testMissingTemporalSlotsDoNotMergeIntoContinuousRain() {
        let data=[p(0,1),p(5,1.5),p(20,2),p(25,2)]
        let spans=RainWaveForecast.spans(data)
        XCTAssertEqual(spans.count,2)
        XCTAssertEqual(spans.map(\.count),[2,2])
    }
}
