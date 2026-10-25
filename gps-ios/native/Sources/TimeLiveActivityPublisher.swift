import Foundation
import ActivityKit

/// Solicita y restaura la Live Activity sin App Group ni permisos de servidor.
/// iOS puede terminarla por su límite de duración; solo se recupera al abrir la app
/// o cuando el sistema realmente entrega una posición GPS.
@MainActor final class TimeLiveActivityPublisher {
    private var lastUpdated:Date = .distantPast
    private var lastFingerprint:TimeActivityFingerprint?
    private var lastMoving:Bool?
    private var updateTask:Task<Void,Never>?
    private var previousZoneVisitSeconds:TimeInterval?
    private var previousZoneID:UUID?
    private var lastMilestone:String?
    private var milestoneUntil:Date = .distantPast

    // BIOGRID computation is cached and always runs off the main thread.
    // Rebuild at most once per ten minutes to protect background battery.
    private var bioPopulations:[String:[Int64]]?
    private var bioLastComputed:Date?
    private var bioLastAttempt:Date = .distantPast
    private var bioComputing=false
    private var bioLoadedCache=false

    private var bioCacheURL:URL {
        let base=FileManager.default.urls(for:.applicationSupportDirectory,
                                           in:.userDomainMask).first!
        return base.appendingPathComponent("biogrid-derived-v9.json")
    }

    private func ensureBioGrid(from model:TimeModel,now:Date) {
        if !bioLoadedCache {
            bioLoadedCache=true
            let path=bioCacheURL
            Task {
                // File I/O and potentially large JSON decode do NOT belong
                // on the main thread that handles GPS and SwiftUI.
                let cached=await Task.detached(priority:.utility) {
                    () -> (populations:[String:[Int64]],modified:Date?)? in
                    guard let data=try? Data(contentsOf:path),
                          let saved=try? JSONDecoder().decode(BioGridSnapshot.self,from:data),
                          let date=saved.latestProcessed else { return nil }
                    var local=Calendar(identifier:.gregorian)
                    local.timeZone=TimeZone(identifier:"Europe/Madrid")!
                    guard local.isDate(date,inSameDayAs:now) else { return nil }
                    let attributes=try? FileManager.default.attributesOfItem(
                        atPath:path.path)
                    return (saved.populations,attributes?[.modificationDate] as? Date)
                }.value
                // Do not overwrite a newer recomputation that finished first.
                if let cached,bioPopulations == nil {
                    bioPopulations=cached.populations
                    bioLastComputed=cached.modified
                    refresh(from:model,force:true,now:.now)
                }
            }
        }
        guard !bioComputing,now.timeIntervalSince(bioLastAttempt)>=600 else { return }
        bioLastAttempt=now
        bioComputing=true
        let intervals=model.data.intervals
        let timezone=TimeZone.current
        Task {
            let populations=await Task.detached(priority:.utility) { () -> [String:[Int64]] in
                // Do not compete with BIOGRID's own cache writer. Recompute
                // off the main thread, project only the current populations
                // and discard the rest of the heavy historical simulation.
                BioGridEngine.simulate(intervals,now:now,timezone:timezone).populations
            }.value
            bioPopulations=populations
            bioLastComputed=Date()
            bioComputing=false
            // Only an authorized live activity will be updated.
            guard !Task.isCancelled else { return }
            refresh(from:model,force:true,now:.now)
        }
    }

    private func liveSite(for cell:Cell,model:TimeModel,now:Date)
       -> (name:String,confirmed:Bool)? {
        let valid=Set(model.data.identifiedSites.map(\.id))
        if let start=model.currentVisitStart {
            let key=SiteStayPolicy.visitKey(cellID:cell.id,entered:start)
            let parts=model.data.siteStayParts.filter { $0.stayID == key }
            if !parts.isEmpty {
                // Explicit split / "De paso" / "Sin identificar" takes
                // precedence over ALL automatic and legacy assignments.
                guard let current=parts.first(where:{
                    $0.from <= now && now < $0.to
                }),current.kind == .place,
                    let id=current.siteID,valid.contains(id),
                    let label=model.siteNamed(id)?.name
                else { return nil }
                return (label,current.confirmed)
            }
            if let assignment=model.data.siteStayAssignments.first(where:{
                $0.id == key && valid.contains($0.siteID)
            }),let name=model.siteNamed(assignment.siteID)?.name {
                return (name,assignment.confirmed)
            }
            if model.data.dismissedSiteStayKeys.contains(key) {
                return nil
            }
        }
        // Display a suggestion only if its ranking comes from user-confirmed
        // visits to THIS exact square; never guess a neighboring POI.
        if let best=model.preferredSiteID(for:cell.id),
            let name=model.siteNamed(best)?.name {
            return (name,false)
        }
        return nil
    }

    private func ongoingActivities()->[Activity<TimeMapActivityAttributes>] {
        Activity<TimeMapActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    func check(from model:TimeModel) {
        let enabled=ActivityAuthorizationInfo().areActivitiesEnabled
        let items=Activity<TimeMapActivityAttributes>.activities
        let states=items.map { "\($0.id.prefix(8)): \($0.activityState)" }.joined(separator:", ")
        model.liveActivityDiagnostic = "ActivityKit: \(enabled ? "autorizado" : "no permitido") · \(items.count) actividad(es)" +
            (states.isEmpty ? "" : " · "+states)
        let embedded=Bundle.main.builtInPlugInsURL.map {
            FileManager.default.fileExists(atPath:
                $0.appendingPathComponent("MiMapaWidgets.appex").path)
        } ?? false
        model.liveActivityDiagnostic += embedded ?
            " · Extensión En vivo instalada" :
            " · FALTA extensión En vivo en IPA firmado"

    }

    func restoreIfNeeded(from model:TimeModel) {
        guard UserDefaults.standard.bool(forKey:"miMapaLiveActivity") else { return }
        // Bypass del limitador si iOS ha terminado una actividad de 8 horas.
        if ongoingActivities().isEmpty {
            lastUpdated = .distantPast
            lastFingerprint=nil
            lastMoving=nil
            refresh(from:model,force:true)
        } else {
            refresh(from:model)
        }
    }

    /// Botón explícito: sustituye la actividad anterior y muestra una nueva.
    /// Si aún no hay GPS reciente, queda solicitada la reactivación en Ajustes
    /// y la primera muestra válida iniciará la actividad automáticamente.
    func reactivate(from model:TimeModel) {
        UserDefaults.standard.set(true,forKey:"miMapaLiveActivity")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            model.liveActivityDiagnostic="Actividades en directo desactivadas en Ajustes de iOS."
            return
        }
        updateTask?.cancel()
        updateTask=Task {
            for existing in Activity<TimeMapActivityAttributes>.activities {
                await existing.end(nil,dismissalPolicy:.immediate)
            }
            guard !Task.isCancelled else { return }
            lastFingerprint=nil
            lastMoving=nil
            lastUpdated = .distantPast
            refresh(from:model,force:true)
        }
    }

    func refresh(from model:TimeModel,force:Bool=false,now:Date = .now) {
        let enabled=UserDefaults.standard.bool(forKey:"miMapaLiveActivity")
        let permitted=ActivityAuthorizationInfo().areActivitiesEnabled
        guard enabled,permitted else {
            lastFingerprint=nil
            lastMoving=nil
            lastUpdated = .distantPast
            updateTask?.cancel()
            updateTask=Task {
                for activity in Activity<TimeMapActivityAttributes>.activities {
                    await activity.end(nil,dismissalPolicy:.immediate)
                }
            }
            return
        }
        guard let cell=model.activeCell,
              let start=model.currentVisitStart ?? model.data.gpsRest?.startedAt,
              model.recording || model.isResting else {
            model.liveActivityDiagnostic="En vivo preparado · esperando primera posición GPS."
            return
        }
        let resting=model.isResting
        // Nunca hacemos pasar la última posición histórica por una posición viva.
        let fix=resting ? nil : model.current?.date
        guard resting || fix != nil else {
            model.liveActivityDiagnostic="En vivo activado · esperando nueva posición GPS."
            return
        }
        ensureBioGrid(from:model,now:now)
        let namedSite=liveSite(for:cell,model:model,now:now)
        let name=model.label(for:cell)
        let fingerprint=TimeActivityFingerprint(cellID:cell.id,
            visibleName:name,startedAt:start,resting:resting)
        let active=ongoingActivities()
        let changed=lastFingerprint != fingerprint
        // Evaluar movimiento ANTES del limitador: una transición de modo
        // necesita actualizar la pantalla aunque siga en la misma casilla.
        let motion=TimeLiveMotion.analyze(model.data.fixes,now:now,center:cell,
            latest:resting ? nil : model.current)
        let motionChanged=lastMoving != (motion.moving && !resting)
        guard force || changed || motionChanged || active.isEmpty ||
              now.timeIntervalSince(lastUpdated)>=45 else { return }

        let zone=model.primaryZone(for:cell)
        let confirmed=model.confirmedTotals(now:now)
        let zoneTotal:TimeInterval?=zone.map { zone in
            zone.cellIDs.reduce(0) { $0+(confirmed[$1] ?? 0) }
        }
        let end:Date
        if resting {
            // ActivityKit termina las actividades por duración. No se usa este
            // intervalo para asignar más tiempo al historial.
            end=max(start.addingTimeInterval(8*3600),now.addingTimeInterval(90))
        } else {
            end=max(start.addingTimeInterval(1),
                    (fix ?? now).addingTimeInterval(120))
        }
        // Graphs were removed from the Live Activity. Avoid spending CPU on
        // chart windows or neighborhood tiles that will never be displayed.
        let zoneStay=zone.map { model.zoneStaySeconds(for:$0,now:now) }
        // Anunciar un hito únicamente al cruzarlo durante esta sesión; no
        // repetir las horas acumuladas anteriores cuando se abre la app.
        if let zone,let seconds=zoneStay {
            if previousZoneID == zone.id,let previous=previousZoneVisitSeconds,
               Int(previous/3600) < Int(seconds/3600),seconds>=3600 {
                lastMilestone="\(Int(seconds/3600)) h en esta visita a \(zone.name)"
                milestoneUntil=now.addingTimeInterval(90)
            }
            previousZoneID=zone.id
            previousZoneVisitSeconds=seconds
        } else {
            previousZoneID=nil
            previousZoneVisitSeconds=nil
        }
        // La prioridad es el descubrimiento de zona, seguido de cuadrícula.
        // Sin historial previo confirmado nunca se atribuye "primera visita"
        // a una zona que ya tenga horas acumuladas.
        if changed,let zone,let total=zoneTotal,
           total<60,now.timeIntervalSince(start)<=100 {
            lastMilestone="Primera visita a \(zone.name)"
            milestoneUntil=now.addingTimeInterval(90)
        } else if changed,
                  (confirmed[cell.id] ?? 0)<60,
                  now.timeIntervalSince(start)<=100 {
            lastMilestone="Nueva cuadrícula descubierta"
            milestoneUntil=now.addingTimeInterval(90)
        }
        let state=TimeMapActivityAttributes.ContentState(
            cellName:name,
            cellNumber:model.data.shortIDs[cell.id].map { "Cuadrícula \($0)" } ?? "Cuadrícula actual",
            zoneName:zone?.name,
            confirmedCellSeconds:confirmed[cell.id] ?? 0,
            confirmedZoneSeconds:zoneTotal,
            stayStartedAt:start,
            timerValidUntil:end,
            lastGPSAt:fix,
            resting:resting,
            nearbyIntensity:[],
            lastSixHours:[],
            chartIsZone:zone != nil,
            moving:motion.moving && !resting,
            recentDistanceMeters:motion.recentDistanceMeters,
            crossedCells:motion.crossedCells,
            trailIndices:motion.trailIndices,
            headingDegrees:motion.headingDegrees,
            currentZoneStaySeconds:zoneStay,
            lastSixMinutes:[],
            milestone:now<=milestoneUntil ? lastMilestone : nil,
            siteName:namedSite?.name,
            siteConfirmed:namedSite?.confirmed,
            bioGridCounts:LiveBioGridPopulation.counts(cellID:cell.id,
                                                         populations:bioPopulations),
            bioGridUpdatedAt:bioLastComputed)
        let content=ActivityContent(
            state:state,
            staleDate:resting ? nil : fix?.addingTimeInterval(90),
            relevanceScore:60)
        lastUpdated=now
        lastFingerprint=fingerprint
        lastMoving=motion.moving && !resting
        updateTask?.cancel()
        updateTask=Task {
            if let item=ongoingActivities().first {
                await item.update(content)
                guard !Task.isCancelled else { return }
                model.liveActivityDiagnostic="En vivo actualizado · \(item.id.prefix(12)) · \(item.activityState)"
            } else {
                do {
                    let item=try Activity<TimeMapActivityAttributes>.request(
                        attributes:TimeMapActivityAttributes(),
                        content:content,pushType:nil)
                    guard !Task.isCancelled else { return }
                    model.liveActivityDiagnostic="En vivo iniciado · \(item.id.prefix(12)) · \(item.activityState)"
                } catch {
                    guard !Task.isCancelled else { return }
                    lastUpdated = .distantPast
                    lastFingerprint=nil
                    model.liveActivityDiagnostic="No se pudo crear En vivo: \(String(reflecting:error))"
                }
            }
        }
    }
}
