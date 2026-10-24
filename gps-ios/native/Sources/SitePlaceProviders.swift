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

    /// Build server-side POI queries. The old implementation downloaded at
    /// most 180 unfiltered nearby records and then filtered them locally.
    /// Schools, offices and long-named places were often never in that page.
    static func overpassQuery(center: CLLocationCoordinate2D,
                              query: String?) -> String {
        let typed=query?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let matcher=strongPlaceTerm(in:typed)
        let typedSearch = !typed.isEmpty
        let radius = typedSearch ? (matcher == nil ? 2600 : 5000) : 350
        let point="\(radius),\(center.latitude),\(center.longitude)"
        let categories=["amenity","shop","office","leisure","tourism","craft"]
        var clauses:[String]=[]
        if let matcher {
            for type in categories {
                // Match the establishment NAME at Overpass, not after an
                // arbitrary truncated list of unfiltered POIs.
                clauses.append("nwr(around:\(point))[\"\(type)\"][\"name\"~\"\(matcher)\",i];")
            }
            // Some education and civic buildings have only a building tag.
            clauses.append("nwr(around:\(point))[\"building\"~\"^(school|university|public|civic)$\"][\"name\"~\"\(matcher)\",i];")
        } else if typedSearch {
            let normalized=typed.folding(options:[.caseInsensitive,.diacriticInsensitive],
                                          locale:Locale(identifier:"es_ES")).lowercased()
            let schoolWords=["colegio","escuela","instituto","educacion","educación","universidad"]
            let sportsWords=["polideportivo","gimnasio","deportivo","deportes"]
            if schoolWords.contains(where:{ normalized.contains($0) }) {
                clauses.append("nwr(around:\(point))[\"amenity\"~\"^(school|college|university|kindergarten)$\"][name];")
                clauses.append("nwr(around:\(point))[\"building\"=\"school\"][name];")
            } else if sportsWords.contains(where:{normalized.contains($0)}) {
                clauses.append("nwr(around:\(point))[\"leisure\"~\"^(sports_centre|fitness_centre|stadium|pitch)$\"][name];")
                clauses.append("nwr(around:\(point))[\"sport\"][name];")
            } else {
                let safe=escapedOverpassRegex(typed)
                for type in categories {
                    clauses.append("nwr(around:\(point))[\"\(type)\"][\"name\"~\"\(safe)\",i];")
                }
            }
        } else {
            for type in categories {
                clauses.append("nwr(around:\(point))[\"\(type)\"][name];")
            }
        }
        // Bound server output even for popular generic categories.
        return "[out:json][timeout:12];(" + clauses.joined() + ");out center 260;"
    }

    /// Pick a meaningful, venue-identifying word instead of looking for an
    /// exact complete phrase. This is generic language handling, not a
    /// database of manually added business names.
    static func strongPlaceTerm(in query:String) -> String? {
        let generic:Set<String>=["el","la","los","las","de","del","en","un","una",
          "colegio","escuela","instituto","centro","academia","universidad",
          "polideportivo","deportivo","gimnasio","restaurante","cafeteria",
          "cafetería","hotel","oficina","tienda","museo","parque","plaza",
          "calle","avenida","paseo"]
        let words=query.split(whereSeparator:{ $0.isWhitespace || $0.isPunctuation })
                       .map(String.init)
        guard let candidate=words.first(where: {
            $0.count >= 3 &&
            !generic.contains($0.folding(options:[.caseInsensitive,.diacriticInsensitive],
                                            locale:Locale(identifier:"es_ES")).lowercased())
        }) else { return nil }
        return escapedOverpassRegex(candidate)
    }

    private static func escapedOverpassRegex(_ word:String) -> String {
        // Overpass matches POSIX regex, but user text is not regex syntax.
        // Accept unaccented Spanish searches for accented venue names.
        var pattern=""
        for char in word.folding(options:.diacriticInsensitive,
                                 locale:Locale(identifier:"es_ES")).lowercased() {
            switch char {
            case "a": pattern += "[aáàäâ]"
            case "e": pattern += "[eéèëê]"
            case "i": pattern += "[iíìïî]"
            case "o": pattern += "[oóòöô]"
            case "u": pattern += "[uúùüû]"
            case "n": pattern += "[nñ]"
            case "c": pattern += "[cç]"
            default:
                pattern += NSRegularExpression.escapedPattern(for:String(char))
            }
        }
        // Overpass QL string quoting requires escaped slash and quote.
        return pattern.replacingOccurrences(of:"\\",with:"\\\\")
                      .replacingOccurrences(of:"\"",with:"\\\"")
    }

    static func openStreetMap(center: CLLocationCoordinate2D,
                              cell: Cell,
                              query: String?) async throws -> [SitePlaceResult] {
        let statement=overpassQuery(center:center,query:query)
        var request=URLRequest(url:URL(string:"https://overpass-api.de/api/interpreter")!)
        request.httpMethod="POST"
        request.timeoutInterval=15
        request.setValue("MiMapaDelTiempo/1.0.69 (user-triggered OSM search)",forHTTPHeaderField:"User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField:"Content-Type")
        var body=URLComponents()
        body.queryItems=[URLQueryItem(name:"data",value:statement)]
        request.httpBody=body.percentEncodedQuery?.data(using:.utf8)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let status=(response as? HTTPURLResponse)?.statusCode,status == 200 else {
            throw SitePlacesError.unavailable
        }
        let result=try JSONDecoder().decode(OverpassPayload.self,from:data)
        // The query was already filtered by tag / place name by Overpass.
        // Keep titles exactly as stored there; never construct POI names.
        return result.elements.compactMap { item -> SitePlaceResult? in
            guard let title=item.tags?["name"],!title.isEmpty,
                  let lat=item.lat ?? item.center?.lat,
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
            // Do not return cities/streets as if they were businesses.
            request.resultTypes=[.pointOfInterest]
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
            // A nearby school whose name contains "Osuna" must win over
            // the distant locality "Osuna" despite a perfect exact match.
            if query != nil && (la > 0 || lb > 0) {
                let localA=left.distance <= 3500
                let localB=right.distance <= 3500
                if localA != localB && (la > 0 && lb > 0 ||
                                       max(left.distance,right.distance) > 8000) {
                    return localA
                }
            }
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
