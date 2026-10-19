import SwiftUI

/// Dynamic time display: SwiftUI TimelineView recomputes elapsed time
/// locally, without claiming that weather observations refresh every second.
struct RainHeroCard: View {
    @ObservedObject var store:RainStore

    private func radarConfirmedDisplay(_ store:RainStore)->Bool {
        let now=Date()
        return store.radarLocal?.isFresh(at:now)==true &&
               store.shortEstimate?.isUsable(at:now)==true &&
               store.shortEstimate?.radarBased==true
    }

    var body:some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                Label(store.name,systemImage:"location.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
            if let weather=store.snapshot {
                TimelineView(.periodic(from:.now,by:1)) { clock in
                    let moment=clock.date
                    let fallback=RainInsight.transition(currentIsRaining:weather.isRaining,
                                                        samples:weather.samples,now:moment)
                    let short=store.shortEstimate?.isUsable(at:moment)==true
                        ? store.shortEstimate : nil
                    let raining=short?.rainingNow ?? fallback.raining
                    let radarConfirmed=short?.radarBased==true
                    let nextChange=short?.change ?? fallback.change
                    let phase=weather.phase(at:raining ? moment : (nextChange ?? moment))
                    let precipitation=phase.label
                    VStack(alignment:.leading,spacing:10) {
                        HStack(alignment:.center) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(radarConfirmed ?
                                     (raining ? "RADAR: PRECIPITACIÓN DETECTADA" : "RADAR: SIN ECO LOCAL") :
                                     (raining ? "MODELO PREVÉ PRECIPITACIÓN · NO CONFIRMADA" :
                                                "MODELO PREVÉ TIEMPO SECO"))
                                    .font(.system(size:10,weight:.heavy))
                                    .foregroundStyle(raining ? .cyan : .green)
                                Text(radarConfirmed ?
                                         (raining ? "¿Cuándo terminará la precipitación?" :
                                                    "¿Cuándo llegará la \(precipitation)?") :
                                         (raining ? "¿Hasta cuándo prevé \(precipitation)?" :
                                                    "¿Cuándo prevé \(precipitation)?"))
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.76))
                            }
                            Spacer()
                            Image(systemName:raining ? phase.glyph : "cloud.fill")
                                .font(.system(size:40))
                                .foregroundStyle(raining ? .cyan : .yellow)
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text(nextChange == nil ? "Sin cambio previsto" : RainInsight.countdown(to:nextChange,at:moment))
                            .font(.system(size:nextChange == nil ? 29 : 45,
                                          weight:.bold,design:.rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                        HStack {
                            Text(nextChange.map {
                                "Cambio estimado: " + $0.formatted(date:.omitted,time:.shortened)
                            } ?? "Sin cambio próximo con hora fiable")
                                .font(.caption)
                                .foregroundStyle(.cyan)
                            Spacer()

                        }
                        Text(store.radarAnalysisStatus)
                            .font(.caption2)
                            .foregroundStyle(radarConfirmed ? .mint : .yellow)
                        if let short {
                            HStack(spacing:6) {
                                Text(short.method + " · " + short.confidence)
                                Spacer(minLength:0)
                            }
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            if let low=short.windowStart,let high=short.windowEnd {
                                Text((raining ? "Final orientativo: " : "Llegada orientativa: ") +
                                     low.formatted(date:.omitted,time:.shortened) + "–" +
                                     high.formatted(date:.omitted,time:.shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                HStack(spacing:10) {
                    if let temperature=weather.temperature {
                        Label(String(format:"%.0f °C",temperature),systemImage:"thermometer.medium")
                    }
                    Label(radarConfirmedDisplay(store) ?
                          ((store.minuteForecast(now:Date(),horizon:0).first?.rate ?? 0)>=0.15 ?
                              "Eco de precipitación" : "Radar: seco") :
                          "Modelo: " + weather.phase().label,
                          systemImage:"drop.fill")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.9))
                HStack {
                    Label("Actualizado \(weather.updatedAt.formatted(date:.omitted,time:.shortened))",
                          systemImage:"clock.arrow.circlepath")
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView("Calculando el próximo cambio…")
                    .padding(.vertical,30)
            }
        }
        .padding(18)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(
            LinearGradient(colors:[Color(red:0.02,green:0.22,blue:0.35),
                                   Color(red:0.07,green:0.08,blue:0.23)],
                           startPoint:.topLeading,endPoint:.bottomTrailing),
            in:RoundedRectangle(cornerRadius:24)
        )
        .overlay(RoundedRectangle(cornerRadius:24).stroke(.cyan.opacity(0.24),lineWidth:1))
    }
}

struct RainSettingsView: View {
    @ObservedObject var store:RainStore
    @AppStorage("raineta.settings.refresh") private var refreshSeconds=240
    @AppStorage("raineta.settings.defaultHorizon") private var defaultHorizon=60
    @State private var explicitLiveConfirmation=false

    var body:some View {
        Form {
            Section {
                HStack {
                    Image(systemName:"livephoto").foregroundStyle(.cyan)
                    VStack(alignment:.leading) {
                        Text("Actividad En Vivo")
                            .font(.headline)
                        Text(store.liveEnabled ? "Activa en la pantalla bloqueada" : "Desactivada")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("",isOn:Binding(
                        get:{store.liveEnabled},
                        set:{ next in
                            if next { explicitLiveConfirmation=true }
                            else { Task { await store.toggleLive() } }
                        }
                    ))
                    .labelsHidden()
                }
                Text(store.liveStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text("La actividad muestra lluvia/nieve, cuenta atrás, franja de precipitación de 60 min, fuente y hora de actualización. No depende de un widget de pantalla de inicio. Si iOS suspende RainETA, la predicción quedará marcada como antigua; el contador no recibe datos nuevos por sí solo.")
                    .font(.caption2).foregroundStyle(.secondary)
            } header:{Label("Pantalla bloqueada",systemImage:"lock.iphone")}

            Section {
                LabeledContent("Permiso actual",value:store.locationPermission)
                Button("Solicitar localización «Siempre»") {store.requestAlwaysLocation()}
                Text("La ubicación puede actualizarse al desplazarte si has concedido permiso; esto no garantiza consultas meteorológicas constantes en segundo plano.")
                    .font(.caption2).foregroundStyle(.secondary)
            } header:{Label("Ubicación",systemImage:"location.fill")}

            Section("Actualización") {
                Picker("Con la app abierta",selection:$refreshSeconds) {
                    Text("2 minutos").tag(120)
                    Text("4 minutos").tag(240)
                    Text("10 minutos").tag(600)
                }
                Button("Actualizar ahora") {
                    Task {
                        await store.refresh(force:true)
                        await store.refreshSummaries(force:true)
                    }
                }
                if store.loading {ProgressView("Consultando…")}
            }

            Section("Visualización") {
                Picker("Mostrar al abrir Pulso",selection:$defaultHorizon) {
                    Text("30 minutos").tag(30)
                    Text("60 minutos").tag(60)
                    Text("120 minutos").tag(120)
                }
                Text("Prioridad a lluvia y nieve. El Pulso de precipitación muestra 30, 60 o 120 minutos; la resolución de 1 minuto es visual, no una medición nueva cada minuto.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Datos y fiabilidad") {
                LabeledContent("Observación radar",value:"RainViewer")
                LabeledContent("Modelo por horas",value:"Open-Meteo")
                LabeledContent("Modelos en Pulso",value:"\(store.shortModels.count) de 5")
                Text("ECMWF IFS · DWD ICON · NOAA GFS · Météo-France · UKMO")
                    .font(.caption2).foregroundStyle(.secondary)
                Link("Fuentes y licencia UKMO (CC BY-SA 4.0)",destination:URL(string:"https://open-meteo.com/en/docs/ukmo-api")!)
                    .font(.caption2)
                LabeledContent("Radar observado",value:store.radar.source)
                LabeledContent("Predicción del mapa",value:store.radar.hasNowcast ? "LibreWXR · +60 min":"No disponible")
                LabeledContent("Pulso local",value:"Hasta +120 min")
                Text("El nowcast LibreWXR es experimental y combina radar europeo y modelos. Solo se dibujan tiempos proporcionados por la API; después de +60 min consulta el Pulso local.")
                    .font(.caption2).foregroundStyle(.secondary)
                Link("Crédito y licencia de LibreWXR",destination:URL(string:"https://librewxr.net/")!)
                    .font(.caption)
            }
        }
        .navigationTitle("Ajustes")
        .preferredColorScheme(.dark)
        .confirmationDialog("Activar En Vivo",isPresented:$explicitLiveConfirmation) {
            Button("Activar") { Task { await store.toggleLive() } }
            Button("Cancelar",role:.cancel) {}
        } message:{
            Text("La actividad utilizará el lugar seleccionado y mostrará el estado hasta la siguiente actualización posible.")
        }
    }
}
