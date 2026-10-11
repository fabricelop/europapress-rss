import SwiftUI

struct GPSDayView: View {
    let day: Date
    let fixes: [GPSHistoryFix]
    let intervals: [AssignedInterval]

    private var nextDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
    }
    private var episodes: [GPSHistoryEpisode] {
        GPSHistoryGrouping.episodes(fixes).filter { $0.end >= day && $0.start < nextDay }
    }
    private var assigned: TimeInterval {
        intervals.reduce(0) { result, segment in
            result + max(0, min(segment.end, nextDay).timeIntervalSince(max(segment.start, day)))
        }
    }
    var body: some View {
        List {
            Section("Resumen") {
                LabeledContent("Tiempo asignado", value: DurationFormat.full(assigned))
                LabeledContent("Episodios", value: String(episodes.count))
                Text("Las lagunas GPS no se rellenan automáticamente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Trayectos y estancias") {
                ForEach(episodes) { episode in
                    NavigationLink {
                        GPSReplayShell(episode: episode, intervals: intervals)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.kind.rawValue).font(.headline)
                            HStack {
                                Text(episode.start, style: .time)
                                Text("—")
                                Text(episode.end, style: .time)
                            }
                            Text(DurationFormat.full(episode.duration))
                                .font(.caption).foregroundStyle(.secondary)
                            if episode.start < day || episode.end >= nextDay {
                                Text("El episodio cruza medianoche")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(day.formatted(.dateTime.day().month().year()))
    }
}
