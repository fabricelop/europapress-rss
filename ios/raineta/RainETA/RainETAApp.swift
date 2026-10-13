import SwiftUI
import MapKit

@main
struct RainETAApp: App {
    var body: some Scene {
        WindowGroup { RainTabRoot() }
    }
}

struct RainTabRoot: View {
    @StateObject private var store = RainStore()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $selectedTab) {
            RainHomeView(store: store)
                .tabItem { Label("Inicio", systemImage: "cloud.rain.fill") }
                .tag(0)
            NavigationStack {
                ScrollView {
                    PlacesOverview(store: store, onSelect: { selectedTab = 0 })
                        .padding(16)
                }
                .background(Color(red: 0.035, green: 0.067, blue: 0.12))
                .navigationTitle("Mis lugares")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await store.refreshSummaries(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .tabItem { Label("Mis lugares", systemImage: "mappin.and.ellipse") }
            .tag(1)
            NavigationStack {
                RainSettingsView(store:store)
            }
            .tabItem { Label("Ajustes", systemImage:"gearshape.fill") }
            .tag(2)
        }
        .preferredColorScheme(.dark)
        .task {
            store.start()
            while !Task.isCancelled {
                let interval = UserDefaults.standard.integer(forKey: "raineta.settings.refresh")
                let seconds = interval == 120 || interval == 600 ? interval : 240
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if phase == .active {
                    await store.refresh()
                    await store.refreshSummaries()
                }
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await store.refresh(force: true)
                    await store.refreshSummaries()
                }
            }
        }
    }
}

struct RainHomeView: View {
    @ObservedObject var store: RainStore
    @Environment(\.scenePhase) private var phase
    @State private var fullRadar = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RainHeroCard(store:store)
                    radarSection
                    MinuteRainGraph(projection: store.projection, weather: store.snapshot)
                    ThreeHourRainView(weather:store.snapshot)
                    RainWeekForecast(weather: store.snapshot)
                    RainMultiModelView(coordinate:store.coordinate.latitude,longitude:store.coordinate.longitude,primary:store.snapshot)
                    footer
                }
                .padding(16)
            }
            .background(Color(red: 0.035, green: 0.067, blue: 0.12))
            .preferredColorScheme(.dark)
            .navigationTitle("RainETA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(store.loading)
                }
            }
            .refreshable {
                await store.refresh(force: true)
                await store.refreshSummaries(force: true)
            }
            .sheet(isPresented: $fullRadar) {
                NavigationStack {
                    ScrollView {
                        RadarSection(store: store, expanded: true)
                            .padding(.horizontal,16)
                            .padding(.top,12)
                    }
                    .background(Color(red: 0.035, green: 0.067, blue: 0.12))
                    .navigationTitle("Radar de lluvia")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { fullRadar = false }
                    }}
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private var radarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Radar y previsión", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button { fullRadar = true } label: {
                    Label("Ampliar", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
            }
            RadarSection(store: store, expanded: false)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.status)
            Text("v0.6.0 · Observación RainViewer y previsión oficial ICON-EU (DWD), con mapas completos en vez de interpolación de 9×9 puntos.")
            Text(store.futureFieldStatus)
            Text("Radar: RainViewer (rainviewer.com) · Modelo: Open-Meteo. Favoritos guardados únicamente en este iPhone.")
            Text("En Vivo mantiene el contador con la pantalla bloqueada, pero iOS puede suspender las actualizaciones meteorológicas en segundo plano.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func headline(_ wx: RainSnapshot, now: Date) -> String {
        guard let target = wx.nextChange else {
            return wx.isRaining ? "Está lloviendo" : "Sin lluvia próxima"
        }
        let minutes = max(0, Int(ceil(target.timeIntervalSince(now) / 60)))
        if minutes == 0 { return wx.isRaining ? "Dejará de llover pronto" : "Lluvia inminente" }
        return wx.isRaining ? "Termina en \(minutes) min" : "Lluvia en \(minutes) min"
    }

    private func barColor(_ mm: Double) -> Color {
        if mm < 0.08 { return .gray.opacity(0.2) }
        if mm < 0.5 { return .cyan }
        if mm < 1.6 { return .blue }
        return .purple
    }
}

struct RadarSection: View {
    @ObservedObject var store: RainStore
    var expanded: Bool
    @State private var playing = false

    private var selected: RadarFrame? {
        let frames = store.radar.frames
        guard !frames.isEmpty else { return nil }
        return frames[min(frames.count - 1, max(0, store.radarIndex))]
    }
    private var finalPastIndex: Int { max(0, store.radar.frames.count - 1) }
    private var lastSliderIndex: Int {
        finalPastIndex + (ICONForecastTiles.covers(store.coordinate) ? 16 : 0)
    }
    private var sliderSelection: Double {
        Double(store.radarFutureMinutes > 0 ?
               finalPastIndex + store.radarFutureMinutes / 15 : store.radarIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RadarMap(center: store.coordinate, host: store.radar.host,
                     framePath: selected?.path,
                     projection: nil,
                     modelField: nil,
                     futureMinutes: store.radarFutureMinutes,
                     forecastStatus: { status in
                         store.futureFieldStatus = status
                     })
                .frame(height: expanded ? 540 : 325)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    Text(store.radarFutureMinutes > 0 ? "ICON-EU · INTERPOLADO" : "RADAR OBSERVADO")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(store.radarFutureMinutes > 0 ? .yellow : .white)
                        .padding(8)
                        .background(.black.opacity(0.77), in: Capsule())
                        .padding(8)
                }
            HStack {
                if store.radarFutureMinutes > 0 {
                    Text("Futuro +\(store.radarFutureMinutes) min")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Text(Date().addingTimeInterval(Double(store.radarFutureMinutes*60))
                        .formatted(date: .omitted, time: .shortened))
                } else {
                    Text(selected.map { "Observado " + $0.date.formatted(date: .omitted, time: .shortened) } ?? "Sin radar")
                    Spacer()
                    Text(selected.map { "hace " + String(max(0, Int(Date().timeIntervalSince($0.date) / 60))) + " min" } ?? "")
                }
            }
            .font(.caption.monospacedDigit())

            Slider(value: Binding(get: { sliderSelection }, set: { value in
                let index = Int(value.rounded())
                if index > finalPastIndex, ICONForecastTiles.covers(store.coordinate) {
                    store.radarFutureMinutes = (index-finalPastIndex) * 15
                    store.radarIndex = finalPastIndex
                } else {
                    store.radarFutureMinutes = 0
                    store.radarIndex = max(0, min(finalPastIndex, index))
                }
            }), in: 0...Double(max(1, lastSliderIndex)), step: 1)
                .disabled(store.radar.frames.count < 2)
                .tint(.cyan)

            HStack(spacing: 10) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.radar.frames.count < 2)
                Text("Pasado")
                Spacer()
                Button("Ahora") {
                    store.radarIndex = finalPastIndex
                    store.radarFutureMinutes = 0
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if ICONForecastTiles.covers(store.coordinate) {
                    Button("+15 m") {
                        store.radarIndex = finalPastIndex
                        store.radarFutureMinutes = min(240,store.radarFutureMinutes + 15)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("−15 m") {
                        store.radarIndex = finalPastIndex
                        store.radarFutureMinutes = max(0,store.radarFutureMinutes - 15)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .font(.caption)
            Text(store.radarFutureMinutes > 0
                 ? "Transición visual cada 15 min entre campos horarios ICON-EU: no son predicciones independientes de 15 min."
                 : "Radar observado hasta Ahora. Después, campos horarios ICON-EU con pasos visuales de 15 min hasta +4 h.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(store.futureFieldStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Colores homogéneos; resolución real del modelo ~6 km. Ampliar no crea más detalle.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Link("Fuente del modelo: Deutscher Wetterdienst (DWD)", destination: URL(string: "https://www.dwd.de/")!)
                .font(.caption2)
            Link("Datos radar: RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
                .font(.caption2)
            .task(id: playing) {
                while playing && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    if Task.isCancelled || !playing { break }
                    let n = finalPastIndex
                    if store.radarFutureMinutes > 0 {
                        if store.radarFutureMinutes >= 240 { playing = false }
                        else { store.radarFutureMinutes += 15 }
                    } else if store.radarIndex < n {
                        store.radarIndex += 1
                    } else if ICONForecastTiles.covers(store.coordinate) {
                        store.radarFutureMinutes = 15
                    } else { playing = false }
                }
            }
        }
    }
}
