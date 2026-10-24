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

struct TimeSitePickerView: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @Environment(\.dismiss) private var dismiss
    var onPicked: ((IdentifiedSite) -> Void)? = nil
    @State private var searchText = ""
    @State private var externalResults: [SitePlaceResult] = []
    @State private var showDistantResults = false
    private var nearbyResults: [SitePlaceResult] { externalResults.filter { $0.distance <= 3500 } }
    private var distantResults: [SitePlaceResult] { externalResults.filter { $0.distance > 3500 } }
    @State private var loading = false
    @State private var pendingProviders = 0
    @State private var requestID = UUID()
    @State private var searchWasLimited = false
    @State private var errorText: String?
    @State private var searchedText = ""
    @State private var privateName = ""

    var body: some View {
        List {
            let known = model.siteOptions(for:cell)
            if !known.isEmpty {
                Section("Sitios conocidos · ordenados por probabilidad") {
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
                                    Text("\(row.confirmations) aquí")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if row.fromOtherSquares > 0 {
                                    Text("Ya confirmado cerca")
                                        .font(.caption2).foregroundStyle(.teal)
                                }
                                Image(systemName:"checkmark.circle")
                                    .foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }
            Section("Buscar un lugar por su nombre") {
                HStack {
                    TextField("Nombre, calle, localidad…",text:$searchText)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit { searchAnywhere() }
                    Button("Buscar") { searchAnywhere() }
                        .disabled(searchText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Text("La búsqueda consulta las fuentes por separado y enseña los resultados en cuanto aparecen.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Establecimientos próximos a la cuadrícula") {
                if loading && nearbyResults.isEmpty {
                    ProgressView("Consultando establecimientos de la zona…")
                }
                if !nearbyResults.isEmpty {
                    ForEach(nearbyResults.prefix(35)) { item in
                        providerRow(item)
                    }
                }
                if nearbyResults.isEmpty && !loading {
                    Text("No se han encontrado establecimientos próximos con este nombre. Puedes probar otra búsqueda o consultar resultados más alejados.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if pendingProviders > 0 && !searchWasLimited {
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small)
                        Text("Comprobando otras fuentes…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Se priorizan los locales de la zona; una localidad con el mismo nombre pero distante no sustituirá a un establecimiento próximo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !distantResults.isEmpty {
                Section("Resultados alejados") {
                    Button(showDistantResults ? "Ocultar resultados alejados" :
                           "Mostrar \(distantResults.count) resultados a más de 3,5 km") {
                        showDistantResults.toggle()
                    }
                    .buttonStyle(.borderless)
                    if showDistantResults {
                        ForEach(distantResults.prefix(20)) { item in
                            providerRow(item)
                        }
                    }
                }
            }
            if externalResults.contains(where:{$0.source == .openStreetMap}) {
                Section {
                    Link("Datos © OpenStreetMap colaboradores",
                         destination:URL(string:"https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
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
        .task(id:cell.id) { searchPlaces(query:nil) }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func providerRow(_ item:SitePlaceResult) -> some View {
        Button {
            guard let site=model.createOrReuseSite(
                name:item.name, latitude:item.latitude,
                longitude:item.longitude,
                origin:item.source == .foursquare ? "foursquare" :
                       item.source == .openStreetMap ? "openstreetmap" : "apple"
            ) else { return }
            if let onPicked { onPicked(site) }
            else { model.confirmSite(site,cell:cell) }
            dismiss()
        } label: {
            HStack(spacing:9) {
                Image(systemName:"mappin.circle").foregroundStyle(.indigo)
                VStack(alignment:.leading,spacing:3) {
                    Text(item.name).foregroundStyle(.primary)
                        .fontWeight(item.inGrid ? .semibold : .regular)
                    HStack(spacing:6) {
                        Text(item.source.rawValue)
                        Text("·")
                        Text(item.inGrid ? "Dentro de la cuadrícula" :
                             "Aprox. \(Int(item.distance.rounded())) m")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName:"plus.circle").foregroundStyle(.indigo)
            }
        }
    }

    private func searchAnywhere() {
        let query=searchText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchPlaces(query:query)
    }

    /// These three provider calls are independent. A slow Overpass request
    /// must never prevent Apple or Foursquare results from being displayed.
    /// Waiting indicators stop after eight seconds, even if a public service
    /// is throttled or unavailable. Known local places remain actionable.
    private func searchPlaces(query:String?) {
        let center=Grid.center(cell)
        let id=UUID()
        requestID=id
        let text=query?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        searchedText=text
        externalResults=[]
        showDistantResults=false
        errorText=nil
        loading=true
        searchWasLimited=false
        let effectiveQuery:String?=text.isEmpty ? nil : text
        let foursquareKey=SiteFoursquareCredentials.load()
        pendingProviders=foursquareKey == nil ? 2 : 3

        Task {
            let response=(try? await SitePOISearch.apple(center:center,cell:cell,
                                                         query:effectiveQuery)) ?? []
            await receive(response,for:id)
        }
        Task {
            let response=(try? await SitePOISearch.openStreetMap(center:center,
                                     cell:cell,query:effectiveQuery)) ?? []
            await receive(response,for:id)
        }
        if let foursquareKey,!foursquareKey.isEmpty {
            Task {
                let response=(try? await SitePOISearch.foursquare(center:center,
                             cell:cell,query:effectiveQuery,
                             serviceKey:foursquareKey)) ?? []
                await receive(response,for:id)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds:8_000_000_000)
            await MainActor.run {
                guard requestID == id else { return }
                loading=false
                searchWasLimited=true
                if externalResults.isEmpty {
                    errorText="La consulta está tardando. Puedes elegir ya un sitio guardado, buscar otro nombre o crear uno privado."
                }
            }
        }
    }

    @MainActor private func receive(_ results:[SitePlaceResult],for id:UUID) {
        guard requestID == id else { return }
        pendingProviders=max(0,pendingProviders-1)
        if !results.isEmpty {
            externalResults=SitePOISearch.ranked(externalResults + results,
                                               query:searchedText.isEmpty ? nil : searchedText)
            errorText=nil
            loading=false
        }
        if pendingProviders == 0 {
            loading=false
            searchWasLimited=false
            if externalResults.isEmpty {
                errorText="Los servicios de mapas no han devuelto resultados. Prueba por nombre o usa un sitio guardado."
            }
        }
    }

}

struct TimeMySitesView: View {
    @ObservedObject var model: TimeModel
    @State private var totalsBySite:[UUID:SiteTimeTotal] = [:]
    @State private var computing = false
    @State private var generation = UUID()
    @State private var editingSite: IdentifiedSite?
    @State private var deletingSite: IdentifiedSite?
    @State private var warningText: String?

    private var privateSites:[IdentifiedSite] {
        model.data.identifiedSites.filter { $0.origin == "private" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var mapSites:[IdentifiedSite] {
        model.data.identifiedSites.filter { $0.origin != "private" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TimeSiteCalendarView(model:model)
                } label: {
                    Label("Ver todo el histórico en calendario",
                          systemImage:"calendar.badge.clock")
                }
            }
            Section {
                Text("Puedes cambiar el nombre y la ubicación de tus sitios privados o eliminarlos. Las modificaciones se reflejan en todas las estancias que tengan asociado ese sitio.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Sitios creados por mí",value:"\(privateSites.count)")
                LabeledContent("Sitios de mapas",value:"\(mapSites.count)")
                if computing { ProgressView("Calculando tiempos históricos…") }
            }
            Section {
                if privateSites.isEmpty {
                    Text("Los lugares que crees manualmente aparecerán aquí con opciones para editarlos o eliminarlos.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(privateSites) { site in
                    HStack(alignment:.center,spacing:10) {
                        siteSummary(site)
                        Spacer(minLength:4)
                        Menu {
                            Button {
                                editingSite = site
                            } label: {
                                Label("Editar nombre y ubicación",systemImage:"pencil")
                            }
                            Button(role:.destructive) {
                                deletingSite = site
                            } label: {
                                Label("Eliminar sitio",systemImage:"trash")
                            }
                        } label: {
                            Image(systemName:"ellipsis.circle")
                                .font(.title3)
                                .frame(minWidth:42,minHeight:44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Opciones de \(site.name)")
                    }
                    .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                        Button("Editar") { editingSite=site }.tint(.blue)
                        Button("Eliminar",role:.destructive) { deletingSite=site }
                    }
                }
            } header: {
                Text("Sitios creados por mí")
            } footer: {
                Text("Eliminar un sitio no elimina las estancias ni sus minutos GPS: solo borra su identificación y deja esos tramos como «Sin identificar».")
            }
            if !mapSites.isEmpty {
                Section("Sitios guardados desde mapas") {
                    ForEach(mapSites) { site in
                        siteSummary(site)
                    }
                }
            }
        }
        .navigationTitle("Mis Sitios")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item:$editingSite) { site in
            NavigationStack {
                TimePrivateSiteEditView(model:model,site:site)
            }
        }
        .confirmationDialog(
            deletingSite.map { "¿Eliminar «\($0.name)»?" } ?? "Eliminar sitio privado",
            isPresented:Binding(
                get: { deletingSite != nil },
                set: { if !$0 { deletingSite=nil } }
            ),
            titleVisibility:.visible
        ) {
            Button("Eliminar sitio",role:.destructive) {
                if let site=deletingSite {
                    if !model.deletePrivateSite(site.id) {
                        warningText="No se pudo eliminar el sitio. Los datos permanecen intactos."
                    }
                }
                deletingSite=nil
                rebuild()
            }
            Button("Cancelar",role:.cancel) { deletingSite=nil }
        } message: {
            if let site=deletingSite {
                Text("Hay \(model.privateSiteLinkedStayCount(site.id)) estancias asociadas. Sus tramos quedarán sin identificar; las fechas, las cuadrículas y el tiempo seguirán guardados.")
            }
        }
        .alert("No se pudo completar",isPresented:Binding(
            get:{ warningText != nil },set:{ if !$0 { warningText=nil } }
        )) {
            Button("Aceptar",role:.cancel) { warningText=nil }
        } message: {
            Text(warningText ?? "")
        }
        .onAppear { rebuild() }
        .onChange(of:model.data.siteStayParts.count) { _,_ in rebuild() }
        .onChange(of:model.data.siteStayAssignments.count) { _,_ in rebuild() }
        .onChange(of:model.data.identifiedSites.count) { _,_ in rebuild() }
    }

    @ViewBuilder private func siteSummary(_ site:IdentifiedSite) -> some View {
        let total = totalsBySite[site.id] ?? SiteTimeTotal()
        VStack(alignment:.leading,spacing:5) {
            Label(site.name,systemImage:site.origin == "private" ? "house.fill" : "mappin")
                .font(.subheadline.weight(.semibold))
            Text("\(total.verifiedVisits) estancias confirmadas · \(DurationFormat.full(total.verifiedSeconds))")
                .font(.caption).foregroundStyle(.teal)
            if total.suggestedVisits > 0 {
                Text("\(total.suggestedVisits) propuestas · \(DurationFormat.full(total.suggestedSeconds))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical,5)
    }

    private func rebuild() {
        let id=UUID()
        generation=id
        computing=true
        let raw=model.data.intervals
        let parts=model.data.siteStayParts
        let legacy=model.data.siteStayAssignments
        DispatchQueue.global(qos:.userInitiated).async {
            let statistics=SiteStayTotals.calculate(intervals:raw,parts:parts,
                                                   assignments:legacy)
            DispatchQueue.main.async {
                guard generation==id else { return }
                totalsBySite=statistics
                computing=false
            }
        }
    }
}

/// Editing a private site's name keeps its identity (UUID), so all linked
/// historic stays adopt it without writing to GPS or changing durations.
/// The map can be tapped to correct the site's saved pin.
private struct TimePrivateSiteEditView: View {
    @ObservedObject var model:TimeModel
    let site:IdentifiedSite
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var latitude:Double
    @State private var longitude:Double
    @State private var camera:MapCameraPosition
    @State private var errorMessage:String?

    init(model:TimeModel,site:IdentifiedSite) {
        self.model=model
        self.site=site
        _name=State(initialValue:site.name)
        _latitude=State(initialValue:site.latitude)
        _longitude=State(initialValue:site.longitude)
        _camera=State(initialValue:.region(MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:site.latitude,longitude:site.longitude),
            latitudinalMeters:800,longitudinalMeters:800)))
    }

    var body: some View {
        Form {
            Section("Nombre del sitio") {
                TextField("Nombre",text:$name)
                    .textInputAutocapitalization(.words)
                Text("El nombre corregido se mostrará en todas las estancias de este sitio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ubicación del sitio") {
                MapReader { proxy in
                    Map(position:$camera) {
                        Annotation("Ubicación guardada",coordinate:CLLocationCoordinate2D(
                            latitude:latitude,longitude:longitude)) {
                            Image(systemName:"mappin.circle.fill")
                                .font(.system(size:28))
                                .foregroundStyle(.teal)
                        }
                    }
                    .mapStyle(.standard(elevation:.flat))
                    .frame(height:220)
                    .clipShape(RoundedRectangle(cornerRadius:12))
                    .onTapGesture { point in
                        if let coordinate=proxy.convert(point,from:.local) {
                            latitude=coordinate.latitude
                            longitude=coordinate.longitude
                        }
                    }
                }
                Text("Toca el mapa para mover el marcador. Esto solo corrige la ficha del sitio; nunca mueve las posiciones GPS ya registradas.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restaurar posición original") {
                    latitude=site.latitude
                    longitude=site.longitude
                    camera = .region(MKCoordinateRegion(
                        center:CLLocationCoordinate2D(latitude:site.latitude,longitude:site.longitude),
                        latitudinalMeters:800,longitudinalMeters:800))
                }
                .font(.caption)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Editar sitio privado")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
            ToolbarItem(placement:.confirmationAction) {
                Button("Guardar") {
                    if model.updatePrivateSite(id:site.id,name:name,
                                               latitude:latitude,longitude:longitude) {
                        dismiss()
                    } else {
                        errorMessage="Comprueba el nombre y la ubicación. No se puede duplicar otro sitio del mismo nombre en esta zona."
                    }
                }
                .fontWeight(.semibold)
                .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
