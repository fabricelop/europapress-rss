import SwiftUI
import WidgetKit
import ActivityKit

private struct GPSWidgetEntry: TimelineEntry {
    var date: Date
    var value: TimeWidgetSnapshot?
}

private struct GPSWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> GPSWidgetEntry {
        GPSWidgetEntry(date: .now,
            value: TimeWidgetSnapshot(
                recordedAt: .now, totalAssignedSeconds: 1_234_567,
                currentCellSeconds: 27_450, currentStaySeconds: 640,
                currentCellName: "Mi cuadrícula", lastLocationAt: .now,
                trackingEnabled: true, hasFix: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (GPSWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) :
                   GPSWidgetEntry(date: .now, value: TimeWidgetStorage.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GPSWidgetEntry>) -> Void) {
        let date = Date()
        let summary = TimeWidgetStorage.read()
        // Entradas futuras con la misma última muestra: la hora puede
        // actualizarse, pero los segundos no se inventan.
        let times = [0, 15, 30, 45].map { date.addingTimeInterval(TimeInterval($0 * 60)) }
        let entries = times.map { GPSWidgetEntry(date: $0, value: summary) }
        completion(Timeline(entries: entries,
                            policy: .after(date.addingTimeInterval(60 * 60))))
    }
}

private struct GPSWidgetFace: View {
    let entry: GPSWidgetEntry
    @Environment(\.widgetFamily) private var family

    private let ink=Color(red:0.09,green:0.20,blue:0.25)
    private let subdued=Color(red:0.24,green:0.35,blue:0.39)
    private var total: String {
        entry.value.map { TimeWidgetDuration.compact($0.totalAssignedSeconds) } ?? "—"
    }
    private var place: String {
        entry.value?.currentCellName ?? "Lugar privado"
    }
    private var stay: String {
        entry.value?.currentStaySeconds.map(TimeWidgetDuration.compact) ?? "—"
    }
    private var status: String {
        guard let value = entry.value else { return "Abre la app para conectar los widgets" }
        if !value.trackingEnabled { return "Seguimiento detenido" }
        if !value.locationIsRecent(at: entry.date) { return "Sin GPS reciente" }
        return "Última ubicación registrada"
    }

    var body: some View {
        Group {
            if entry.value == nil {
                switch family {
                case .accessoryInline:
                    Text("Mi Mapa Prueba · Abrir").foregroundStyle(ink)
                case .accessoryCircular:
                    Image(systemName:"map.fill").font(.title3).foregroundStyle(ink)
                case .accessoryRectangular:
                    VStack(alignment:.leading,spacing:2) {
                        Text("Mi Mapa Prueba").font(.headline).foregroundStyle(ink)
                        Text("Abrir mapa").font(.caption2).foregroundStyle(subdued)
                    }
                default:
                    VStack(alignment:.leading,spacing:8) {
                        Label("Mi Mapa Prueba",systemImage:"map.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(ink)
                        Spacer(minLength:2)
                        Image(systemName:"map.circle.fill")
                            .font(.system(size:38)).foregroundStyle(.teal)
                        Text("Abrir mi mapa")
                            .font(.headline).foregroundStyle(ink)
                        Text("Datos no disponibles: App Group sin autorización")
                            .font(.caption2).foregroundStyle(subdued)
                            .fixedSize(horizontal:false,vertical:true).lineLimit(3)
                    }
                }
            } else {
            switch family {
            case .accessoryInline:
                Text("Mapa del Tiempo · \(total)")
            case .accessoryCircular:
                VStack(spacing: 1) {
                    Image(systemName:"hourglass").font(.caption2)
                    Text(total).font(.system(size: 11, weight:.bold, design:.rounded))
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
            case .accessoryRectangular:
                VStack(alignment:.leading,spacing:1) {
                    Text("Tiempo registrado").font(.caption2)
                    Text(total).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    Text("Estancia · \(stay)").font(.caption2).lineLimit(1)
                }
            case .systemMedium:
                HStack(spacing: 12) {
                    VStack(alignment:.leading,spacing:5) {
                        Label("Tiempo total",systemImage:"hourglass")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(total).font(.system(.title2,design:.rounded,weight:.bold))
                            .lineLimit(2).minimumScaleFactor(0.65)
                        Text(status).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:2)
                    VStack(alignment:.leading,spacing:5) {
                        Label("Estancia",systemImage:"mappin.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                        Text(stay).font(.headline.monospacedDigit())
                            .lineLimit(2).minimumScaleFactor(0.7)
                        Text(place).font(.caption2).lineLimit(2)
                    }
                    .frame(maxWidth: 145,alignment:.leading)
                }
            default:
                VStack(alignment:.leading,spacing:6) {
                    Label("Mi Mapa PRUEBA",systemImage:"map.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    Spacer(minLength:0)
                    Text(total).font(.system(.title2,design:.rounded,weight:.bold))
                        .minimumScaleFactor(0.7).lineLimit(2)
                    Text("Total confirmado").font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Text("Estancia: \(stay)").font(.caption.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            }
        }
        .widgetURL(URL(string: "mimapadeltiempoprueba://mapa"))
        .containerBackground(for:.widget) {
            Color(red: 0.92, green: 0.96, blue: 0.95)
        }
        .accessibilityElement(children:.combine)
        .accessibilityLabel(entry.value == nil ?
            "Mi Mapa Prueba. Abrir mapa. El App Group no está autorizado para compartir los tiempos." :
            "Mi Mapa Prueba. Total \(total). Estancia actual \(stay). \(status)")
    }
}

struct MiMapaTiempoWidget: Widget {
    let kind = "MiMapaTiempoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind, provider:GPSWidgetProvider()) { entry in
            GPSWidgetFace(entry:entry)
        }
        .configurationDisplayName("Mi Mapa Prueba")
        .description("Acceso rápido al mapa. Los tiempos se muestran solo si iOS autoriza compartir datos.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryCircular, .accessoryRectangular
        ])
    }
}

/// Live Activity completa, independiente del App Group.
private struct MiMapaLivePanel:View {
    let state:TimeMapActivityAttributes.ContentState
    let isStale:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:state.resting ? "moon.zzz.fill":"location.fill")
                    .font(.title3).foregroundStyle(.teal).frame(width:26)
                VStack(alignment:.leading,spacing:3) {
                    Text(state.cellName)
                        .font(.subheadline.weight(.bold)).lineLimit(2)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    Text(state.cellNumber).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength:1)
                VStack(alignment:.trailing,spacing:3) {
                    Text("ESTANCIA").font(.system(size:9,weight:.semibold))
                        .foregroundStyle(.secondary)
                    liveClock.font(.system(.title3,design:.rounded,weight:.bold))
                        .monospacedDigit()
                        .frame(width:110,alignment:.trailing)
                }
            }
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:2) {
                    Text("Total cuadrícula").font(.caption2).foregroundStyle(.secondary)
                    Text(TimeWidgetDuration.compact(state.confirmedCellSeconds))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                if let zoneTotal=state.confirmedZoneSeconds {
                    VStack(alignment:.leading,spacing:2) {
                        Text("Total zona").font(.caption2).foregroundStyle(.secondary)
                        Text(TimeWidgetDuration.compact(zoneTotal))
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            Divider().opacity(0.5)
            HStack(spacing:5) {
                Image(systemName:state.resting ? "moon.zzz.fill" :
                      isStale ? "exclamationmark.triangle.fill" : "location.circle.fill")
                    .foregroundStyle(isStale ? .orange : .teal)
                Text(state.resting ? "GPS en pausa · tiempo asumido" :
                     isStale ? "Sin GPS reciente · contador limitado" :
                     "GPS verificado")
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength:0)
                if let last=state.lastGPSAt {
                    Text(last,style:.relative).lineLimit(1)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal,14).padding(.vertical,12)
    }
    private var liveClock:Text {
        if state.resting {
            return Text(state.stayStartedAt,style:.timer)
        }
        // pauseTime evita que el cronómetro atribuya horas sin GPS actualizado.
        return Text(timerInterval:state.stayStartedAt...state.timerValidUntil,
                    pauseTime:state.timerValidUntil,countsDown:false,showsHours:true)
    }
}

struct MiMapaRestLiveActivity:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:TimeMapActivityAttributes.self) { context in
            MiMapaLivePanel(state:context.state,isStale:context.isStale)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(context.state.cellName)
                            .font(.headline).lineLimit(2)
                        Text(context.state.cellNumber)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment:.trailing,spacing:2) {
                        Text("Estancia").font(.caption2)
                        if context.state.resting {
                            Text(context.state.stayStartedAt,style:.timer)
                        } else {
                            Text(timerInterval:context.state.stayStartedAt...context.state.timerValidUntil,
                                 pauseTime:context.state.timerValidUntil,countsDown:false,
                                 showsHours:true)
                        }
                    }
                    .monospacedDigit().font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(TimeWidgetDuration.compact(context.state.confirmedCellSeconds),
                              systemImage:"square")
                        Spacer()
                        if let zone=context.state.confirmedZoneSeconds {
                            Label(TimeWidgetDuration.compact(zone),systemImage:"square.3.layers.3d")
                        }
                    }
                    .font(.caption2)
                    Text(context.isStale ? "GPS sin actualizar" :
                         context.state.resting ? "GPS pausado" : "GPS activo")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName:context.isStale ? "exclamationmark.triangle" :
                      context.state.resting ? "moon.zzz.fill" : "location.fill")
            } compactTrailing: {
                if context.state.resting {
                    Text(context.state.stayStartedAt,style:.timer)
                        .monospacedDigit().frame(maxWidth:52)
                } else {
                    Text(timerInterval:context.state.stayStartedAt...context.state.timerValidUntil,
                         pauseTime:context.state.timerValidUntil,countsDown:false,showsHours:true)
                        .monospacedDigit().frame(maxWidth:52)
                }
            } minimal: {
                Image(systemName:context.isStale ? "exclamationmark.triangle" : "hourglass")
            }
            .widgetURL(URL(string:"mimapadeltiempoprueba://mapa"))
        }
    }
}

@main
struct MiMapaTiempoWidgetBundle: WidgetBundle {
    var body: some Widget {
        MiMapaTiempoWidget()
        MiMapaRestLiveActivity()
    }
}
