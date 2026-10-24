import Foundation
import CoreLocation
import MapKit
import Security

enum SitePlaceOrigin: String, Codable, CaseIterable {
    case foursquare = "Foursquare"
    case openStreetMap = "OpenStreetMap"
    case apple = "Apple Maps"
}

struct SitePlaceResult: Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let source: SitePlaceOrigin
    let distance: Double
    let inGrid: Bool
}

/// Search labels are actual records from the named dataset. A nearby pin
/// is never considered proof that the user visited that business.
enum SitePOISearch {
    private struct FoursquarePayload: Decodable {
        struct Place: Decodable {
            let fsq_place_id: String
            let name: String
            let latitude: Double
            let longitude: Double
        }
        let results: [Place]
    }

    private struct OverpassPayload: Decodable {
        struct Element: Decodable {
            struct Center: Decodable { let lat: Double; let lon: Double }
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let center: Center?
            let tags: [String:String]?
        }
        let elements: [Element]
    }

    static func foursquare(center: CLLocationCoordinate2D,
                           cell: Cell, query: String?,
                           serviceKey: String) async throws -> [SitePlaceResult] {
        guard !serviceKey.isEmpty else { return [] }
        var components=URLComponents(string:"https://places-api.foursquare.com/places/search")!
        let text=query?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        components.queryItems=[
            URLQueryItem(name:"ll",value:"\(center.latitude),\(center.longitude)"),
            URLQueryItem(name:"radius",value:text.isEmpty ? "550" : "10000"),
            URLQueryItem(name:"limit",value:"50"),
            URLQueryItem(name:"sort",value:text.isEmpty ? "DISTANCE" : "RELEVANCE"),
            URLQueryItem(name:"fields",value:"fsq_place_id,name,latitude,longitude")
        ]
        if !text.isEmpty { components.queryItems?.append(URLQueryItem(name:"query",value:text)) }
        var request=URLRequest(url:components.url!)
        request.timeoutInterval=9
        request.setValue("Bearer \(serviceKey)",forHTTPHeaderField:"Authorization")
        request.setValue("2025-06-17",forHTTPHeaderField:"X-Places-Api-Version")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let status=(response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw SitePlacesError.unavailable
        }
        let found=try JSONDecoder().decode(FoursquarePayload.self,from:data)
        return found.results.compactMap { place in
            makeResult(id:"fsq:\(place.fsq_place_id)",name:place.name,
                       latitude:place.latitude,longitude:place.longitude,
                       source:.foursquare,center:center,cell:cell)
        }
    }

    static func openStreetMap(center: CLLocationCoordinate2D,
                              cell: Cell,
                              query: String?) async throws -> [SitePlaceResult] {
        // Public Overpass is called ONLY on explicit opening/search of the
        // chooser, never from the GPS pipeline. Small bounded request.
        let radius=query == nil ? 340 : 650
        let point="\(radius),\(center.latitude),\(center.longitude)"
        let q="[out:json][timeout:7];(" +
            "nwr(around:\(point))[name][amenity];" +
            "nwr(around:\(point))[name][shop];" +
            "nwr(around:\(point))[name][office];" +
            "nwr(around:\(point))[name][leisure];" +
            "nwr(around:\(point))[name][tourism];" +
            "nwr(around:\(point))[name][building=public];" +
            ");out center 180;"
        var request=URLRequest(url:URL(string:"https://overpass-api.de/api/interpreter")!)
        request.httpMethod="POST"
        request.timeoutInterval=9
        request.setValue("MiMapaDelTiempo/1.0.67 (iOS personal place search)",forHTTPHeaderField:"User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField:"Content-Type")
        var body=URLComponents()
        body.queryItems=[URLQueryItem(name:"data",value:q)]
        request.httpBody=body.percentEncodedQuery?.data(using:.utf8)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let status=(response as? HTTPURLResponse)?.statusCode,status == 200 else {
            throw SitePlacesError.unavailable
        }
        let result=try JSONDecoder().decode(OverpassPayload.self,from:data)
        let normalized=query?.folding(options:[.caseInsensitive,.diacriticInsensitive],
                                      locale:.current).trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return result.elements.compactMap { item -> SitePlaceResult? in
            guard let title=item.tags?["name"],!title.isEmpty else { return nil }
            if !normalized.isEmpty {
                let lowered=title.folding(options:[.caseInsensitive,.diacriticInsensitive],
                                           locale:.current)
                let terms=normalized.split(separator:" ").filter { $0.count > 1 }
                if !lowered.contains(normalized) &&
                   !(!terms.isEmpty && terms.allSatisfy({ lowered.contains($0) })) {
                    return nil
                }
            }
            guard let lat=item.lat ?? item.center?.lat,
                  let lon=item.lon ?? item.center?.lon else { return nil }
            return makeResult(id:"osm:\(item.type):\(item.id)",name:title,
                         latitude:lat,longitude:lon,source:.openStreetMap,
                         center:center,cell:cell)
        }
    }

    static func apple(center: CLLocationCoordinate2D,cell:Cell,
                      query:String?) async throws -> [SitePlaceResult] {
        let terms=query?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let search: MKLocalSearch
        if terms.isEmpty {
            // A generic MKLocalSearch.Request() with NO text query is not a
            // nearby-POI search. It caused the regression that returned few
            // or no places. Restore Apple's dedicated POI API.
            let poi=MKLocalPointsOfInterestRequest(center:center,radius:260)
            search=MKLocalSearch(request:poi)
        } else {
            // Explicit text search is different: use natural language and
            // a broad geographic hint, never a hard 100m grid restriction.
            let region=MKCoordinateRegion(center:center,latitudinalMeters:25000,
                                          longitudinalMeters:25000)
            let request=MKLocalSearch.Request()
            request.naturalLanguageQuery=terms
            request.region=region
            request.resultTypes=[.pointOfInterest,.address]
            search=MKLocalSearch(request:request)
        }
        let response=try await search.start()
        return response.mapItems.compactMap { item in
            guard let name=item.name,!name.isEmpty else { return nil }
            let point=item.placemark.coordinate
            return makeResult(id:"apple:\(name):\(point.latitude):\(point.longitude)",
                              name:name,latitude:point.latitude,longitude:point.longitude,
                              source:.apple,center:center,cell:cell)
        }
    }

    private static func makeResult(id:String,name:String,latitude:Double,longitude:Double,
                                   source:SitePlaceOrigin,center:CLLocationCoordinate2D,
                                   cell:Cell) -> SitePlaceResult? {
        guard latitude.isFinite,longitude.isFinite,
              abs(latitude)<=90,abs(longitude)<=180,
              !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
        let origin=CLLocation(latitude:center.latitude,longitude:center.longitude)
        let meters=origin.distance(from:CLLocation(latitude:latitude,longitude:longitude))
        return SitePlaceResult(id:id,name:name,latitude:latitude,longitude:longitude,
                               source:source,distance:meters,
                               inGrid:Grid.cell(latitude:latitude,longitude:longitude)==cell)
    }

    /// Search results remain grounded in each provider's actual POI names.
    /// For explicit text searches name relevance comes first; otherwise
    /// same-square matches, proximity and source precedence win. This avoids
    /// putting unrelated near-grid names above the business the user typed.
    static func ranked(_ values:[SitePlaceResult], query:String?=nil,
                       maxCount:Int=40) -> [SitePlaceResult] {
        let priority:[SitePlaceOrigin:Int]=[.foursquare:0,.openStreetMap:1,.apple:2]
        let ordered=values.sorted { left,right in
            let la=queryScore(left.name,query:query)
            let lb=queryScore(right.name,query:query)
            if la != lb { return la > lb }
            if left.inGrid != right.inGrid { return left.inGrid }
            // Prefer established source when candidates are roughly in the
            // same locality. Distance remains dominant for distant pins.
            if abs(left.distance-right.distance)>90 {
                return left.distance < right.distance
            }
            let pa=priority[left.source,default:99]
            let pb=priority[right.source,default:99]
            if pa != pb { return pa < pb }
            if left.distance != right.distance { return left.distance < right.distance }
            return left.id < right.id
        }
        var unique:[SitePlaceResult]=[]
        for item in ordered {
            let key=folded(item.name)
            let repeated=unique.contains { previous in
                folded(previous.name) == key &&
                CLLocation(latitude:previous.latitude,longitude:previous.longitude)
                    .distance(from:CLLocation(latitude:item.latitude,longitude:item.longitude)) < 60
            }
            if !repeated { unique.append(item) }
            if unique.count >= maxCount { break }
        }
        return unique
    }

    static func queryScore(_ title:String,query:String?) -> Int {
        let q=folded(query ?? "")
        guard !q.isEmpty else { return 0 }
        let name=folded(title)
        if name == q { return 5 }
        if name.hasPrefix(q) { return 4 }
        if name.contains(q) { return 3 }
        let tokens=q.split(separator:" ").map(String.init).filter { $0.count > 1 }
        if !tokens.isEmpty && tokens.allSatisfy({ name.contains($0) }) { return 2 }
        if tokens.count > 1 && tokens.filter({ name.contains($0) }).count >= 2 { return 1 }
        return 0
    }

    private static func folded(_ string:String) -> String {
        string.folding(options:[.caseInsensitive,.diacriticInsensitive],
                       locale:Locale(identifier:"es_ES"))
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }

}

enum SitePlacesError: Error { case unavailable }

/// API token is personal and optional, never committed or stored in backups.
/// Note: for public distribution a server-side proxy is preferable.
enum SiteFoursquareCredentials {
    private static let service="es.mimapadeltiempo.foursquare.places"
    private static let account="user-provided-service-key"

    static func load() -> String? {
        let query:[String:Any]=[
            kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,
            kSecAttrAccount as String:account,
            kSecReturnData as String:true,
            kSecMatchLimit as String:kSecMatchLimitOne
        ]
        var data:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&data) == errSecSuccess,
              let bytes=data as? Data else { return nil }
        return String(data:bytes,encoding:.utf8)
    }

    static func save(_ key:String) -> Bool {
        let trimmed=key.trimmingCharacters(in:.whitespacesAndNewlines)
        let query:[String:Any]=[
            kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,
            kSecAttrAccount as String:account
        ]
        if trimmed.isEmpty { return SecItemDelete(query as CFDictionary) == errSecSuccess }
        let data=Data(trimmed.utf8)
        let updated=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var creation=query
        creation[kSecValueData as String]=data
        creation[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(creation as CFDictionary,nil)==errSecSuccess
    }
}
