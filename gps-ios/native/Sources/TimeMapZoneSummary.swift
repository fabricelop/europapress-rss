import SwiftUI

/// Ficha compacta de una zona tocada en el mapa. No crea ni modifica datos.
struct TimeMapZoneSummary:View {
    @ObservedObject var model:TimeModel
    let zone:TimeCustomZone
    var onSelectCell:(Cell)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCells=false

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    HStack {
                        Label(zone.name,systemImage:"square.3.layers.3d")
                            .font(.title3.bold()).foregroundStyle(.teal)
                        Spacer(minLength:5)
                        Text("\(zone.cellIDs.count) cuadrículas")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        let now=context.date
                        VStack(alignment:.leading,spacing:8) {
                            LabeledContent("Tiempo total de zona",
                                value:DurationFormat.full(model.total(for:zone,now:now)))
                            if model.activeCell.map({zone.cellIDs.contains($0.id)}) == true {
                                LabeledContent("Estancia actual en zona",
                                    value:DurationFormat.full(model.zoneStaySeconds(for:zone,now:now)))
                            }
                        }.font(.subheadline.monospacedDigit())
                    }
                    Button {
                        withAnimation(.easeOut(duration:0.2)) { showCells.toggle() }
                    } label: {
                        Label(showCells ? "Ocultar cuadrículas" : "Ver cuadrículas y tiempos",
                              systemImage:showCells ? "chevron.up" : "square.grid.3x3")
                    }.buttonStyle(.borderedProminent)
                    if showCells {
                        let totals=model.periodTotals()
                        ForEach(zone.cellIDs.prefix(150),id:\.self) { id in
                            if let cell=TimeAnalytics.cell(id) {
                                Button {
                                    onSelectCell(cell)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text("Cuadrícula \(model.data.shortIDs[id].map(String.init) ?? id)")
                                            .lineLimit(1)
                                        Spacer()
                                        Text(DurationFormat.full(totals[id] ?? 0))
                                            .monospacedDigit().foregroundStyle(.teal)
                                    }.font(.caption)
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                        if zone.cellIDs.count>150 {
                            Text("Se muestran las primeras 150 cuadrículas para mantener la fluidez.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(16)
            }
            .navigationTitle("Zona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(285),.medium,.large])
    }
}
