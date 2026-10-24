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
            Section("Sitios encontrados en mapas") {
                if loading && externalResults.isEmpty {
                    ProgressView("Consultando mapas…")
                }
                if !externalResults.isEmpty {
                    ForEach(externalResults.prefix(35)) { item in
                        Button {
                            guard let site=model.createOrReuseSite(
                                name:item.name,latitude:item.latitude,
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
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName:"plus.circle").foregroundStyle(.indigo)
                            }
                        }
                    }
                }
                if pendingProviders > 0 && !searchWasLimited {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Comprobando otras fuentes en segundo plano…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText).font(.caption2).foregroundStyle(.secondary)
                } else if externalResults.isEmpty && !loading {
                    Text("Sin resultados por ahora. Puedes buscar otro nombre o utilizar un sitio conocido o privado.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Las ubicaciones son puntos de referencia de sus respectivos mapas. Estar cerca no confirma que hayas entrado en un establecimiento.")
                    .font(.caption2).foregroundStyle(.secondary)
                if externalResults.contains(where:{$0.source == .openStreetMap}) {
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
                Text("Los sitios confirmados y propuestos se contabilizan por separado. Si divides una estancia, cada establecimiento suma solo los minutos de su tramo.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Sitios identificados",value:"\(model.data.identifiedSites.count)")
                LabeledContent("Estancias editadas",value:
                    "\(Set(model.data.siteStayParts.map(\.stayID)).count)")
                if computing { ProgressView("Calculando tiempos históricos…") }
            }
            Section("Mis sitios") {
                ForEach(model.data.identifiedSites) { site in
                    let total = totalsBySite[site.id] ?? SiteTimeTotal()
                    VStack(alignment:.leading,spacing:5) {
                        Label(site.name,systemImage:site.origin == "private" ? "house" : "mappin")
                            .font(.headline)
                        Text("\(total.verifiedVisits) estancias confirmadas · \(DurationFormat.full(total.verifiedSeconds))")
                            .font(.caption).foregroundStyle(.teal)
                        if total.suggestedVisits > 0 {
                            Text("\(total.suggestedVisits) propuestas sin confirmar · \(DurationFormat.full(total.suggestedSeconds))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,3)
                }
            }
        }
        .navigationTitle("Mis Sitios")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rebuild() }
        .onChange(of:model.data.siteStayParts.count) { _,_ in rebuild() }
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
