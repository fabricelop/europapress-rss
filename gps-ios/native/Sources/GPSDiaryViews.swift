import SwiftUI

struct GPSDiaryShell: View {
    @ObservedObject var model: TimeModel

    private var fixes: [GPSHistoryFix] {
        model.data.fixes.map {
            GPSHistoryFix(date: $0.date, latitude: $0.latitude, longitude: $0.longitude)
        }.sorted { $0.date < $1.date }
    }

    private var days: [Date] {
        let calendar = Calendar.current
        return Array(Set(fixes.map { calendar.startOfDay(for: $0.date) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Revisar") {
                    NavigationLink {
                        GPSGapReviewView(model:model)
                    } label: {
                        Label("Huecos GPS",systemImage:"location.slash.circle")
                    }
                    NavigationLink {
                        TimeRecoveredEditor(model:model)
                    } label: {
                        Label("Corregir tiempo añadido",systemImage:"arrow.uturn.backward")
                    }
                }
                ForEach(days, id: \.self) { day in
                    NavigationLink {
                        GPSDayView(day: day, fixes: fixes, intervals: model.data.intervals, model: model)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day.formatted(.dateTime.weekday(.wide).day().month().year().locale(Locale(identifier:"es_ES"))))
                            Text("Trayectos, estancias y reproducción")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Diario en español. Las fechas usan por ahora la hora local del iPhone; la hora histórica de cada lugar se añadirá después.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Diario GPS")
        }
    }
}
