import SwiftUI
import MapKit
import Combine

/// An unobtrusive row on the existing map card. Never shows a spontaneous
/// modal or generates a notification. The first site must be user-confirmed.
struct TimeSiteInlineView: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @State private var showingChoices = false
    @State private var now = Date()

    var body: some View {
        Group {
            if model.activeCell == cell {
                switch model.siteDecision(for:cell,now:now) {
                case .tooEarly, .skipped:
                    EmptyView()
                case .needsConfirmation:
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle").foregroundStyle(.indigo)
                        Text("¿Dónde estás?")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        Button("Elegir") { showingChoices = true }
                        Button("Ahora no") { model.dismissSitePrompt(in:cell) }
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                case .identified(let siteID, let confirmed):
                    if let site = model.siteNamed(siteID) {
                        HStack(spacing: 7) {
                            Image(systemName:"mappin.circle.fill")
                                .foregroundStyle(.indigo)
                            VStack(alignment:.leading,spacing:2) {
                                Text(site.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(confirmed ? "Sitio confirmado" : "Asignado automáticamente")
                                    .font(.system(size:10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength:4)
                            Button("Corregir") { showingChoices = true }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            now = .now
            model.evaluateCurrentSite()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
            model.evaluateCurrentSite(now:date)
        }
        .sheet(isPresented:$showingChoices) {
            NavigationStack {
                TimeSitePickerView(model:model,cell:cell)
            }
        }
    }
}

private struct ApplePOICandidate: Identifiable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var distance: Double
    var inside: Bool
}

struct TimeSitePickerView: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @Environment(\.dismiss) private var dismiss
    var onPicked: ((IdentifiedSite) -> Void)? = nil
    @State private var searchText = ""
    @State private var appleResults: [ApplePOICandidate] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var privateName = ""

    var body: some View {
        List {
            Section {
                Text("Elige el lugar real de esta estancia. Las próximas visitas a la misma cuadrícula se asignarán al sitio que hayas confirmado más veces.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let known = model.siteOptions(for:cell)
            if !known.isEmpty {
                Section("Tus sitios · más confirmados primero") {
                    ForEach(known.indices, id: \.self) { index in
                        let row = known[index]
                        Button {
                            if let onPicked { onPicked(row.site) }
                            else { model.confirmSite(row.site, cell:cell) }
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName:row.site.origin == "private" ? "house.fill" : "mappin")
                                    .foregroundStyle(.indigo)
                                Text(row.site.name).foregroundStyle(.primary)
                                Spacer()
                                if row.confirmations > 0 {
                                    Text("\(row.confirmations) confirmaciones")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName:"checkmark.circle")
                                    .foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }
            Section("Buscar cualquier sitio en Apple Maps") {
                HStack {
                    TextField("Nombre, calle, localidad…",text:$searchText)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit { Task { await searchAnywhere() } }
                    Button("Buscar") { Task { await searchAnywhere() } }
                        .disabled(searchText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Text("No se limita a sitios dentro de la cuadrícula. Al confirmar un resultado, quedará asociado a esta cuadrícula para próximas visitas.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Lugares en Apple Maps") {
                if loading {
                    ProgressView("Buscando lugares al abrir esta pantalla…")
                } else if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.secondary)
                } else if appleResults.isEmpty {
                    Text("No se encontraron establecimientos próximos. Puedes añadir un lugar privado.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(appleResults) { item in
                        Button {
                            if let site = model.createOrReuseSite(name:item.name,
                               latitude:item.latitude,longitude:item.longitude,origin:"apple") {
                                if let onPicked { onPicked(site) }
                                else { model.confirmSite(site,cell:cell) }
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName:"mappin").foregroundStyle(.indigo)
                                VStack(alignment:.leading,spacing:2) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.inside ? "Dentro de la cuadrícula" :
                                         "Cerca · aprox. \(Int(item.distance)) m")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName:"plus.circle")
                                    .foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }
            Section("Lugar privado o no encontrado") {
                TextField("Nombre, por ejemplo: Casa de Ana",text:$privateName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button {
                    if let site = model.createPrivateSite(name:privateName,cell:cell) {
                        if let onPicked { onPicked(site) }
                        else { model.confirmSite(site,cell:cell) }
                    }
                    dismiss()
                } label: {
                    Label("Guardar y confirmar lugar privado",systemImage:"house")
                }
                .disabled(privateName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Text("Los lugares privados permanecen dentro de los datos locales de la aplicación. No se publican en Apple Maps.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("¿Dónde estás?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.cancellationAction) {
                Button("Cerrar") { dismiss() }
            }
        }
        .task(id:cell.id) { await searchNearby() }
    }

    private func searchAnywhere() async {
        let query = searchText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        let center = Grid.center(cell)
        let origin = CLLocation(latitude:center.latitude,longitude:center.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // This is a ranking hint, not a restriction to the 100m grid.
        request.region = MKCoordinateRegion(center:center,
                        span:MKCoordinateSpan(latitudeDelta:3,longitudeDelta:3))
        do {
            let result = try await MKLocalSearch(request:request).start()
            appleResults = Array(result.mapItems.prefix(40)).compactMap { item in
                guard let name=item.name,!name.isEmpty else { return nil }
                let coordinate=item.placemark.coordinate
                let distance=origin.distance(from:CLLocation(
                    latitude:coordinate.latitude,longitude:coordinate.longitude))
                return ApplePOICandidate(id:"\(name)|\(coordinate.latitude)|\(coordinate.longitude)",
                      name:name,latitude:coordinate.latitude,longitude:coordinate.longitude,
                      distance:distance,inside:Grid.cell(latitude:coordinate.latitude,
                      longitude:coordinate.longitude)==cell)
            }
            if appleResults.isEmpty { errorText = "Sin resultados: prueba otra búsqueda o introduce un sitio privado." }
        } catch {
            errorText = "No se pudo buscar en Apple Maps. Prueba con otra consulta o crea un sitio privado."
        }
    }

    private func searchNearby() async {
        // Never make POI network requests in the background or on GPS changes.
        // Apple Maps is consulted only after the user opens this chooser.
        loading = true
        errorText = nil
        defer { loading = false }
        let center = Grid.center(cell)
        let origin = CLLocation(latitude:center.latitude,longitude:center.longitude)
        let request = MKLocalPointsOfInterestRequest(center:center,radius:130)
        do {
            let results = try await MKLocalSearch(request:request).start()
            let known = model.siteOptions(for:cell).map(\.site)
            var found: [ApplePOICandidate] = []
            for item in results.mapItems {
                guard let name = item.name?.trimmingCharacters(in:.whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                let coordinate = item.placemark.coordinate
                let dist = origin.distance(from:CLLocation(latitude:coordinate.latitude,
                                                           longitude:coordinate.longitude))
                guard dist <= 130 else { continue }
                let inside = Grid.cell(latitude:coordinate.latitude,
                                       longitude:coordinate.longitude) == cell
                let duplicate = known.contains { saved in
                    saved.name.compare(name,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame &&
                    CLLocation(latitude:saved.latitude,longitude:saved.longitude)
                        .distance(from:CLLocation(latitude:coordinate.latitude,
                                                   longitude:coordinate.longitude)) < 60
                }
                if duplicate { continue }
                let key = "\(name.lowercased())|\(Int(coordinate.latitude * 100_000))|\(Int(coordinate.longitude * 100_000))"
                if found.contains(where: { $0.id == key }) { continue }
                found.append(ApplePOICandidate(id:key,name:name,latitude:coordinate.latitude,
                                longitude:coordinate.longitude,distance:dist,inside:inside))
            }
            appleResults = found.sorted {
                if $0.inside != $1.inside { return $0.inside }
                return $0.distance < $1.distance
            }
        } catch {
            errorText = "Apple Maps no está disponible ahora. Puedes usar un sitio guardado o uno privado."
        }
    }
}

struct TimeMySitesView: View {
    @ObservedObject var model: TimeModel
    var body: some View {
        List {
            Section {
                Text("Sitios identificados a partir de estancias en las cuadrículas. Los confirmados cuentan para las próximas asignaciones automáticas; las suposiciones automáticas no votan.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Sitios identificados",value:"\(model.data.identifiedSites.count)")
                LabeledContent("Estancias asignadas",value:"\(model.data.siteStayAssignments.count)")
            }
            Section("Mis sitios") {
                ForEach(model.data.identifiedSites) { site in
                    let stays = model.data.siteStayAssignments.filter { $0.siteID == site.id }
                    VStack(alignment:.leading,spacing:5) {
                        Label(site.name,systemImage:site.origin == "private" ? "house" : "mappin")
                            .font(.headline)
                        HStack {
                            Text("\(stays.count) estancias asignadas")
                            Spacer()
                            Text("\(stays.filter { $0.confirmed }.count) confirmadas")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,3)
                }
            }
        }
        .navigationTitle("Mis Sitios")
        .navigationBarTitleDisplayMode(.inline)
    }
}
