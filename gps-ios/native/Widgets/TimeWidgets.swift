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

/// Alternativa nativa para la pantalla bloqueada: temporizador de iOS,
/// sin App Group ni actualizaciones GPS cada segundo.
struct MiMapaRestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimeMapActivityAttributes.self) { context in
            VStack(alignment:.leading,spacing:7) {
                HStack(alignment:.top,spacing:9) {
                    Image(systemName:context.state.resting ? "moon.zzz.fill" : "location.fill")
                        .font(.headline).foregroundStyle(.teal)
                        .frame(width:22)
                    Text(context.state.cellName)
                        .font(.system(.subheadline,design:.rounded,weight:.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(context.state.resting ? "GPS en pausa · tiempo asumido" :
                         "GPS activo · estancia")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength:0)
                    Text(context.state.stayStartedAt,style:.timer)
                        .font(.system(.subheadline,design:.rounded,weight:.semibold))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal,14).padding(.vertical,12)
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing:4) {
                        Text(context.state.cellName)
                            .font(.headline).lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.85)
                        Text(context.state.resting ? "GPS pausado · sumando tiempo" : "Estancia actual")
                            .font(.caption2)
                        Text(context.state.stayStartedAt,style:.timer)
                            .font(.title3.monospacedDigit())
                    }
                }
            } compactLeading: {
                Image(systemName:context.state.resting ? "moon.zzz.fill" : "hourglass")
            } compactTrailing: {
                Text(context.state.stayStartedAt,style:.timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth:52)
            } minimal: {
                Image(systemName:"hourglass")
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
