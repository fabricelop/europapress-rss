import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class BioGridV53GeographicExodusTests: XCTestCase {
    private let madrid = TimeZone(identifier:"Europe/Madrid")!

    private func instant(_ raw:String)->Date {
        ISO8601DateFormatter().date(from:raw)!
    }
    private func visit(_ start:String,_ end:String,at cell:Cell)->AssignedInterval {
        AssignedInterval(start:instant(start),end:instant(end),
                         cell:cell,quality:"confirmed",source:"test")
    }

    func testNorthAndSouthArePhysicallyAboveAndBelowOnRealMap() {
        // La antigua suma/resta de "row" con igual "column" desplazaba
        // unas dos casillas lateralmente en Madrid (y más en otras latitudes).
        for (lat,lon) in [
            (40.4168,-3.7038), (48.8566,2.3522),
            (-33.8688,151.2093), (35.6762,139.6503),
            (0.0,0.0)
        ] {
            let source=Grid.cell(latitude:lat,longitude:lon)
            let center=Grid.center(source)
            let north=BioGridEngine.neighbor(source,direction:0)
            let south=BioGridEngine.neighbor(source,direction:1)
            let east=BioGridEngine.neighbor(source,direction:2)
            let west=BioGridEngine.neighbor(source,direction:3)
            XCTAssertEqual(north.row,source.row+1)
            XCTAssertEqual(south.row,source.row-1)
            XCTAssertEqual(east.row,source.row)
            XCTAssertEqual(west.row,source.row)

            // El centro de una vecina vertical debe estar al norte o sur
            // sin desvío lateral de más de media cuadrícula.
            for (destination,isNorth) in [(north,true),(south,false)] {
                let geographicCenter=Grid.center(destination)
                let transverse=CLLocation(latitude:center.latitude,
                    longitude:center.longitude)
                    .distance(from:CLLocation(latitude:center.latitude,
                        longitude:geographicCenter.longitude))
                XCTAssertLessThan(transverse,51,
                    "Vecina equivocada en lat \(lat) lon \(lon)")
                if isNorth {
                    XCTAssertGreaterThan(geographicCenter.latitude,center.latitude)
                } else {
                    XCTAssertLessThan(geographicCenter.latitude,center.latitude)
                }
            }
            XCTAssertEqual(BioGridEngine.neighbor(north,direction:1),source)
            XCTAssertEqual(BioGridEngine.neighbor(south,direction:0),source)
            XCTAssertEqual(BioGridEngine.neighbor(east,direction:3),source)
            XCTAssertEqual(BioGridEngine.neighbor(west,direction:2),source)
        }
    }

    func testOriginalSouthColumnWasNearlyTwoHundredMetersWrongInMadrid() {
        let start=Grid.cell(latitude:40.4168,longitude:-3.7038)
        let source=Grid.center(start)
        let incorrect=Grid.center(Cell(row:start.row-1,column:start.column))
        let correct=Grid.center(BioGridEngine.neighbor(start,direction:1))
        let longitudeShift={ (loc:CLLocationCoordinate2D)->Double in
            CLLocation(latitude:source.latitude,longitude:source.longitude)
                .distance(from:CLLocation(latitude:source.latitude,
                    longitude:loc.longitude))
        }
        XCTAssertGreaterThan(longitudeShift(incorrect),100)
        XCTAssertLessThan(longitudeShift(correct),51)
    }

    /// Dos familias igualadas en la casilla origen: no hay emigraciones
    /// ordinarias; tras cinco noches M deja la cuadrícula completa.
    /// Tres vecinas reciben una bacteria el lunes para forzar que el
    /// DESTINO GEOGRÁFICO SUR sea la cuadrícula vacía.
    private func fixture()->(source:Cell,south:Cell,intervals:[AssignedInterval]) {
        let source=Grid.cell(latitude:40.4168,longitude:-3.7038)
        let north=BioGridEngine.neighbor(source,direction:0)
        let south=BioGridEngine.neighbor(source,direction:1)
        let east=BioGridEngine.neighbor(source,direction:2)
        let west=BioGridEngine.neighbor(source,direction:3)
        let records=[
            visit("2026-10-19T08:00:00Z","2026-10-19T08:45:00Z",at:source),
            visit("2026-10-20T08:00:00Z","2026-10-20T08:45:00Z",at:source),
            visit("2026-10-19T10:00:00Z","2026-10-19T10:05:00Z",at:north),
            visit("2026-10-19T10:10:00Z","2026-10-19T10:15:00Z",at:east),
            visit("2026-10-19T10:20:00Z","2026-10-19T10:25:00Z",at:west)
        ]
        return (source,south,records)
    }

    func testFullExodusToActualSouthVisibleOnFollowingDay() throws {
        let f=fixture()
        let twentyFourth=BioGridEngine.simulate(f.intervals,
            now:instant("2026-10-24T12:00:00Z"),timezone:madrid)
        XCTAssertTrue(twentyFourth.exodusEvents.isEmpty)

        let twentySixth=BioGridEngine.simulate(f.intervals,
            now:instant("2026-10-26T12:00:00Z"),timezone:madrid)
        XCTAssertEqual(twentySixth.exodusEvents.count,1)
        let event=try XCTUnwrap(twentySixth.exodusEvents.first)
        XCTAssertEqual(event.source,f.source.id)
        XCTAssertEqual(event.destination,f.south.id)
        // Las batallas anteriores pueden cambiar cuál de las familias
        // queda segunda: comprobamos el estado real de la víspera,
        // nunca una identidad/cantidad supuesta.
        let previous=twentySixth.cellHistory[f.source.id]?
            .last(where:{$0.date<event.date})?.counts ??
            Array(repeating:Int64(0),count:7)
        let maximum=previous.max() ?? 0
        XCTAssertGreaterThan(maximum,0)
        XCTAssertLessThan(previous[event.family],maximum,
            "Debe abandonar la cuadrícula una familia no dominante")
        XCTAssertEqual(event.amount,previous[event.family])
        XCTAssertGreaterThan(event.amount,0)
        let departures=twentySixth.cellDays[f.source.id]?.first {
            $0.date == event.date
        }
        let arrivals=twentySixth.cellDays[f.south.id]?.first {
            $0.date == event.date
        }
        XCTAssertEqual(departures?.departures[event.family][1],event.amount)
        XCTAssertEqual(arrivals?.arrivals[event.family][0],event.amount)

        // Con ningún nacimiento ni rival nuevo, la población emigrada
        // debe seguir en el mapa al menos la jornada siguiente.
        XCTAssertEqual(twentySixth.populations[f.south.id]?[event.family],
                       event.amount)
        XCTAssertEqual(twentySixth.populations[f.source.id]?[event.family],0)
        let historical=twentySixth.cellHistory[f.south.id]?.last?.counts
        XCTAssertEqual(historical?[event.family],event.amount)

        let births=twentySixth.days.reduce(Int64(0)) {$0+$1.births.reduce(0,+)}
        let casualties=twentySixth.days.reduce(Int64(0)) {$0+$1.deaths.reduce(0,+)}
        let finalPopulation=twentySixth.populations.values.reduce(Int64(0)) {
            $0+$1.reduce(0,+)
        }
        XCTAssertEqual(finalPopulation,births-casualties)

        for (key,days) in twentySixth.cellDays {
            for day in days {
                let records=twentySixth.cellHistory[key] ?? []
                let before=records.last(where:{$0.date<day.date})?.counts ??
                    Array(repeating:Int64(0),count:7)
                let after=records.last(where:{$0.date<=day.date})?.counts ??
                    Array(repeating:Int64(0),count:7)
                for family in 0..<7 {
                    XCTAssertEqual(after[family],
                        before[family]+day.delta(family),
                        "Unbalanced \(key) on \(day.date)")
                }
            }
        }
    }
}
