import SwiftUI
import WidgetKit

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

    private var hasData: Bool { entry.value != nil }
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
                    Text("Mi Mapa del Tiempo · Abrir")
                case .accessoryCircular:
                    Image(systemName:"map.fill").font(.title3)
                case .accessoryRectangular:
                    VStack(alignment:.leading,spacing:2) {
                        Text("Mi Mapa del Tiempo").font(.headline)
                        Text("Toca para abrir el mapa").font(.caption2)
                    }
                default:
                    VStack(alignment:.leading,spacing:8) {
                        Label("Mi Mapa del Tiempo",systemImage:"map.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                        Spacer(minLength:2)
                        Image(systemName:"map.circle.fill")
                            .font(.system(size:38)).foregroundStyle(.teal)
                        Text("Abrir mi mapa").font(.headline)
                        Text("Widget de acceso sin datos compartidos")
                            .font(.caption2).foregroundStyle(.secondary)
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
                    Label("Mi Mapa del Tiempo",systemImage:"map.fill")
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
        .widgetURL(URL(string: "mimapadeltiempo://mapa"))
        .containerBackground(for:.widget) {
            Color(red: 0.92, green: 0.96, blue: 0.95)
        }
        .accessibilityElement(children:.combine)
        .accessibilityLabel("Mi Mapa del Tiempo. Total \(total). Estancia actual \(stay). \(status)")
    }
}

struct MiMapaTiempoWidget: Widget {
    let kind = "MiMapaTiempoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind, provider:GPSWidgetProvider()) { entry in
            GPSWidgetFace(entry:entry)
        }
        .configurationDisplayName("Mi Mapa del Tiempo")
        .description("Acceso rápido al mapa. Los tiempos se muestran solo si iOS autoriza compartir datos.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryCircular, .accessoryRectangular
        ])
    }
}

@main
struct MiMapaTiempoWidgetBundle: WidgetBundle {
    var body: some Widget {
        MiMapaTiempoWidget()
    }
}
