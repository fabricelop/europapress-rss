import SwiftUI
import WidgetKit

// Real WidgetKit widgets, independent of the Live Activity. Neither an App
// Group nor APNs is needed: the provider reads the existing public GitHub
// editorial snapshot and never makes an editorial write.
struct TTEditorialEntry: TimelineEntry {
    let date: Date
    let newsReady: Int
    let trendsReady: Int
    let newsWorking: Int
    let trendsWorking: Int
    let latestHeadline: String
    let confirmed: Bool

    static func sample(at date: Date = Date(), confirmed: Bool = false) -> Self {
        .init(date: date, newsReady: 0, trendsReady: 0,
              newsWorking: 0, trendsWorking: 0,
              latestHeadline: "", confirmed: confirmed)
    }
}

struct TTEditorialProvider: TimelineProvider {
    func placeholder(in context: Context) -> TTEditorialEntry {
        TTEditorialEntry(date: Date(), newsReady: 3, trendsReady: 2,
                         newsWorking: 1, trendsWorking: 0,
                         latestHeadline: "Última noticia lista para revisar",
                         confirmed: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TTEditorialEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            Task { completion(await load()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TTEditorialEntry>) -> Void) {
        Task {
            let entry = await load()
            // This is only a requested refresh time: iOS enforces its own
            // WidgetKit budget, so never claim real-time data here.
            completion(Timeline(entries: [entry],
                                policy: .after(Date().addingTimeInterval(20 * 60))))
        }
    }

    private func load() async -> TTEditorialEntry {
        let now = Date()
        do {
            let counts = try await LiveCountsSource.load()
            return TTEditorialEntry(
                date: now, newsReady: counts.news, trendsReady: counts.trends,
                newsWorking: counts.newsWorking, trendsWorking: counts.trendsWorking,
                latestHeadline: counts.latestHeadline, confirmed: true)
        } catch {
            // Do not show invented zeros as live data on a network failure.
            return .sample(at: now, confirmed: false)
        }
    }
}

struct TTActualidadHomeWidget: Widget {
    let kind = "TTActualidadEditorialHome"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TTEditorialProvider()) { entry in
            TTEditorialHomeView(entry: entry)
        }
        .configurationDisplayName("TTActualidad · Centro editorial")
        .description("Noticias y tendencias listas, elaboraciones y último titular.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct TTEditorialHomeView: View {
    let entry: TTEditorialEntry
    @Environment(\.widgetFamily) private var family
    private let mint = Color(red: 0.35, green: 0.89, blue: 0.81)
    private let ocean = Color(red: 0.46, green: 0.70, blue: 1)
    private let navy = Color(red: 0.065, green: 0.105, blue: 0.18)

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            case .accessoryRectangular: lockScreen
            default: small
            }
        }
        .containerBackground(for: .widget) { navy }
        .widgetURL(URL(string: "ttactualidad://listas"))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe.europe.africa.fill")
                .foregroundStyle(mint)
            Text("TTActualidad")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: entry.confirmed ? "checkmark.circle.fill" : "wifi.exclamationmark")
                .font(.caption2)
                .foregroundStyle(entry.confirmed ? mint : Color.orange)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if entry.confirmed {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(String(entry.newsReady))
                        .font(.system(size: 31, weight: .heavy, design: .rounded))
                        .foregroundStyle(mint)
                    Text("noticias listas")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(String(entry.trendsReady))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ocean)
                    Text("tendencias listas")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            } else {
                Text("Sin datos verificados")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Abre la app para comprobar GitHub")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(12)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if entry.confirmed {
                HStack(spacing: 9) {
                    metric(entry.newsReady, working: entry.newsWorking,
                           title: "Noticias", tint: mint)
                    metric(entry.trendsReady, working: entry.trendsWorking,
                           title: "Tendencias", tint: ocean)
                }
                if !entry.latestHeadline.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "newspaper").foregroundStyle(mint)
                        Text("Última lista")
                            .foregroundStyle(mint).fontWeight(.semibold)
                    }
                    .font(.system(size: 10))
                    Text(entry.latestHeadline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            } else {
                Label("GitHub no disponible · sin cifras confirmadas",
                      systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Text("Verificado " + entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(12)
    }

    private func metric(_ value: Int, working: Int, title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(String(value))
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(.white)
                Text(String(working) + " elaborando")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TTActualidad").font(.caption.weight(.bold))
            if entry.confirmed {
                Text("N " + String(entry.newsReady) + " · T " + String(entry.trendsReady))
                    .font(.headline.monospacedDigit())
                Text(String(entry.newsWorking + entry.trendsWorking) + " en elaboración")
                    .font(.caption2)
            } else {
                Text("Sin conexión con GitHub").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
