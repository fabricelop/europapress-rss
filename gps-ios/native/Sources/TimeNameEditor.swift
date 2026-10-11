import SwiftUI

/// Poner el mismo nombre es la única forma de agrupar cuadrículas.
/// Las lejanas requieren una elección explícita; nunca se fusionan solas.
struct TimeNameEditor: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmingDistant = false
    @State private var distantGroupID: UUID?
    @State private var distantGroupName = ""
    @State private var distantMeters: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre de la cuadrícula") {
                    TextField("Casa, Montevalle, Trabajo…",text:$name)
                        .textInputAutocapitalization(.words)
                    Text("Las cuadrículas con el mismo nombre pueden formar una zona. También puedes dibujarla en Estadísticas.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Zona actual") {
                    LabeledContent("Cuadrícula",value:model.label(for:cell))
                    if let place=model.placeFor(cell) {
                        LabeledContent("Zona",value:place.name)
                        LabeledContent("Cuadrículas agrupadas",value:String(place.cellIDs.count))
                    }
                    Text("Dejar vacío el nombre devuelve esta cuadrícula a su Zona y la separa de la zona.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.renameUndoAvailable {
                    Section {
                        Button("Deshacer último cambio de nombre") {
                            _ = model.undoLastRename()
                            dismiss()
                        }.foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Nombrar zona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Guardar") { saveOrAsk() }
                }
            }
            .confirmationDialog(
                "Ya existe una zona lejana con este nombre",
                isPresented:$confirmingDistant,
                titleVisibility:.visible
            ) {
                Button("Unir a la zona existente") {
                    model.assignName(cell,to:name,groupID:distantGroupID)
                    dismiss()
                }
                Button("Crear otra zona independiente") {
                    model.assignName(cell,to:name,groupID:nil)
                    dismiss()
                }
                Button("Cancelar",role:.cancel) {}
            } message: {
                Text("\(distantGroupName) está a unos \(Int(distantMeters)) m. ¿Es la misma zona?")
            }
        }
        .onAppear { name=model.data.names[cell.id] ?? "" }
    }

    private func saveOrAsk() {
        switch model.proposalForRename(cell,to:name) {
        case .assign(let groupID):
            model.assignName(cell,to:name,groupID:groupID)
            dismiss()
        case .distant(let groupID,let name,let meters):
            distantGroupID=groupID
            distantGroupName=name
            distantMeters=meters
            confirmingDistant=true
        }
    }
}
