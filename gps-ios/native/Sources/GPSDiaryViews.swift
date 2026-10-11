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
                ForEach(days, id: \.self) { day in
                    NavigationLink {
                        GPSDayView(day: day, fixes: fixes, intervals: model.data.intervals)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day, format: .dateTime.weekday(.wide).day().month().year())
                            Text("Trayectos, estancias y reproducción")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Horas según el dispositivo; la zona horaria de cada lugar sigue pendiente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Diario GPS")
        }
    }
}
