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
                    MinuteRainGraph(store:store)
                    ThreeHourRainView(store:store)
                    radarSection
                    RainWeekForecast(weather:store.snapshot,
                                     radarAvailable:store.radarLocal?.isFresh(at:Date()) == true)
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
    @ObservedObject var store: RainStore
    let expanded: Bool
    @State private var playing=false
    @State private var recenterRevision=0
    @State private var loadingFuture=false
    @State private var renderedFuture=0

    private var frames:[RadarFrame] {store.radar.frames}
    private var pastEnd:Int {max(0,frames.count-1)}
    private var newest:RadarFrame? {frames.last}
    private var nowcast:[RadarFrame] {store.radar.future}
    private var futureLimit:Int {
        guard let last=newest,let end=nowcast.last else {return 0}
        return min(60,max(0,(end.timestamp-last.timestamp)/60))
    }
    private var historyMinutes:Int {
        guard let first=frames.first,let last=newest else{return 0}
        return max(0,(last.timestamp-first.timestamp)/60)
    }
    private var selection:RadarFrame? {
        guard !frames.isEmpty else{return nil}
        if store.radarFutureMinutes > 0,let last=newest {
            let target=last.timestamp+store.radarFutureMinutes*60
            return nowcast.min(by:{abs($0.timestamp-target)<abs($1.timestamp-target)})
        }
        return frames[max(0,min(pastEnd,store.radarIndex))]
    }
    private var sliderMinute:Double {
        guard let now=newest,let selection else{return 0}
        return Double(selection.timestamp-now.timestamp)/60
    }

    private func choose(_ minutes:Int) {
        guard let last=newest else {return}
        if minutes>0 {
            guard !nowcast.isEmpty else{return}
            let target=last.timestamp+min(futureLimit,minutes)*60
            if let next=nowcast.min(by:{abs($0.timestamp-target)<abs($1.timestamp-target)}) {
                store.radarIndex=pastEnd
                store.radarFutureMinutes=max(1,(next.timestamp-last.timestamp)/60)
            }
        } else {
            let target=last.timestamp+minutes*60
            let closest=frames.enumerated().min(by:{
                abs($0.element.timestamp-target)<abs($1.element.timestamp-target)
            })?.offset ?? pastEnd
            store.radarIndex=closest
            store.radarFutureMinutes=0
            if minutes==0 {loadingFuture=false}
        }
    }

    private func step(_ direction:Int) {
        guard let selected=selection else{return}
        let entries=frames+nowcast
        guard let current=entries.firstIndex(where:{$0.timestamp==selected.timestamp}) else{return}
        let next=current+direction
        guard entries.indices.contains(next),let last=newest else{return}
        let target=entries[next]
        if target.timestamp>last.timestamp {
            choose((target.timestamp-last.timestamp)/60)
        } else {
            store.radarIndex=next
            store.radarFutureMinutes=0
        }
    }
    private func returnToNow() {playing=false;choose(0)}

    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            RadarMap(center:store.coordinate,host:store.radar.host,
                     framePath:frames.indices.contains(store.radarIndex)
                        ? frames[store.radarIndex].path : newest?.path,
                     projection:nil,modelField:nil,
                     futureMinutes:store.radarFutureMinutes,
                     nowcastPath:store.radarFutureMinutes>0 ? selection?.path : nil,
                     recenterRevision:recenterRevision,
                     forecastStatus:{store.futureFieldStatus=$0},
                     onForecastReady:{ minute,success in
                         if minute==store.radarFutureMinutes {
                             loadingFuture=false
                             if success {renderedFuture=minute}
                             else {playing=false}
                         }
                     })
                .frame(height:expanded ? 540:325)
                .clipShape(RoundedRectangle(cornerRadius:16))
                .overlay(alignment:.topTrailing) {
                    Text(store.radarFutureMinutes>0 ?
                         (loadingFuture ? "PREPARANDO PRONÓSTICO…" : "NOWCAST · LIBREWXR") :
                         "RADAR OBSERVADO")
                        .font(.system(size:10,weight:.bold))
                        .foregroundStyle(store.radarFutureMinutes>0 ? .yellow:.white)
                        .padding(9)
                        .background(.black.opacity(0.78),in:Capsule())
                        .padding(9)
                }
                .overlay(alignment:.bottomTrailing) {
                    Button {recenterRevision+=1} label:{
                        Image(systemName:"location.north.line.fill")
                            .font(.title3).foregroundStyle(.cyan)
                            .frame(width:41,height:41)
                            .background(.black.opacity(0.80),in:Circle())
                    }
                    .accessibilityLabel("Centrar mapa")
                    .padding(10)
                }

            HStack {
                if store.radarFutureMinutes>0 {
                    Text("Pronóstico +\(store.radarFutureMinutes) min")
                        .foregroundStyle(.yellow)
                } else {
                    Text(selection.map{"Observado "+$0.date.formatted(date:.omitted,time:.shortened)}
                         ?? "Radar pendiente")
                }
                Spacer()
                Text(selection?.date.formatted(date:.omitted,time:.shortened) ?? "")
            }
            .font(.caption.monospacedDigit())

            GeometryReader { geometry in
                let width=geometry.size.width
                let span=max(10,historyMinutes)
                let range=Double(-span)...Double(max(0,futureLimit))
                let total=Double(span+max(0,futureLimit))
                let markerX=18+(width-36)*CGFloat(Double(span)/total)
                ZStack(alignment:.topLeading) {
                    Slider(value:Binding(
                        get:{sliderMinute},
                        set:{choose(Int($0.rounded()))}
                    ),in:range,step:5)
                        .tint(.cyan)
                        .disabled(frames.isEmpty)
                    Rectangle().fill(.cyan)
                        .frame(width:2,height:18)
                        .position(x:markerX,y:10)
                        .allowsHitTesting(false)
                    Text("AHORA")
                        .font(.system(size:9,weight:.heavy))
                        .foregroundStyle(.cyan)
                        .position(x:min(max(28,markerX),width-28),y:32)
                        .allowsHitTesting(false)
                }
            }
            .frame(height:43)

            HStack(spacing:10) {
                Button {playing.toggle()} label:{
                    Image(systemName:playing ? "pause.fill":"play.fill")
                }
                Button {step(-1)} label:{Image(systemName:"chevron.left")}
                    .disabled(selection?.timestamp == frames.first?.timestamp)
                Button("Ahora"){returnToNow()}
                    .font(.caption.bold())
                Button {step(1)} label:{Image(systemName:"chevron.right")}
                    .disabled(selection?.timestamp == (nowcast.last ?? newest)?.timestamp)
                Spacer()
                Text("−\(historyMinutes)m / +\(futureLimit)m")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(futureLimit>0 ?
                 "Observado y previsión 0–60 min: misma fuente. Pronóstico experimental cada 10 min; hasta +120 min, consulta Pulso de lluvia." :
                 "Solo radar observado disponible. No se inventan fotogramas futuros.")
                .font(.caption2).foregroundStyle(.secondary)
            if store.futureFieldStatus.contains("no disponible") {
                Text(store.futureFieldStatus).font(.caption2).foregroundStyle(.yellow)
            }
            Text("Radar: \(store.radar.source) · datos por \(store.radar.source == "LibreWXR" ? "LibreWXR":"RainViewer")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of:store.radarFutureMinutes) {_,lead in
            loadingFuture=lead>0 && lead != renderedFuture
            if lead==0 {renderedFuture=0;loadingFuture=false}
        }
        .task(id:playing) {
            while playing && !Task.isCancelled {
                if loadingFuture {
                    try? await Task.sleep(nanoseconds:160_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds:1_050_000_000)
                if Task.isCancelled || !playing {break}
                if loadingFuture {continue}
                guard let selected=selection else{playing=false;break}
                let end=(nowcast.last ?? newest)?.timestamp
                if selected.timestamp==end {playing=false}
                else {step(1)}
            }
        }
    }
}
