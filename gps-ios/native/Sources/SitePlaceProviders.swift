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
        request.timeoutInterval=12
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
        let radius=query == nil ? 420 : 850
        let point="\(radius),\(center.latitude),\(center.longitude)"
        let q="[out:json][timeout:12];(" +
            "nwr(around:\(point))[name][amenity];" +
            "nwr(around:\(point))[name][shop];" +
            "nwr(around:\(point))[name][office];" +
            "nwr(around:\(point))[name][leisure];" +
            "nwr(around:\(point))[name][tourism];" +
            "nwr(around:\(point))[name][building=public];" +
            ");out center 180;"
        var request=URLRequest(url:URL(string:"https://overpass-api.de/api/interpreter")!)
        request.httpMethod="POST"
        request.timeoutInterval=18
        request.setValue("MiMapaDelTiempo/1.0.63 (iOS personal place search)",forHTTPHeaderField:"User-Agent")
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
                if !lowered.contains(normalized) { return nil }
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
        let req: MKLocalSearch.Request
        if terms.isEmpty {
            req=MKLocalSearch.Request()
            req.region=MKCoordinateRegion(center:center,latitudinalMeters:850,longitudinalMeters:850)
            req.resultTypes = [.pointOfInterest]
        } else {
            req=MKLocalSearch.Request()
            req.naturalLanguageQuery=terms
            req.region=MKCoordinateRegion(center:center,latitudinalMeters:20000,longitudinalMeters:20000)
            req.resultTypes=[.pointOfInterest,.address]
        }
        let response=try await MKLocalSearch(request:req).start()
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

    /// Exact source priority, then same grid and distance; deduplicate
    /// overlapping records with a similar name within 60 m.
    static func ranked(_ values:[SitePlaceResult], maxCount:Int=40) -> [SitePlaceResult] {
        let priority:[SitePlaceOrigin:Int]=[.foursquare:0,.openStreetMap:1,.apple:2]
        var unique:[SitePlaceResult]=[]
        for item in values.sorted(by:{
            if priority[$0.source] != priority[$1.source] {
                return priority[$0.source,default:99] < priority[$1.source,default:99]
            }
            if $0.inGrid != $1.inGrid { return $0.inGrid }
            return $0.distance < $1.distance
        }) {
            let key=item.name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
            let repeated=unique.contains { previous in
                previous.name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current) == key &&
                CLLocation(latitude:previous.latitude,longitude:previous.longitude)
                    .distance(from:CLLocation(latitude:item.latitude,longitude:item.longitude)) < 60
            }
            if !repeated { unique.append(item) }
            if unique.count >= maxCount { break }
        }
        return unique
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
