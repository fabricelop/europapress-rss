import SwiftUI

struct GPSDiaryShell: View {
    @ObservedObject var model: TimeModel

    @State private var indexedFixes: [GPSHistoryFix] = []
    @State private var days: [Date] = []
    @State private var indexing = false
    @State private var indexGeneration = UUID()

    /// Build the diary list once per GPS-fix change, not in every SwiftUI
    /// body evaluation or while an unrelated tab is being redrawn.
    private func rebuildIndex() {
        let id = UUID()
        indexGeneration = id
        if days.isEmpty { indexing = true }
        let points = model.data.fixes
        let calendar = Calendar.current
        DispatchQueue.global(qos:.utility).async {
            let sorted = points.map {
                GPSHistoryFix(date:$0.date,latitude:$0.latitude,longitude:$0.longitude)
            }.sorted { $0.date < $1.date }
            let dates = Array(Set(sorted.map {
                calendar.startOfDay(for:$0.date)
            })).sorted(by:>)
            DispatchQueue.main.async {
                guard indexGeneration == id else { return }
                indexedFixes = sorted
                days = dates
                indexing = false
            }
        }
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
                if indexing && days.isEmpty {
                    ProgressView("Preparando diario GPS…")
                }
                ForEach(days, id: \.self) { day in
                    NavigationLink {
                        GPSDayView(day: day, fixes: indexedFixes, intervals: model.data.intervals, model: model)
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
            .onAppear { if days.isEmpty { rebuildIndex() } }
            .onChange(of:model.data.fixes.count) { _,_ in rebuildIndex() }
        }
    }
}
