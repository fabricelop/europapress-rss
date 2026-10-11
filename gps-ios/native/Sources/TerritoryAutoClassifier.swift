import Foundation
import CoreLocation

/// Sólo clasifica cuadrículas NUEVAS al recibir GPS fiable. No bloquea la
/// grabación, no requiere mapas descargados y respeta los límites de Apple.
/// iOS puede suspender una tarea en segundo plano: pendiente != pérdida de GPS.
@MainActor final class TerritoryAutoClassifier {
    private let geocoder=CLGeocoder()
    private var waiting:[Cell]=[]
    private var scheduled:Set<String>=[]
    private var worker:Task<Void,Never>?
    private var retryAfter=Date.distantPast

    func enqueue(_ cell:Cell,model:TimeModel) {
        guard model.data.territoryCache[cell.id] == nil,
              !scheduled.contains(cell.id),
              waiting.count < 96 else { return }
        waiting.append(cell)
        scheduled.insert(cell.id)
        guard worker == nil,Date()>=retryAfter else { return }
        worker=Task { await process(model:model) }
    }

    private func process(model:TimeModel) async {
        defer { worker=nil }
        while !waiting.isEmpty && !Task.isCancelled {
            guard Date()>=retryAfter else { return }
            let cell=waiting.removeFirst()
            scheduled.remove(cell.id)
            guard model.data.territoryCache[cell.id] == nil else { continue }
            let center=Grid.center(cell)
            do {
                let result=try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude:center.latitude,longitude:center.longitude),
                    preferredLocale:Locale(identifier:"es_ES"))
                guard let place=result.first else { continue }
                let territory=TerritoryRecord(
                    country:place.country,community:place.administrativeArea,
                    province:place.subAdministrativeArea,city:place.locality,
                    district:place.subLocality,neighborhood:nil,
                    timeZoneIdentifier:place.timeZone?.identifier)
                if !territory.hierarchy.isEmpty {
                    model.saveTerritory(territory,cellIDs:[cell.id])
                }
            } catch {
                // No insistir si el servicio limita las consultas o falla la red.
                // Se retomará con nuevas posiciones después del enfriamiento.
                retryAfter=Date().addingTimeInterval(5*60)
                if waiting.count<96 {
                    waiting.insert(cell,at:0)
                    scheduled.insert(cell.id)
                }
                return
            }
            try? await Task.sleep(for:.seconds(1.5))
        }
    }
}
