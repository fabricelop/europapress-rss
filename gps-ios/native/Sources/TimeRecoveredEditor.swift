import SwiftUI

/// Edición destructiva solo de minutos recuperados manualmente. Recalcula
/// los totales desde intervalos y no toca ni una muestra GPS observada.
struct TimeRecoveredEditor:View {
    @ObservedObject var model:TimeModel
    @State private var selected:TimeRecoveryGroup?
    @State private var destination:Cell?
    @State private var undoConfirmation=false
    @State private var moveConfirmation=false
    @State private var feedback=""

    private var groups:[TimeRecoveryGroup] {
        TimeRecoveryIndex.groups(model.data.intervals)
    }
    private func neighboring(_ group:TimeRecoveryGroup)->[Cell] {
        let original=TimeRecoveryIndex.without(model.data.intervals,group:group)
            .sorted {$0.start<$1.start}
        let before=original.last(where: {$0.end<=group.start})?.cell
        let after=original.first(where: {$0.start>=group.end})?.cell
        var seen:Set<String>=[]
        return ([before,after]+group.cells.map(Optional.some)).compactMap { cell in
            guard let cell,seen.insert(cell.id).inserted else { return nil }
            return cell
        }
    }
    var body:some View {
        List {
            Section {
                Text("Aquí aparecen las recuperaciones confirmadas anteriormente, incluyendo los recorridos estimados. Puedes deshacerlas o cambiar su asignación. Las muestras GPS reales permanecen intactas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !feedback.isEmpty {
                Section { Text(feedback).font(.caption).foregroundStyle(.teal) }
            }
            if groups.isEmpty {
                ContentUnavailableView("Sin recuperaciones editables",
                   systemImage:"checkmark.shield",
                   description:Text("No hay tiempo manual recuperado que corregir."))
            } else {
                Section("Tiempo recuperado") {
                    ForEach(groups) { group in
                        VStack(alignment:.leading,spacing:8) {
                            Text(group.start.formatted(.dateTime.day().month().year()))
                                .font(.headline)
                            Text("\(group.start.formatted(.dateTime.hour().minute())) – \(group.end.formatted(.dateTime.hour().minute()))")
                                .font(.subheadline)
                            Text("\(DurationFormat.full(group.seconds)) · \(group.cells.count) cuadrícula(s)")
                                .foregroundStyle(.orange).font(.subheadline)
                            Text(group.cells.prefix(3).map { model.label(for:$0) }
                                .joined(separator:" · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Menu {
                                ForEach(neighboring(group),id:\.id) { cell in
                                    Button(model.label(for:cell)) {
                                        selected=group
                                        destination=cell
                                        moveConfirmation=true
                                    }
                                }
                            } label: {
                                Label("Corregir cuadrícula",systemImage:"pencil.and.outline")
                            }
                            .buttonStyle(.bordered)
                            Button("Deshacer esta recuperación",role:.destructive) {
                                selected=group
                                undoConfirmation=true
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical,5)
                    }
                }
            }
        }
        .navigationTitle("Corregir recuperaciones")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Deshacer esta recuperación?",
            isPresented:$undoConfirmation,titleVisibility:.visible) {
            Button("Quitar tiempo estimado",role:.destructive) {
                if let selected {
                    feedback=model.reviseRecoveredTime(selected,newCell:nil) ?
                        "Tiempo estimado retirado. Los datos GPS se conservan." :
                        "No se pudo guardar la corrección."
                }
                selected=nil
            }
            Button("Cancelar",role:.cancel) { selected=nil }
        } message: {
            Text("Se quitarán solo los segundos de esta recuperación y se actualizarán los totales. No se borrarán posiciones GPS.")
        }
        .confirmationDialog("¿Reasignar esta recuperación?",
            isPresented:$moveConfirmation,titleVisibility:.visible) {
            Button("Guardar cuadrícula corregida") {
                if let selected,let destination {
                    feedback=model.reviseRecoveredTime(selected,newCell:destination) ?
                        "Recuperación reasignada; totales actualizados." :
                        "No se pudo guardar la corrección."
                }
                selected=nil
                destination=nil
            }
            Button("Cancelar",role:.cancel) {
                selected=nil
                destination=nil
            }
        } message: {
            if let selected,let destination {
                Text("Asignar \(DurationFormat.full(selected.seconds)) a \(model.label(for:destination)). Si había varias cuadrículas estimadas, se concentrarán en esta única cuadrícula.")
            }
        }
    }
}
