import Foundation
import CoreLocation

struct PlaceListRow: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D?
}

@MainActor extension RainStore {
    var allPlaceRows: [PlaceListRow] {
        [PlaceListRow(id: "gps", name: "Mi ubicación · GPS", coordinate: gpsCoordinate)] +
        savedPlaces.map { PlaceListRow(id: $0.id, name: $0.name, coordinate: $0.coordinate) }
    }

    var isSelectedSaved: Bool { selectedPlaceID != "gps" }

    var currentSelectionSaved: Bool {
        savedPlaces.contains {
            abs($0.latitude - coordinate.latitude) < 0.0015 &&
            abs($0.longitude - coordinate.longitude) < 0.0015
        }
    }

    func moveSavedPlaces(from offsets:IndexSet,to destination:Int) {
        savedPlaces.move(fromOffsets:offsets,toOffset:destination)
        persistPlaces()
    }

    func persistPlaces() {
        if let data = try? JSONEncoder().encode(savedPlaces) {
            UserDefaults.standard.set(data, forKey: "raineta.savedPlaces.v1")
        }
        UserDefaults.standard.set(selectedPlaceID, forKey: "raineta.selectedPlace.v1")
    }

    func selectPlace(_ id: String) {
        guard id != selectedPlaceID || snapshot == nil else { return }
        if id == "gps" {
            selectedPlaceID = "gps"
            coordinate = gpsCoordinate ?? CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038)
            name = gpsCoordinate == nil ? "Madrid · provisional" : gpsPlaceName
        } else if let item = savedPlaces.first(where: { $0.id == id }) {
            selectedPlaceID = item.id
            coordinate = item.coordinate
            name = item.name
        } else { return }
        persistPlaces()
        placeSelectionRevision += 1
        snapshot = nil
        projection = nil
        futureField = nil
        radarFutureMinutes = 0
        radarIndex = max(0, radar.frames.count-1)
        Task {
            await updateLivePlaceWhileLoading()
            await refresh(force: true)
        }
    }

    func addPlace(name: String, latitude: Double, longitude: Double, select: Bool = true) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return }
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let existing = savedPlaces.first {
            abs($0.latitude - latitude) < 0.0015 && abs($0.longitude - longitude) < 0.0015
        }
        if let existing {
            if select { selectPlace(existing.id) }
            return
        }
        let item = SavedRainPlace(name: cleaned.isEmpty ? "Lugar guardado" : cleaned,
                                  latitude: latitude, longitude: longitude)
        savedPlaces.append(item)
        persistPlaces()
        summariesCheckedAt = .distantPast
        if select { selectPlace(item.id) }
        Task { await refreshSummaries(force: true) }
    }

    func saveGPSPlace(named customName:String? = nil) {
        guard let gps=gpsCoordinate else {
            status="Primero debe estar disponible la ubicación GPS."
            return
        }
        let name=String((customName ?? "").trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        let text=name.isEmpty ?
            "Mi lugar · \(gps.latitude.formatted(.number.precision(.fractionLength(3)))), \(gps.longitude.formatted(.number.precision(.fractionLength(3))))" :
            name
        // Duplicate coordinates represent the same place, never a new phantom row.
        if let existing=savedPlaces.first(where:{
            abs($0.latitude-gps.latitude)<0.0015 &&
            abs($0.longitude-gps.longitude)<0.0015
        }) {
            if !name.isEmpty {renamePlace(existing.id,to:text)}
            return
        }
        addPlace(name:text,latitude:gps.latitude,longitude:gps.longitude,select:false)
    }

    func renamePlace(_ id: String, to newName: String) {
        let clean = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !clean.isEmpty, let index = savedPlaces.firstIndex(where: { $0.id == id }) else { return }
        savedPlaces[index].name = clean
        if selectedPlaceID == id {
            name = clean
            Task {
                if snapshot != nil { await updateLiveActivity() }
                else { await updateLivePlaceWhileLoading() }
            }
        }
        persistPlaces()
    }

    func deletePlace(_ id: String) {
        savedPlaces.removeAll { $0.id == id }
        quickSummaries.removeValue(forKey: id)
        quickFailures.remove(id)
        if selectedPlaceID == id { selectPlace("gps") }
        persistPlaces()
    }

    func refreshSummaries(force: Bool = false) async {
        if summariesLoading { return }
        if !force && Date().timeIntervalSince(summariesCheckedAt) < 4*60 { return }
        let locations = allPlaceRows.compactMap { item -> (String, CLLocationCoordinate2D)? in
            guard let point = item.coordinate else { return nil }
            return (item.id, point)
        }
        guard !locations.isEmpty else { return }
        summariesLoading = true
        defer { summariesLoading = false }
        // Work in batches to avoid swamping free weather endpoints.
        for start in stride(from: 0, to: locations.count, by: 4) {
            let slice = Array(locations[start..<min(start+4, locations.count)])
            await withTaskGroup(of: (String, QuickRainSummary?).self) { group in
                for (key, location) in slice {
                    group.addTask {
                        let report = try? await RainPlacesAPI.quick(latitude: location.latitude,
                                                                     longitude: location.longitude)
                        return (key, report)
                    }
                }
                for await (key, report) in group {
                    if let report {
                        quickSummaries[key] = report
                        quickFailures.remove(key)
                    } else {
                        quickFailures.insert(key)
                    }
                }
            }
        }
        summariesCheckedAt = Date()
    }
}
