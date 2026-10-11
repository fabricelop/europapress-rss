import XCTest
@testable import MiMapaDelTiempo

final class LiveCounterProjectionTests: XCTestCase {
    private let initial=Date(timeIntervalSince1970:1_000_000)

    private func extra(now seconds:TimeInterval,
                       fix:TimeInterval,
                       cache:TimeInterval,
                       stay:TimeInterval=0) -> TimeInterval {
        LiveCounterProjection.provisionalSeconds(
            recording:true,currentLocationInTarget:true,
            lastFix:initial.addingTimeInterval(fix),
            cacheEnd:initial.addingTimeInterval(cache),
            currentVisitStart:initial.addingTimeInterval(stay),
            periodStart:nil,
            now:initial.addingTimeInterval(seconds))
    }

    func testConfirmedCacheMayRefreshEveryFiveSecondsButDisplayAdvancesEverySecond() {
        let baseline:TimeInterval=7200
        // La posición GPS cambia cada segundo. La normalización solo se
        // recalcula en los segundos 0, 5 y 10; la cifra no debe saltar.
        for second in 0...15 {
            let cacheSecond=Double((second/5)*5)
            let oldConfirmed=baseline+cacheSecond
            let display=oldConfirmed+extra(now:Double(second),
                                           fix:Double(second),
                                           cache:cacheSecond)
            XCTAssertEqual(display,baseline+Double(second),accuracy:0.001,
                           "La cifra visible debe subir exactamente 1s por tic")
        }
    }

    func testGpsArrivalDoesNotRestartProvisionalClock() {
        // Antes se usaba la fecha del último fix como ancla y el número
        // aparente se detenía/reiniciaba cada vez que llegaba otro GPS.
        XCTAssertEqual(extra(now:1,fix:1,cache:0),1)
        XCTAssertEqual(extra(now:2,fix:2,cache:0),2)
        XCTAssertEqual(extra(now:3,fix:3,cache:0),3)
        XCTAssertEqual(extra(now:4,fix:4,cache:0),4)
        XCTAssertEqual(extra(now:5,fix:5,cache:0),5)
    }

    func testStaleFixStopsAtLimitWithoutNegativeTimeJump() {
        XCTAssertEqual(extra(now:119,fix:0,cache:0),119,accuracy:0.001)
        XCTAssertEqual(extra(now:120,fix:0,cache:0),120,accuracy:0.001)
        XCTAssertEqual(extra(now:121,fix:0,cache:0),120,accuracy:0.001)
        XCTAssertEqual(extra(now:300,fix:0,cache:0),120,accuracy:0.001)
    }

    func testNewVisitDoesNotClaimEarlierCachedGap() {
        XCTAssertEqual(extra(now:200,fix:200,cache:100,stay:195),5,accuracy:0.001)
    }

    func testNoProvisionalWhenNotRecordingOrNotInTarget() {
        let now=initial.addingTimeInterval(5)
        XCTAssertEqual(LiveCounterProjection.provisionalSeconds(
            recording:false,currentLocationInTarget:true,
            lastFix:initial,cacheEnd:initial,
            currentVisitStart:initial,periodStart:nil,now:now),0)
        XCTAssertEqual(LiveCounterProjection.provisionalSeconds(
            recording:true,currentLocationInTarget:false,
            lastFix:initial,cacheEnd:initial,
            currentVisitStart:initial,periodStart:nil,now:now),0)
    }

    func testPeriodStartRespectedWithoutAddingPastSeconds() {
        let extra=LiveCounterProjection.provisionalSeconds(
            recording:true,currentLocationInTarget:true,
            lastFix:initial.addingTimeInterval(5),
            cacheEnd:initial,
            currentVisitStart:initial,
            periodStart:initial.addingTimeInterval(4),
            now:initial.addingTimeInterval(6))
        XCTAssertEqual(extra,2,accuracy:0.001)
    }
}
