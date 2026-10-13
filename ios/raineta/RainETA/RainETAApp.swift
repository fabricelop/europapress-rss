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
                    MinuteRainGraph(projection:store.projection,weather:store.snapshot)
                    ThreeHourRainView(weather:store.snapshot)
                    RainWeekForecast(weather:store.snapshot)
                    radarSection
                    RainMultiModelView(coordinate:store.coordinate.latitude,longitude:store.coordinate.longitude,primary:store.snapshot)
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
    @ObservedObject var store:RainStore
    let expanded:Bool
    @State private var playing=false
    @State private var recenterRevision=0

    private var frames:[RadarFrame] { store.radar.frames }
    private var pastEnd:Int {max(0,frames.count-1)}
    private var futureSteps:Int {ICONForecastTiles.covers(store.coordinate) ? 48 : 0}
    private var sliderIndex:Double {
        Double(store.radarFutureMinutes>0 ?
               pastEnd + store.radarFutureMinutes/5 : store.radarIndex)
    }
    private var observed:RadarFrame? {
        guard !frames.isEmpty else{return nil}
        return frames[max(0,min(pastEnd,store.radarIndex))]
    }
    private var historyMinutes:Int {
        guard let first=frames.first,let last=frames.last else{return 0}
        return max(0,Int(last.date.timeIntervalSince(first.date)/60))
    }

    private func select(_ index:Int) {
        let next=max(0,min(pastEnd+futureSteps,index))
        if next>pastEnd {
            store.radarIndex=pastEnd
            store.radarFutureMinutes=min(240,(next-pastEnd)*5)
        } else {
            store.radarIndex=next
            store.radarFutureMinutes=0
        }
    }
    private func step(_ direction:Int) {
        if store.radarFutureMinutes>0 {
            let offset=store.radarFutureMinutes+direction*5
            if offset<=0 {select(pastEnd)}
            else {select(pastEnd+offset/5)}
        } else {
            // Real past frames can be 5 or 10 minutes apart, depending on
            // what RainViewer delivered. Never invent a past observation.
            select(store.radarIndex+direction)
        }
    }
    private func now() {playing=false;select(pastEnd)}

    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            RadarMap(center:store.coordinate,host:store.radar.host,
                     framePath:observed?.path,projection:nil,modelField:nil,
                     futureMinutes:store.radarFutureMinutes,
                     recenterRevision:recenterRevision,
                     forecastStatus:{store.futureFieldStatus=$0})
                .frame(height:expanded ? 540 : 325)
                .clipShape(RoundedRectangle(cornerRadius:16))
                .overlay(alignment:.topTrailing) {
                    Text(store.radarFutureMinutes>0 ? "ICON-EU · MODELO" : "RADAR OBSERVADO")
                        .font(.system(size:10,weight:.bold))
                        .foregroundStyle(store.radarFutureMinutes>0 ? .yellow:.white)
                        .padding(9)
                        .background(.black.opacity(0.78),in:Capsule())
                        .padding(9)
                }
                .overlay(alignment:.bottomTrailing) {
                    Button {
                        recenterRevision += 1
                    } label:{
                        Image(systemName:"location.north.line.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                            .frame(width:41,height:41)
                            .background(.black.opacity(0.80),in:Circle())
                    }
                    .accessibilityLabel("Centrar mapa en la localidad seleccionada")
                    .padding(10)
                }

            HStack {
                if store.radarFutureMinutes>0 {
                    Text("Futuro +\(store.radarFutureMinutes) min")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Text(Date().addingTimeInterval(Double(store.radarFutureMinutes*60))
                        .formatted(date:.omitted,time:.shortened))
                } else {
                    Text(observed.map{"Observado "+$0.date.formatted(date:.omitted,time:.shortened)}
                         ?? "Radar pendiente")
                    Spacer()
                    Text(observed.map{"hace \(max(0,Int(Date().timeIntervalSince($0.date)/60))) min"} ?? "")
                }
            }
            .font(.caption.monospacedDigit())

            GeometryReader { proxy in
                let fraction=CGFloat(pastEnd)/CGFloat(max(1,pastEnd+futureSteps))
                let markX=18+(proxy.size.width-36)*fraction
                ZStack(alignment:.topLeading) {
                    Slider(value:Binding(
                        get:{sliderIndex},
                        set:{select(Int($0.rounded()))}
                    ),in:0...Double(max(1,pastEnd+futureSteps)),step:1)
                        .tint(.cyan)
                        .disabled(frames.isEmpty)
                        .padding(.top,0)
                    Rectangle().fill(.cyan.opacity(0.8))
                        .frame(width:2,height:18)
                        .position(x:markX,y:10)
                        .allowsHitTesting(false)
                    Text("AHORA")
                        .font(.system(size:9,weight:.heavy))
                        .foregroundStyle(.cyan)
                        .fixedSize()
                        .position(x:min(max(28,markX),proxy.size.width-28),y:33)
                        .allowsHitTesting(false)
                }
            }
            .frame(height:42)

            HStack(spacing:10) {
                Button {playing.toggle()} label:{
                    Image(systemName:playing ? "pause.fill":"play.fill")
                }
                .accessibilityLabel(playing ? "Pausar radar":"Reproducir radar")
                Button {step(-1)} label:{
                    Image(systemName:"chevron.left")
                }
                .accessibilityLabel("Retroceder cinco minutos, o al radar anterior")
                .disabled(store.radarFutureMinutes==0 && store.radarIndex<=0)
                Button("Ahora"){now()}
                    .font(.caption.bold())
                Button {step(1)} label:{
                    Image(systemName:"chevron.right")
                }
                .accessibilityLabel("Avanzar cinco minutos, o al radar siguiente")
                .disabled(store.radarFutureMinutes>=240 ||
                          (store.radarFutureMinutes==0 &&
                           store.radarIndex>=pastEnd && futureSteps==0))
                Spacer(minLength:0)
                Text("−\(historyMinutes)m / +4h")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if store.futureFieldStatus.contains("no disponible") {
                Text("Previsión temporalmente no disponible")
                    .font(.caption2).foregroundStyle(.yellow)
            }
        }
        .task(id:playing) {
            while playing && !Task.isCancelled {
                let delay=store.radarFutureMinutes>0 ? 2_100_000_000:850_000_000
                try? await Task.sleep(nanoseconds:UInt64(delay))
                if Task.isCancelled || !playing {break}
                if sliderIndex>=Double(pastEnd+futureSteps) {playing=false}
                else {select(Int(sliderIndex)+1)}
            }
        }
    }
}
