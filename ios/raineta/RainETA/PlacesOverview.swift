import SwiftUI

/// Horizontal comparison is deliberately tabular: one row per saved location,
/// with the same current-status and time-to-change columns.
struct PlacesOverview: View {
    @ObservedObject var store: RainStore
    var onSelect: () -> Void = {}
    @State private var showingSearch=false
    @State private var showingComparison=false
    @State private var showingOrder=false
    @State private var showingGPSName=false
    @State private var enteredGPSName=""
    @State private var renaming: SavedRainPlace?
    @State private var editedName=""

    var body: some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Mis lugares").font(.title3.bold())
                    Text("\(store.allPlaceRows.count) ubicaciones")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.summariesLoading { ProgressView().controlSize(.mini) }
                Button { showingOrder=true } label: {
                    Image(systemName:"arrow.up.arrow.down")
                }
                .disabled(store.savedPlaces.count<2)
                .accessibilityLabel("Ordenar lugares")
                Button {
                    Task { await store.refreshSummaries(force:true) }
                } label:{ Image(systemName:"arrow.clockwise") }
                .accessibilityLabel("Actualizar todas las ubicaciones")
                Button { showingSearch=true } label:{
                    Label("Añadir",systemImage:"plus")
                }
                .buttonStyle(.borderedProminent).tint(.cyan).foregroundStyle(.black)
                .controlSize(.small)
            }
            Button { showingComparison=true } label:{
                HStack {
                    Label("Comparador en directo",systemImage:"tablecells.fill")
                        .font(.caption.bold())
                    Spacer()
                    Text("Ampliar")
                        .font(.caption2)
                    Image(systemName:"arrow.up.right")
                }
                .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal) {
                VStack(spacing:0) {
                    header
                    ForEach(store.allPlaceRows) { place in
                        TimelineView(.periodic(from:.now,by:30)) { timer in
                            row(place,now:timer.date)
                        }
                        Divider().overlay(.white.opacity(0.08))
                    }
                }
                .frame(minWidth:355)
            }
            .scrollIndicators(.visible)
            .padding(8)
            .background(Color(red:0.03,green:0.12,blue:0.22),in:RoundedRectangle(cornerRadius:15))

            if store.gpsCoordinate != nil {
                Button { enteredGPSName = "";showingGPSName=true } label:{
                    Label("Guardar mi posición con un nombre propio",systemImage:"mappin.and.ellipse")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            } else {
                Text("Esperando coordenadas GPS para guardar un punto fijo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("SÍ/NO es la estimación actual del modelo, no una comprobación física de lluvia. El contador se actualiza localmente; los datos meteorológicos se renuevan al consultar.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .sheet(isPresented:$showingComparison) {
            RainLiveComparison(store:store,onSelect:onSelect)
        }
        .sheet(isPresented:$showingSearch) {
            PlaceSearchSheet(store:store,onSelect:onSelect)
        }
        .sheet(isPresented:$showingOrder) {
            NavigationStack {
                List {
                    Section {
                        Label("Mi ubicación GPS permanece primera",systemImage:"location.fill")
                            .foregroundStyle(.secondary)
                    }
                    Section("Arrastra para ordenar tus lugares") {
                        ForEach(store.savedPlaces) { place in
                            Label(place.name,systemImage:"mappin")
                        }
                        .onMove(perform:store.moveSavedPlaces)
                    }
                }
                .environment(\.editMode,.constant(.active))
                .navigationTitle("Ordenar lugares")
                .toolbar {
                    ToolbarItem(placement:.topBarTrailing) {
                        Button("Hecho") {showingOrder=false}
                    }
                }
            }
        }
        .sheet(isPresented:$showingGPSName) {
            NavigationStack {
                Form {
                    TextField("Ej.: Casa, Oficina, Colegio…",text:$enteredGPSName)
                        .textInputAutocapitalization(.words)
                    if let coord=store.gpsCoordinate {
                        Text(String(format:"Coordenadas fijas: %.4f, %.4f",coord.latitude,coord.longitude))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("El lugar guardado conserva estas coordenadas aunque te desplaces.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("Guardar lugar GPS")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button("Cancelar"){showingGPSName=false}
                    }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("Guardar") {
                            store.saveGPSPlace(named:enteredGPSName)
                            showingGPSName=false
                        }
                        .disabled(enteredGPSName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Renombrar lugar",isPresented:Binding(
            get:{renaming != nil},
            set:{if !$0 {renaming=nil}}
        )) {
            TextField("Nombre",text:$editedName)
            Button("Cancelar",role:.cancel) {renaming=nil}
            Button("Guardar") {
                if let place=renaming {store.renamePlace(place.id,to:editedName)}
                renaming=nil
            }
        } message:{
            Text("El alias queda guardado únicamente en este iPhone.")
        }
    }

    private var header:some View {
        HStack(spacing:7) {
            heading("LUGAR",width:110)
            heading("LLUEVE",width:50)
            heading("CAMBIO",width:87)
            heading("°C",width:43)
            heading("OPC.",width:37)
        }
        .padding(.horizontal,6).padding(.vertical,9)
        .background(.cyan.opacity(0.10),in:RoundedRectangle(cornerRadius:8))
    }

    private func heading(_ text:String,width:CGFloat)->some View {
        Text(text).font(.system(size:10,weight:.bold))
            .foregroundStyle(.cyan)
            .frame(width:width,alignment:.leading)
    }

    private func row(_ place:PlaceListRow,now:Date)->some View {
        let summary=store.quickSummaries[place.id]
        let stale=summary.map { now.timeIntervalSince($0.checkedAt)>20*60 } ?? true
        let target=summary.map{$0.raining ? $0.until : $0.nextRain} ?? nil
        return HStack(spacing:7) {
            Button {
                store.selectPlace(place.id)
                onSelect()
            } label:{
                HStack(spacing:4) {
                    Image(systemName:place.id=="gps" ? "location.fill":"mappin")
                        .foregroundStyle(.cyan)
                    Text(place.name).font(.system(size:12,weight:.semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .foregroundStyle(.white)
                    if store.selectedPlaceID==place.id {
                        Image(systemName:"checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                    }
                }
                .frame(width:110,alignment:.leading)
            }
            .buttonStyle(.plain)
            Group {
                if stale { Text("—").foregroundStyle(.secondary) }
                else {
                    Text(summary?.raining == true ? "SÍ" : "NO")
                        .foregroundStyle(summary?.raining == true ? .cyan : .green)
                }
            }
            .font(.system(size:15,weight:.heavy))
            .frame(width:50,alignment:.leading)
            Text(stale ? "Sin datos" : RainInsight.countdown(to:target,at:now))
                .font(.system(size:12,weight:.bold,design:.rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width:87,alignment:.leading)
            Text(summary?.temperatureLabel ?? "—")
                .font(.subheadline.bold())
                .frame(width:43,alignment:.leading)
            Menu {
                Button("Abrir",systemImage:"arrow.up.forward") {
                    store.selectPlace(place.id);onSelect()
                }
                if place.id=="gps" {
                    Button("Guardar GPS con nombre",systemImage:"star") {
                        enteredGPSName="";showingGPSName=true
                    }
                } else {
                    Button("Renombrar",systemImage:"pencil") {
                        renaming=store.savedPlaces.first(where:{$0.id==place.id})
                        editedName=place.name
                    }
                    Button("Eliminar",systemImage:"trash",role:.destructive) {
                        store.deletePlace(place.id)
                    }
                }
            } label:{
                Image(systemName:stale ? "exclamationmark.circle":"ellipsis.circle")
                    .foregroundStyle(stale ? .yellow : .cyan)
                    .frame(width:37)
            }
        }
        .padding(.horizontal,6).padding(.vertical,12)
    }
}

struct RainLiveComparison: View {
    @ObservedObject var store:RainStore
    var onSelect:()->Void
    @Environment(\.dismiss) private var dismiss

    var body:some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing:11) {
                    ForEach(store.allPlaceRows) { place in
                        TimelineView(.periodic(from:.now,by:30)) { clock in
                            let summary=store.quickSummaries[place.id]
                            let stale=summary.map {
                                clock.date.timeIntervalSince($0.checkedAt)>20*60
                            } ?? true
                            let next=summary.map { $0.raining ? $0.until : $0.nextRain } ?? nil
                            Button {
                                store.selectPlace(place.id)
                                dismiss()
                                onSelect()
                            } label:{
                                VStack(alignment:.leading,spacing:10) {
                                    HStack {
                                        Label(place.name,systemImage:"mappin")
                                            .font(.headline)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(stale ? "DATOS PENDIENTES":
                                             summary?.raining == true ? "LLUEVE":"NO LLUEVE")
                                            .font(.caption.bold())
                                            .foregroundStyle(stale ? .yellow :
                                                        summary?.raining == true ? .cyan:.green)
                                    }
                                    HStack {
                                        VStack(alignment:.leading) {
                                            Text("Próximo cambio").font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(stale ? "—":RainInsight.countdown(to:next,at:clock.date))
                                                .font(.title3.bold().monospacedDigit())
                                        }
                                        Spacer()
                                        VStack(alignment:.trailing) {
                                            Text("Temperatura").font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(summary?.temperatureLabel ?? "—")
                                                .font(.title3.bold())
                                        }
                                        Image(systemName:"chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(16)
                                .background(.white.opacity(0.065),
                                            in:RoundedRectangle(cornerRadius:16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(red:0.035,green:0.067,blue:0.12))
            .navigationTitle("Comparador en directo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Button("Actualizar") {
                        Task {await store.refreshSummaries(force:true)}
                    }
                    .disabled(store.summariesLoading)
                }
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar"){dismiss()}
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct PlaceSearchSheet: View {
    @ObservedObject var store: RainStore
    var onSelect: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [FoundRainPlace] = []
    @State private var loading = false
    @State private var failed = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Ciudad, localidad o código postal", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { searchTask?.cancel(); searchTask = Task { await search() } }
                    Button("Buscar") {
                        searchTask?.cancel()
                        searchTask = Task { await search() }
                    }
                    .disabled(query.count < 2)
                }
                .padding(12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if loading { ProgressView("Buscando localidades…") }
                if failed { Text("No se pudo buscar. Inténtalo de nuevo.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        Button {
                            store.selectPlace("gps")
                            dismiss()
                            onSelect()
                        } label: {
                            Label("Usar mi ubicación GPS", systemImage: "location.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        ForEach(matches) { found in
                            Button {
                                store.addPlace(name: found.name, latitude: found.latitude,
                                               longitude: found.longitude, select: true)
                                dismiss()
                                onSelect()
                            } label: {
                                HStack {
                                    Image(systemName: "mappin")
                                        .foregroundStyle(.cyan)
                                    Text(found.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus.circle")
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Añadir lugar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } }
            }
            .onChange(of: query) { _, next in
                searchTask?.cancel()
                if next.count < 2 {
                    matches = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !Task.isCancelled { await search() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, !Task.isCancelled else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let result = try await RainPlacesAPI.find(term)
            if !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == term {
                matches = result
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
