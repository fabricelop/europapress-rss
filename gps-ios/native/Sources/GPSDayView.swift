import SwiftUI

struct GPSDayView: View {
    let day: Date
    let fixes: [GPSHistoryFix]
    let intervals: [AssignedInterval]
    @ObservedObject var model: TimeModel

    private var nextDay: Date {
        Calendar.current.date(byAdding:.day,value:1,to:day) ?? day.addingTimeInterval(86400)
    }
    private var episodes:[GPSHistoryEpisode] {
        GPSHistoryGrouping.episodes(fixes,manualBreaks:model.data.manualBreaks)
            .filter { $0.end>day && $0.start<nextDay && valid($0) }
    }
    private func valid(_ ep:GPSHistoryEpisode) -> Bool {
        guard ep.points.count>=2,ep.duration>0 else { return false }
        if ep.kind == .stay { return ep.duration>=5*60 }
        let distance=zip(ep.points,ep.points.dropFirst())
            .reduce(0.0) { $0+GPSHistoryGrouping.distance($1.0,$1.1) }
        return ep.duration>=30 && distance>=65
    }
    private var assigned:TimeInterval {
        let rows=TimeAttribution.byCell(intervals,window:DateInterval(start:day,end:nextDay))
        return rows.values.reduce(0,+)
    }
    private func label(_ point: GPSHistoryFix?) -> String {
        guard let point else { return "ubicación desconocida" }
        let cell=Grid.cell(latitude:point.latitude,longitude:point.longitude)
        return model.placeFor(cell)?.name ?? model.label(for:cell)
    }
    private func title(_ episode:GPSHistoryEpisode) -> String {
        if episode.kind == .stay { return "Estancia en "+label(episode.points.first) }
        return label(episode.points.first)+" → "+label(episode.points.last)
    }
    var body: some View {
        List {
            Section("Resumen del día") {
                LabeledContent("Tiempo atribuido",value:DurationFormat.full(assigned))
                LabeledContent("Estancias y trayectos reconocibles",value:String(episodes.count))
                Text("Las lagunas GPS se mantienen sin atribuir. Las paradas y trayectos se reconocen de manera aproximada, a partir de las muestras disponibles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cronología") {
                if episodes.isEmpty {
                    Text("No hay estancias o desplazamientos suficientemente largos para clasificar con confianza.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(episodes) { episode in
                    NavigationLink {
                        GPSReplayShell(episode:episode,intervals:intervals)
                    } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Label(episode.kind.rawValue,
                                  systemImage: episode.kind == .stay ? "mappin.circle" : "figure.walk")
                                .font(.subheadline.weight(.semibold))
                            Text(title(episode)).font(.subheadline).lineLimit(2)
                            HStack {
                                Text(episode.start,style:.time)
                                Text("—")
                                Text(episode.end,style:.time)
                                Spacer()
                                Text(DurationFormat.full(
                                    max(0,min(episode.end,nextDay).timeIntervalSince(max(episode.start,day)))))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                            }.font(.caption).foregroundStyle(.secondary)
                            if episode.start<day || episode.end>nextDay {
                                Text("Continúa al otro lado de medianoche")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical,3)
                    }
                    .swipeActions(edge:.trailing) {
                        if episode.points.count>2 {
                            Button {
                                let index=episode.points.count/2
                                model.splitEpisode(at:episode.points[index].date)
                            } label: {
                                Label("Dividir episodio",systemImage:"scissors")
                            }.tint(.teal)
                        }
                    }
                }
            }
            Section("Edición") {
                Text("Puedes dividir manualmente un episodio deslizando su tarjeta. No altera los segundos ni los GPS originales.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.data.manualBreaks.filter{$0>=day && $0<nextDay},id:\.self) { timestamp in
                    HStack {
                        Text("División: "+timestamp.formatted(date:.omitted,time:.shortened))
                        Spacer()
                        Button("Unir") { model.removeSplit(at:timestamp) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle(day.formatted(.dateTime.day().month().year().locale(Locale(identifier:"es_ES"))))
    }
}
