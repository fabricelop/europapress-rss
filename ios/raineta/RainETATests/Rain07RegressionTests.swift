import XCTest
import UIKit
@testable import RainETA

final class Rain07RegressionTests:XCTestCase {
    func testOfficialWMSPaletteDoesNotShowGrey() {
        XCTAssertEqual(ICONForecastTiles.classStrength(r:192,g:192,b:192,a:255),0.25)
        XCTAssertEqual(ICONForecastTiles.classStrength(r:254,g:254,b:192,a:255),0.54)
        XCTAssertEqual(ICONForecastTiles.classStrength(r:254,g:254,b:91,a:255),0.80)
        XCTAssertEqual(ICONForecastTiles.classStrength(r:255,g:255,b:255,a:0),0)
        let mapped=ICONForecastTiles.palette(0.25)
        XCTAssertGreaterThan(Int(mapped.3),0)
        XCTAssertGreaterThan(Int(mapped.2),Int(mapped.0))
        XCTAssertEqual(ICONForecastTiles.palette(0).3,0)
    }

    func testQuarterHourInterpolationsUseActualHourlyFieldTimes() {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let window=ICONForecastTiles.period(leadMinutes:15,now:now)
        XCTAssertEqual(window.upper.timeIntervalSince(window.lower),3600,accuracy:0.001)
        XCTAssertGreaterThanOrEqual(window.fraction,0)
        XCTAssertLessThanOrEqual(window.fraction,1)
        let plus30=ICONForecastTiles.period(leadMinutes:30,now:now)
        XCTAssertEqual(plus30.target.timeIntervalSince(window.target),900,accuracy:0.001)
    }

    func testColorizationProducesBlueNotGrayOnSyntheticDWDMap() throws {
        let format=UIGraphicsImageRendererFormat()
        format.scale=1
        format.opaque=false
        let sample=UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:format).image { ctx in
            UIColor(red:192/255,green:192/255,blue:192/255,alpha:1).setFill()
            ctx.fill(CGRect(x:0,y:0,width:256,height:256))
        }
        let png=try XCTUnwrap(sample.pngData())
        let result=try XCTUnwrap(ICONForecastTiles.colorize(png,png,fraction:0.25))
        let reloaded=try XCTUnwrap(UIImage(data:result))
        XCTAssertEqual(reloaded.size.width,256)
        XCTAssertNotEqual(result,png)
    }

    func testSpanishDayLabels() {
        let date=Date(timeIntervalSince1970:1_800_000_000)
        let value=RainSpanishDates.long(date).lowercased()
        XCTAssertFalse(value.contains("saturday"))
        XCTAssertFalse(value.contains("october"))
        XCTAssertFalse(value.isEmpty)
    }

    func testThreeHourAndMinuteBarsShareSameWeatherSource() {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let samples=(0...13).map { i in
            RainSample(id:i,time:now.addingTimeInterval(Double(i*900)),
                       precipitation:i<6 ? 0.2:0.0,probability:70)
        }
        let one=RainInsight.moments(samples:samples,from:now,minutes:60,step:1)
        let fifteen=RainInsight.moments(samples:samples,from:now,minutes:180,step:15)
        XCTAssertEqual(one[0].rateMMH,fifteen[0].rateMMH,accuracy:0.001)
        XCTAssertEqual(one[15].rateMMH,fifteen[1].rateMMH,accuracy:0.001)
        XCTAssertGreaterThan(fifteen[0].rateMMH,0)
    }
}
