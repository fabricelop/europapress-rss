import SwiftUI

struct PlacesOverview: View {
    @ObservedObject var store: RainStore
    @State private var showingSearch = false
    @State private var renaming: SavedRainPlace?
    @State private var editedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Mis lugares", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Spacer()
                if store.summariesLoading { ProgressView().controlSize(.mini) }
                Button {
                    Task { await store.refreshSummaries(force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Actualizar todas las ubicaciones")
                Button { showingSearch = true } label: {
                    Label("Añadir", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .foregroundStyle(.black)
                .controlSize(.small)
            }
            Text("Ahora · Próxima lluvia · Hasta cuándo · Según modelo Open-Meteo")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.allPlaceRows) { place in
                HStack(spacing: 6) {
                    Button { store.selectPlace(place.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: place.id == "gps" ? "location.fill" : "mappin.circle.fill")
                                    .foregroundStyle(.cyan)
                                Text(place.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Spacer()
                                if store.selectedPlaceID == place.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.cyan)
                                }
                                Text(store.quickSummaries[place.id]?.temperatureLabel ?? "—")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                metric("Ahora", nowText(place.id),
                                       store.quickSummaries[place.id]?.raining == true ? .cyan : .white)
                                metric("Próxima lluvia",
                                       store.quickSummaries[place.id]?.nextLabel ?? "—", .white)
                                metric("Hasta cuándo",
                                       store.quickSummaries[place.id]?.untilLabel ?? "—", .white)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(store.selectedPlaceID == place.id ?
                                    Color.cyan.opacity(0.14) : Color.white.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)

                    if place.id == "gps" {
                        Button {
                            store.saveGPSPlace()
                        } label: { Image(systemName: "star.badge.plus").frame(width: 25) }
                            .disabled(store.gpsCoordinate == nil)
                            .accessibilityLabel("Guardar posición GPS como lugar fijo")
                    } else {
                        Menu {
                            Button("Abrir", systemImage: "arrow.up.forward") { store.selectPlace(place.id) }
                            Button("Renombrar", systemImage: "pencil") {
                                renaming = store.savedPlaces.first(where: { $0.id == place.id })
                                editedName = place.name
                            }
                            Button("Eliminar", systemImage: "trash", role: .destructive) {
                                store.deletePlace(place.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(width: 25)
                        }
                        .accessibilityLabel("Opciones de \(place.name)")
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("El estado «LLUEVE» se basa en el modelo: puede diferir de la lluvia observada en la calle.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $showingSearch) {
            PlaceSearchSheet(store: store)
        }
        .alert("Renombrar lugar", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Nombre", text: $editedName)
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Guardar") {
                if let item = renaming { store.renamePlace(item.id, to: editedName) }
                renaming = nil
            }
        } message: {
            Text("El nombre se conservará en este iPhone.")
        }
    }

    private func nowText(_ id: String) -> String {
        guard let state = store.quickSummaries[id] else {
            if id == "gps" && store.gpsCoordinate == nil { return "Esperando GPS" }
            return store.quickFailures.contains(id) ? "Sin datos" : "Cargando…"
        }
        return state.nowLabel
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlaceSearchSheet: View {
    @ObservedObject var store: RainStore
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
