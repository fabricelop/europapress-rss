import XCTest
@testable import MiMapaDelTiempo

final class SitePrivateManagementTests:XCTestCase {
    private func privateSite(_ name:String = "Mi lugar") -> IdentifiedSite {
        IdentifiedSite(name:name,latitude:40.45,longitude:-3.62,origin:"private")
    }
    func testRenamePreservesIdentityAndCoordinates() {
        var sites=[privateSite()]
        let id=sites[0].id
        XCTAssertTrue(SitePrivateManagement.update(id:id,name:"  Casa de Ana ",
            latitude:sites[0].latitude,longitude:sites[0].longitude,sites:&sites))
        XCTAssertEqual(sites[0].name,"Casa de Ana")
        XCTAssertEqual(sites[0].id,id)
        XCTAssertEqual(sites[0].latitude,40.45)
    }
    func testLocationCanBeCorrectedWithoutChangingSiteIdentity() {
        var sites=[privateSite()]
        let id=sites[0].id
        XCTAssertTrue(SitePrivateManagement.update(id:id,name:"Mi lugar",
            latitude:40.456,longitude:-3.633,sites:&sites))
        XCTAssertEqual(sites[0].id,id)
        XCTAssertEqual(sites[0].latitude,40.456)
        XCTAssertEqual(sites[0].longitude,-3.633)
    }
    func testNonprivateMapPlacesCannotBeEditedOrDeleted() {
        var sites=[IdentifiedSite(name:"Un sitio",latitude:40.4,
                                   longitude:-3.7,origin:"openstreetmap")]
        var assignments:[SiteStayAssignment]=[]
        var parts:[SiteStayPart]=[]
        let id=sites[0].id
        XCTAssertFalse(SitePrivateManagement.update(id:id,name:"Cambio",
                       latitude:40,longitude:-3,sites:&sites))
        XCTAssertFalse(SitePrivateManagement.delete(id:id,sites:&sites,
                         assignments:&assignments,parts:&parts))
        XCTAssertEqual(sites.count,1)
    }
    func testDeleteUnlinksHistoryButPreservesPartBoundaries() {
        let site=privateSite()
        var sites=[site,privateSite("Otro lugar")]
        let now=Date(timeIntervalSince1970:1000)
        var assignments=[SiteStayAssignment(
            id:"1|1000",cellID:"1",startedAt:now,siteID:site.id,confirmed:true),
            SiteStayAssignment(
            id:"2|1000",cellID:"2",startedAt:now,siteID:sites[1].id,confirmed:true)]
        var parts=[
            SiteStayPart(stayID:"3|1000",from:now,to:now.addingTimeInterval(600),
                         kind:.place,siteID:site.id,confirmed:true),
            SiteStayPart(stayID:"3|1000",from:now.addingTimeInterval(600),
                         to:now.addingTimeInterval(900),
                         kind:.place,siteID:sites[1].id,confirmed:true)
        ]
        XCTAssertEqual(SitePrivateManagement.linkedStays(id:site.id,
            assignments:assignments,parts:parts),2)
        let from=parts[0].from, to=parts[0].to
        XCTAssertTrue(SitePrivateManagement.delete(id:site.id,
          sites:&sites,assignments:&assignments,parts:&parts))
        XCTAssertEqual(sites.count,1)
        XCTAssertEqual(assignments.count,1)
        XCTAssertEqual(parts.count,2)
        XCTAssertEqual(parts[0].from,from)
        XCTAssertEqual(parts[0].to,to)
        XCTAssertEqual(parts[0].kind,.unassigned)
        XCTAssertNil(parts[0].siteID)
        XCTAssertFalse(parts[0].confirmed)
        XCTAssertEqual(parts[1].kind,.place)
        XCTAssertNotNil(parts[1].siteID)
        XCTAssertEqual(parts[1].to.timeIntervalSince(parts[0].from),900)
    }
    func testUnknownIDAndInvalidNameCannotCorruptState() {
        var sites=[privateSite()]
        let original=sites
        XCTAssertFalse(SitePrivateManagement.update(id:sites[0].id,name:"  ",
            latitude:40.4,longitude:-3.7,sites:&sites))
        XCTAssertFalse(SitePrivateManagement.update(id:UUID(),name:"A",
            latitude:40.4,longitude:-3.7,sites:&sites))
        XCTAssertEqual(sites,original)
    }
    func testDeleteLegacyAssignmentCreatesUnidentifiedPartAndKeepsGPS() {
        let site=privateSite()
        let from=Date(timeIntervalSince1970:1000)
        let to=Date(timeIntervalSince1970:1700)
        let cell=Cell(row:100,column:500)
        let start=SiteStayPolicy.visitKey(cellID:cell.id,entered:from)
        let assigned=SiteStayAssignment(id:start,cellID:cell.id,
                         startedAt:from,siteID:site.id,confirmed:true)
        let intervals=[AssignedInterval(start:from,end:to,cell:cell,
                                       quality:"observado",source:"gps")]
        let newParts=SitePrivateManagement.unassignedPartsForDeletedLegacy(
            id:site.id,assignments:[assigned],intervals:intervals,existingParts:[])
        XCTAssertEqual(newParts.count,1)
        XCTAssertEqual(newParts[0].kind,.unassigned)
        XCTAssertEqual(newParts[0].from,from)
        XCTAssertEqual(newParts[0].to,to)
        XCTAssertNil(newParts[0].siteID)
        XCTAssertEqual(intervals[0].seconds,700)
        XCTAssertTrue(SiteStayHistory.valid(newParts,
                  for:SiteStayHistory.extract(intervals)[0]))
    }

    func testDeleteSamePrivateSiteTwiceIsSafe() {
        let site=privateSite()
        var sites=[site]
        var assignments:[SiteStayAssignment]=[]
        var parts:[SiteStayPart]=[]
        XCTAssertTrue(SitePrivateManagement.delete(id:site.id,sites:&sites,
                    assignments:&assignments,parts:&parts))
        XCTAssertFalse(SitePrivateManagement.delete(id:site.id,sites:&sites,
                    assignments:&assignments,parts:&parts))
    }
}
