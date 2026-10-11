import SwiftUI

struct GPSDiaryShell: View {
    @ObservedObject var model: TimeModel

    private var fixes: [GPSHistoryFix] {
        model.data.fixes.map {
            GPSHistoryFix(date: $0.date, latitude: $0.latitude, longitude: $0.longitude)
        }.sorted { $0.date < $1.date }
    }

    private var days: [Date] {
        let cal = Calendar.current
        return Array(Set(fixes.map { cal.startOfDay(for: $0.date) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.self) { day in
                    NavigationLink {
                        GPSDayView(day: day, fixes: fixes)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day, format: .dateTime.weekday(.wide).day().month().year())
                            Text("Trayectos, estancias y reproducción")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Horas en la zona horaria del dispositivo; duración real en UTC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Diario GPS")
        }
    }
}
