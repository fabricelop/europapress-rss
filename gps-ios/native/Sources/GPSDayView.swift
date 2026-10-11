import SwiftUI

struct GPSDayView: View {
    let day: Date
    let fixes: [GPSHistoryFix]
    let intervals: [AssignedInterval]
    @ObservedObject var model: TimeModel

    private var nextDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
    }
    private var episodes: [GPSHistoryEpisode] {
        GPSHistoryGrouping.episodes(fixes,manualBreaks:model.data.manualBreaks).filter { $0.end >= day && $0.start < nextDay }
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
                            Text(DurationFormat.full(max(0, min(episode.end, nextDay).timeIntervalSince(max(episode.start, day)))))
                                .font(.caption).foregroundStyle(.secondary)
                            if episode.start < day || episode.end >= nextDay {
                                Text("El episodio cruza medianoche")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    .swipeActions(edge:.trailing) {
                        if episode.points.count > 2 {
                            Button {
                                let index = episode.points.count / 2
                                model.splitEpisode(at:episode.points[index].date)
                            } label: {
                                Label("Dividir episodio",systemImage:"scissors")
                            }.tint(.teal)
                        }
                    }
                }
            }
            Section("Edición del diario") {
                Text("Desliza un episodio para dividirlo en dos por el punto GPS central. Los tiempos de las cuadrículas no cambian.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.data.manualBreaks.filter({ $0 >= day && $0 < nextDay }),id:\.self) { timestamp in
                    HStack {
                        Text("División: \(timestamp.formatted(date:.omitted,time:.shortened))")
                        Spacer()
                        Button("Unir de nuevo") { model.removeSplit(at:timestamp) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle(day.formatted(.dateTime.day().month().year().locale(Locale(identifier:"es_ES"))))
    }
}
