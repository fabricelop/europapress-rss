import SwiftUI
import MapKit

@main
struct RainETAApp: App {
    var body: some Scene {
        WindowGroup { RainHomeView() }
    }
}

struct RainHomeView: View {
    @StateObject private var store = RainStore()
    @Environment(\.scenePhase) private var phase
    @State private var fullRadar = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    radarSection
                    forecastSection
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
            .refreshable { await store.refresh(force: true) }
            .task {
                store.start()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 240_000_000_000)
                    if phase == .active { await store.refresh() }
                }
            }
            .onChange(of: phase) { _, value in
                if value == .active { Task { await store.refresh(force: true) } }
            }
            .sheet(isPresented: $fullRadar) {
                NavigationStack {
                    RadarSection(store: store, expanded: true)
                        .padding()
                        .background(Color(red: 0.035, green: 0.067, blue: 0.12))
                        .navigationTitle("Radar de lluvia")
                        .toolbar { ToolbarItem(placement: .topBarTrailing) {
                            Button("Cerrar") { fullRadar = false }
                        }}
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.name, systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.cyan)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
            if let weather = store.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(headline(weather, now: timeline.date))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text(weather.isRaining ? "Lluvia detectada por el modelo actual" : "Inicio estimado por modelo")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    if let t = weather.temperature {
                        Label(String(format: "%.0f °C", t), systemImage: "thermometer.medium")
                    }
                    Label(weather.isRaining ? "Lloviendo" : "Ahora sin lluvia", systemImage: "cloud.drizzle")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Actualizado \(weather.updatedAt.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Text("Modelo 15 min")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Button {
                    Task { await store.toggleLive() }
                } label: {
                    Label(store.liveEnabled ? "Desactivar En Vivo" : "Activar En Vivo",
                          systemImage: store.liveEnabled ? "checkmark.circle.fill" : "livephoto")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .foregroundStyle(.black)
            } else {
                ProgressView("Obteniendo predicción")
                    .padding(.vertical, 25)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
    }

    private var radarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Radar observado", systemImage: "dot.radiowaves.left.and.right")
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

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Próximas 3 horas", systemImage: "chart.bar.xaxis")
                .font(.headline)
            if let weather = store.snapshot {
                let soon = Array(weather.samples.prefix(12))
                if soon.isEmpty {
                    Text("No hay datos de precipitación de 15 minutos para este lugar.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(soon) { point in
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(barColor(point.precipitation))
                                    .frame(height: max(5, min(90, CGFloat(point.precipitation * 46))))
                                Text(point.time.formatted(.dateTime.hour().minute()))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 125)
                    Text("Altura = precipitación prevista · Intervalos de 15 min · Modelo, no radar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.status)
            Text("v0.1.0 · Previsión Open-Meteo y radar RainViewer. El radar solo muestra observaciones; ninguna imagen futura se presenta como real.")
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

    private var selected: RadarFrame? {
        let frames = store.radar.frames
        guard !frames.isEmpty else { return nil }
        return frames[max(0, frames.count - 1 - store.radarOffset)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RadarMap(center: store.coordinate, host: store.radar.host, framePath: selected?.path)
                .frame(height: expanded ? 530 : 310)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    Text("RADAR HISTÓRICO")
                        .font(.system(size: 10, weight: .bold))
                        .padding(8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(8)
                }
            HStack {
                Text(selected?.date.formatted(date: .omitted, time: .shortened) ?? "Sin radar")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("Ahora") { store.radarOffset = 0 }
                    .font(.caption.bold())
            }
            Slider(value: Binding(
                get: { Double(store.radarOffset) },
                set: { store.radarOffset = Int($0) }
            ), in: 0...Double(max(1, store.radar.frames.count - 1)), step: 1)
                .disabled(store.radar.frames.count < 2)
                .tint(.cyan)
            HStack {
                Text("Más reciente")
                Spacer()
                Text("Retroceder en el tiempo →")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
