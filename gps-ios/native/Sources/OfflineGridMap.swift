import SwiftUI
import MapKit
import Network
import CoreLocation

/// A momentary connectivity blip must not destroy and rebuild the MapKit view.
/// Network status is a hint for selecting our offline canvas, not tile availability.
@MainActor final class MapConnectivity: ObservableObject {
    @Published private(set) var connected = true
    private let monitor = NWPathMonitor()
    private var pendingChange: Task<Void, Never>?
    private var latestAvailable = true
    private let outageDelay: UInt64
    private let restoreDelay: UInt64

    init(startMonitoring: Bool = true,
         outageDelay: UInt64 = 12_000_000_000,
         restoreDelay: UInt64 = 8_000_000_000) {
        self.outageDelay = outageDelay
        self.restoreDelay = restoreDelay
        if startMonitoring {
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(available) }
            }
            monitor.start(queue: DispatchQueue(label: "gps.map.network"))
        }
    }

    // Internal for deterministic regression tests without actual network switching.
    func networkChanged(_ available: Bool) {
        latestAvailable = available
        pendingChange?.cancel()
        pendingChange = nil
        guard available != connected else { return }
        // Wait for a sustained outage before falling back; wait for a sustained
        // restoration before rebuilding visible map tiles.
        let wait = available ? restoreDelay : outageDelay
        pendingChange = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: wait) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.latestAvailable == available else { return }
            self.connected = available
        }
    }

    deinit {
        pendingChange?.cancel()
        monitor.cancel()
    }
}

/// Renderiza sin teselas ni servidor: los puntos visitados y una malla métrica
/// aproximada sobre fondo neutro. Zoom y desplazamiento son locales.
struct OfflineGridMap: View {
    @ObservedObject var model: TimeModel
    @Binding var region: MKCoordinateRegion
    var onNavigate:(MKCoordinateRegion)->Void
    var onSelect:((Cell)->Void)? = nil
    var onInteractionStart:(()->Void)? = nil
    var onInteractionEnd:(()->Void)? = nil
    @State private var dragOffset: CGSize = .zero

    private func screen(_ coordinate: CLLocationCoordinate2D, size: CGSize) -> CGPoint {
        let latitudeDelta = max(0.0001, region.span.latitudeDelta)
        let longitudeDelta = max(0.0001, region.span.longitudeDelta)
        return CGPoint(
            x: size.width * (0.5 + (coordinate.longitude - region.center.longitude) / longitudeDelta),
            y: size.height * (0.5 - (coordinate.latitude - region.center.latitude) / latitudeDelta)
        )
    }
    private func colour(_ seconds: TimeInterval) -> Color {
        if model.explore { return .cyan }
        if seconds >= 31_536_000 { return .purple }
        if seconds >= 2_592_000 { return .red }
        if seconds >= 604_800 { return .orange }
        if seconds >= 86_400 { return .yellow }
        if seconds >= 21_600 { return .green }
        if seconds >= 3_600 { return .teal }
        return .cyan.opacity(0.8)
    }
    var body: some View {
        let cachedTotals=model.periodTotals()
        let activeCell=model.activeCell
        let activeExtra=activeCell.map {
            model.provisionalSeconds(for:[$0.id])
        } ?? 0
        let overlays=model.zoneOverlays
        let focusedCell=model.selected ?? model.activeCell
        let focusedZoneID=focusedCell.flatMap { model.primaryZone(for:$0) }?.id
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin:.zero,size:size)),
                                 with:.color(Color(red:0.92,green:0.95,blue:0.95)))
                    // Cuadrícula de referencia: aprox. 100 m por casilla.
                    let midCell = Grid.cell(latitude:region.center.latitude,
                                            longitude:region.center.longitude)
                    if region.span.latitudeDelta < 0.035 {
                        for row in (midCell.row-80)...(midCell.row+80) {
                            for col in (midCell.column-8)...(midCell.column+8) {
                                let c=Cell(row:row,column:col)
                                let poly=Grid.polygon(c)
                                let topLeft=screen(poly[3],size:size)
                                let bottomRight=screen(poly[1],size:size)
                                let rect=CGRect(x:topLeft.x,y:topLeft.y,
                                                width:bottomRight.x-topLeft.x,
                                                height:bottomRight.y-topLeft.y)
                                if rect.intersects(CGRect(origin:.zero,size:size)) {
                                    context.stroke(Path(rect),with:.color(.gray.opacity(0.15)),lineWidth:0.5)
                                }
                            }
                        }
                    }
                    for c in model.allCells.prefix(12_000) {
                        let secs=(cachedTotals[c.id] ?? 0)+(c==activeCell ? activeExtra : 0)
                        guard secs>0 else { continue }
                        let poly=Grid.polygon(c)
                        let p0=screen(poly[3],size:size),p1=screen(poly[1],size:size)
                        let rect=CGRect(x:p0.x,y:p0.y,width:p1.x-p0.x,height:p1.y-p0.y)
                        guard rect.intersects(CGRect(origin:.zero,size:size)), rect.width>0 else { continue }
                        context.fill(Path(rect),with:.color(colour(secs).opacity(model.cellFillOpacity)))
                        if rect.width >= 38 && rect.height >= 30 {
                            context.draw(Text(DurationFormat.small(secs))
                                .font(.system(size:10,weight:.bold))
                                .foregroundColor(.black),at:CGPoint(x:rect.midX,y:rect.midY))
                        }
                    }
                    // Misma delimitación visible sin Internet ni mapas descargados.
                    // El perímetro de una zona es más grueso que la rejilla normal.
                    for overlay in overlays {
                        for line in overlay.contours {
                            let points=line.coordinates.map { screen($0,size:size) }
                            guard points.count>1 else { continue }
                            var path=Path()
                            path.addLines(points)
                            context.stroke(path,with:.color(.teal.opacity(
                                overlay.zone.id == focusedZoneID ? 1 : 0.65)),
                                lineWidth:overlay.zone.id == focusedZoneID ? 5 : 2.5)
                        }
                        if let middle=overlay.center {
                            let center=screen(middle,size:size)
                            if center.x>=0 && center.x<size.width &&
                               center.y>=0 && center.y<size.height &&
                               region.span.latitudeDelta<0.07 {
                                context.draw(Text("\(overlay.zone.name) · \(overlay.zone.cellIDs.count)")
                                    .font(.system(size:11,weight:.bold))
                                    .foregroundColor(.teal),
                                    at:center)
                            }
                        }
                    }
                    if let cell=focusedCell {
                        let polygon=Grid.polygon(cell)
                        let p0=screen(polygon[3],size:size)
                        let p1=screen(polygon[1],size:size)
                        let square=CGRect(x:min(p0.x,p1.x),y:min(p0.y,p1.y),
                                        width:abs(p1.x-p0.x),height:abs(p1.y-p0.y))
                        if square.intersects(CGRect(origin:.zero,size:size)) {
                            context.stroke(Path(square),
                                with:.color(cell == activeCell ? .orange : .indigo),
                                lineWidth:4)
                        }
                    }
                    if let current=model.current {
                        let p=screen(current.coordinate,size:size)
                        context.fill(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),
                                     with:.color(.blue))
                        context.stroke(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),
                                       with:.color(.white),lineWidth:2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    let longitude=region.center.longitude +
                        (Double(point.x / max(1,geo.size.width))-0.5)*region.span.longitudeDelta
                    let latitude=region.center.latitude -
                        (Double(point.y / max(1,geo.size.height))-0.5)*region.span.latitudeDelta
                    onSelect?(Grid.cell(latitude:latitude,longitude:longitude))
                }
                .gesture(DragGesture(minimumDistance:5)
                    .onChanged {
                        onInteractionStart?()
                        dragOffset=$0.translation
                    }
                    .onEnded { translation in
                        let lat = region.center.latitude +
                            Double(translation.translation.height / max(1,geo.size.height)) * region.span.latitudeDelta
                        let lon = region.center.longitude -
                            Double(translation.translation.width / max(1,geo.size.width)) * region.span.longitudeDelta
                        region.center = CLLocationCoordinate2D(latitude:min(85,max(-85,lat)),
                                                                 longitude:min(179.9,max(-179.9,lon)))
                        onNavigate(region)
                        dragOffset = .zero
                        onInteractionEnd?()
                    })
            }
        }
    }
}
