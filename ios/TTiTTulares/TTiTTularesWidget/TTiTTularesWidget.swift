import SwiftUI
import WidgetKit

struct DashboardCounts: Codable, Equatable {
    let listas: Int
    let elaboracion: Int
    let creciendo: Int
    let tendencias: Int

    static let empty = DashboardCounts(listas: 0, elaboracion: 0, creciendo: 0, tendencias: 0)
}

private struct DashboardResponse: Decodable {
    let ok: Bool
    let updatedAt: String?
    let refreshAfterSeconds: Int?
    let counts: DashboardCounts

    enum CodingKeys: String, CodingKey {
        case ok
        case updatedAt = "updated_at"
        case refreshAfterSeconds = "refresh_after_seconds"
        case counts
    }
}

struct DashboardEntry: TimelineEntry {
    let date: Date
    let counts: DashboardCounts
    let available: Bool
}

struct DashboardProvider: TimelineProvider {
    func placeholder(in context: Context) -> DashboardEntry {
        DashboardEntry(
            date: Date(),
            counts: DashboardCounts(listas: 4, elaboracion: 2, creciendo: 3, tendencias: 1),
            available: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DashboardEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        load { entry, _ in completion(entry) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DashboardEntry>) -> Void) {
        load { entry, refreshSeconds in
            let seconds = TimeInterval(max(900, refreshSeconds))
            let next = Date().addingTimeInterval(seconds)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load(completion: @escaping (DashboardEntry, Int) -> Void) {
        let url = URL(string: "https://europapress-rss.vercel.app/api/ttittulares-widget")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data,
                let payload = try? JSONDecoder().decode(DashboardResponse.self, from: data),
                payload.ok
            else {
                completion(DashboardEntry(date: Date(), counts: .empty, available: false), 900)
                return
            }

            completion(
                DashboardEntry(date: Date(), counts: payload.counts, available: true),
                payload.refreshAfterSeconds ?? 900
            )
        }.resume()
    }
}

struct MetricTile: View {
    let title: String
    let count: Int
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(count))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(10)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DashboardWidgetView: View {
    let entry: DashboardEntry

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("TTiTTulares")
                    .font(.headline)
                Spacer()
                if entry.available {
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sin conexión")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                MetricTile(title: "Listas", count: entry.counts.listas, destination: URL(string: "ttittulares://listas")!)
                MetricTile(title: "En elaboración", count: entry.counts.elaboracion, destination: URL(string: "ttittulares://elaboracion")!)
                MetricTile(title: "Creciendo", count: entry.counts.creciendo, destination: URL(string: "ttittulares://creciendo")!)
                MetricTile(title: "Tendencias", count: entry.counts.tendencias, destination: URL(string: "ttittulares://tendencias")!)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct TTiTTularesDashboardWidget: Widget {
    let kind = "TTiTTularesDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DashboardProvider()) { entry in
            DashboardWidgetView(entry: entry)
        }
        .configurationDisplayName("Estado de TTiTTulares")
        .description("Listas, En elaboración, Creciendo y Tendencias de un vistazo.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
