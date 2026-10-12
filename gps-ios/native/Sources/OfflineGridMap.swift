import SwiftUI
import MapKit
import Network
import CoreLocation

@MainActor final class MapConnectivity: ObservableObject {
    @Published private(set) var connected = true
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.connected = (path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "gps.map.network"))
    }
    deinit { monitor.cancel() }
}

/// Renderiza sin teselas ni servidor: los puntos visitados y una malla métrica
/// aproximada sobre fondo neutro. Zoom y desplazamiento son locales.
struct OfflineGridMap: View {
    @ObservedObject var model: TimeModel
    @Binding var region: MKCoordinateRegion
    var onNavigate:(MKCoordinateRegion)->Void
    var onSelect:((Cell)->Void)? = nil
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
                    if let cell=activeCell {
                        let polygon=Grid.polygon(cell)
                        let p0=screen(polygon[3],size:size)
                        let p1=screen(polygon[1],size:size)
                        let square=CGRect(x:min(p0.x,p1.x),y:min(p0.y,p1.y),
                                        width:abs(p1.x-p0.x),height:abs(p1.y-p0.y))
                        if square.intersects(CGRect(origin:.zero,size:size)) {
                            context.stroke(Path(square),with:.color(.orange),lineWidth:4)
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
                            context.stroke(path,with:.color(.teal),lineWidth:3)
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
                    .onChanged { dragOffset=$0.translation }
                    .onEnded { translation in
                        let lat = region.center.latitude +
                            Double(translation.translation.height / max(1,geo.size.height)) * region.span.latitudeDelta
                        let lon = region.center.longitude -
                            Double(translation.translation.width / max(1,geo.size.width)) * region.span.longitudeDelta
                        region.center = CLLocationCoordinate2D(latitude:min(85,max(-85,lat)),
                                                                 longitude:min(179.9,max(-179.9,lon)))
                        onNavigate(region)
                        dragOffset = .zero
                    })
                VStack(alignment:.leading,spacing:9) {
                    Label("Mapa de cuadrículas · sin cartografía",systemImage:"wifi.slash")
                        .font(.caption.weight(.semibold))
                    HStack(spacing:9) {
                        Button { zoom(0.5) } label: { Image(systemName:"plus.magnifyingglass") }
                        Button { zoom(2) } label: { Image(systemName:"minus.magnifyingglass") }
                    }.buttonStyle(.bordered)
                }
                .padding(10)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:11))
                .padding(12)
            }
        }
    }
    private func zoom(_ factor: Double) {
        region.span = MKCoordinateSpan(
            latitudeDelta:min(120,max(0.0004,region.span.latitudeDelta*factor)),
            longitudeDelta:min(120,max(0.0004,region.span.longitudeDelta*factor))
        )
        onNavigate(region)
    }
}
