import SwiftUI

/// Pantalla de corrección opcional, con UNA acción por recuperación.
/// Las elecciones y su confirmación se muestran solo cuando se necesitan.
struct TimeRecoveredEditor:View {
    @ObservedObject var model:TimeModel
    @State private var active:TimeRecoveryGroup?
    @State private var target:Cell?
    @State private var showActions=false
    @State private var showCells=false
    @State private var confirmUndo=false
    @State private var confirmMove=false
    @State private var message=""

    private var groups:[TimeRecoveryGroup] {
        TimeRecoveryIndex.groups(model.data.intervals)
    }
    private func choices(_ group:TimeRecoveryGroup)->[Cell] {
        let other=TimeRecoveryIndex.without(model.data.intervals,group:group)
            .sorted {$0.start<$1.start}
        let candidates=[other.last(where:{$0.end<=group.start})?.cell,
                        other.first(where:{$0.start>=group.end})?.cell]+
                        group.cells.map(Optional.some)
        var seen:Set<String>=[]
        return candidates.compactMap {
            guard let cell=$0,seen.insert(cell.id).inserted else { return nil }
            return cell
        }
    }
    var body:some View {
        List {
            if !message.isEmpty {
                Section { Text(message).font(.caption).foregroundStyle(.teal) }
            }
            if groups.isEmpty {
                ContentUnavailableView("No hay tiempos por corregir",
                    systemImage:"checkmark.circle",
                    description:Text("Las recuperaciones que confirmes aparecerán aquí."))
            } else {
                Section {
                    ForEach(groups) { group in
                        HStack(spacing:10) {
                            VStack(alignment:.leading,spacing:3) {
                                Text(group.start.formatted(.dateTime.day().month().year()))
                                    .font(.subheadline.weight(.medium))
                                Text("\(group.start.formatted(.dateTime.hour().minute())) – \(group.end.formatted(.dateTime.hour().minute())) · \(DurationFormat.small(group.seconds))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(group.cells.prefix(2).map{model.label(for:$0)}
                                    .joined(separator:" · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength:3)
                            Button("Corregir") {
                                active=group
                                showActions=true
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical,3)
                    }
                } header: {
                    Text("Tiempo añadido manualmente")
                } footer: {
                    Text("Solo se modifica el tiempo estimado. Las posiciones GPS permanecen intactas.")
                }
            }
        }
        .navigationTitle("Corregir tiempo")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Corregir recuperación",isPresented:$showActions,
            titleVisibility:.visible) {
            Button("Cambiar cuadrícula") { showCells=true }
            Button("Deshacer tiempo añadido",role:.destructive) {
                confirmUndo=true
            }
            Button("Cancelar",role:.cancel) { active=nil }
        }
        .confirmationDialog("Elegir cuadrícula",isPresented:$showCells,
            titleVisibility:.visible) {
            if let active {
                ForEach(choices(active),id:\.id) { cell in
                    Button(model.label(for:cell)) {
                        target=cell
                        confirmMove=true
                    }
                }
            }
            Button("Cancelar",role:.cancel) {
                active=nil
            }
        }
        .alert("¿Deshacer este tiempo?",isPresented:$confirmUndo) {
            Button("Deshacer",role:.destructive) {
                if let active {
                    message=model.reviseRecoveredTime(active,newCell:nil) ?
                        "Recuperación deshecha." : "No se pudo guardar el cambio."
                }
                active=nil
            }
            Button("Cancelar",role:.cancel) { active=nil }
        } message: {
            Text("Solo se quitará el tiempo que añadiste manualmente. No se borrará ninguna posición GPS.")
        }
        .alert("¿Cambiar la cuadrícula?",isPresented:$confirmMove) {
            Button("Guardar") {
                if let active,let target {
                    message=model.reviseRecoveredTime(active,newCell:target) ?
                        "Cuadrícula corregida." : "No se pudo guardar el cambio."
                }
                active=nil
                target=nil
            }
            Button("Cancelar",role:.cancel) {
                active=nil
                target=nil
            }
        } message: {
            if let active,let target {
                Text("Se asignará \(DurationFormat.small(active.seconds)) a \(model.label(for:target)).")
            }
        }
    }
}
