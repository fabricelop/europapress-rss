import SwiftUI

/// Las cuatro celdas son siempre independientes y no se agrupan con el zoom.
/// Muestra la población al cierre del día elegido; en el día actual el último
/// cálculo confirmado por GPS. Tocar una vecina abre su ficha con la misma fecha.
struct BioGridNeighborsView: View {
    let cell:Cell
    let date:Date
    let snapshot:BioGridSnapshot?
    let colors:[Color]
    let onSelect:(Cell)->Void

    private var source:[Int64] { counts(cell) }
    private var family:Int? {
        guard let maximum = source.max(), maximum > 0 else { return nil }
        if let saved = snapshot?.rulers[cell.id],
           source.indices.contains(saved),
           source[saved] == maximum { return saved }
        return source.firstIndex(of:maximum)
    }
    private var canEmigrate:Bool {
        BioGridEngine.defensiveMigrationLimit(source) != nil
    }
    private var validTargets:[Int] {
        guard let family,canEmigrate else { return [] }
        var cells:[String:[Int64]] = [cell.id:source]
        for direction in 0..<4 {
            let neighbor = BioGridEngine.neighbor(cell,direction:direction)
            cells[neighbor.id] = counts(neighbor)
        }
        return BioGridEngine.migrationTargets(cell:cell,family:family,
            populations:cells,rulers:date == snapshot?.latestProcessed ?
                (snapshot?.rulers ?? [:]) : [:])
    }

    private func counts(_ target:Cell)->[Int64] {
        snapshot?.cellHistory[target.id]?
            .last(where:{$0.date <= date})?.counts ??
            Array(repeating:0,count:7)
    }

    private func winner(_ target:Cell)->Int? {
        let values = counts(target)
        guard let maxCount = values.max(), maxCount > 0 else { return nil }
        return values.firstIndex(of:maxCount)
    }

    private func tile(_ direction:Int) -> some View {
        let target=BioGridEngine.neighbor(cell,direction:direction)
        let values=counts(target)
        let total=values.reduce(0,+)
        let leader=winner(target)
        let compass=["NORTE","SUR","ESTE","OESTE"]
        let selected=validTargets.contains(direction)
        let reinforcement=leader == family && total > 0
        return Button {
            onSelect(target)
        } label: {
            VStack(spacing:4) {
                Text(compass[direction])
                    .font(.system(size:10,weight:.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing:4) {
                    if let leader {
                        Text(BioGridEngine.letters[leader])
                            .font(.subheadline.bold())
                            .foregroundStyle(colors[leader])
                    } else {
                        Text("Vacía")
                            .font(.caption.weight(.semibold))
                    }
                    Text(total.formatted())
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(selected ? (reinforcement ? "Refuerzo" : "Expansión") : "Ver detalle")
                    .font(.system(size:10))
                    .foregroundStyle(selected ? Color.green : Color.secondary)
                Image(systemName:"chevron.right")
                    .font(.system(size:10,weight:.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth:.infinity)
            .frame(height:87)
            .background(selected ? Color.green.opacity(0.10) :
                Color(.secondarySystemGroupedBackground),
                in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9)
                .strokeBorder(selected ? Color.green.opacity(0.40) :
                    Color.clear,lineWidth:1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(compass[direction]): \(total) bacterias, abrir cuadrícula")
    }

    private var centerTile:some View {
        let total=source.reduce(0,+)
        return VStack(spacing:4) {
            Text("ACTUAL")
                .font(.system(size:10,weight:.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing:5) {
                if let family {
                    Text(BioGridEngine.letters[family])
                        .bold().foregroundStyle(colors[family])
                } else {
                    Text("—")
                }
                Text(total.formatted())
                    .font(.subheadline.bold().monospacedDigit())
                    .minimumScaleFactor(0.7)
            }
            Text(canEmigrate ? "Puede expandirse" : "En defensa")
                .font(.system(size:10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth:.infinity)
        .frame(height:87)
        .background(Color.blue.opacity(0.12),
                    in:RoundedRectangle(cornerRadius:9))
    }

    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Alrededor de esta cuadrícula",
                  systemImage:"square.grid.3x3")
                .font(.headline)
            Text("Población y familia dominante de las cuatro vecinas al terminar el día elegido. Toca una para explorarla.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
            HStack {
                Spacer(minLength:0)
                tile(0).frame(maxWidth:125)
                Spacer(minLength:0)
            }
            HStack(spacing:7) {
                tile(3)
                centerTile
                tile(2)
            }
            HStack {
                Spacer(minLength:0)
                tile(1).frame(maxWidth:125)
                Spacer(minLength:0)
            }
            if canEmigrate {
                Text(validTargets.isEmpty ?
                    "La familia dominante tiene reserva suficiente, pero ninguna vecina necesita refuerzo ni es un objetivo de conquista." :
                    "En verde: destinos preferentes de la próxima emigración, si se mantiene el doble de bacterias que la segunda familia (máximo 20 % emigrante).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:12))
    }
}