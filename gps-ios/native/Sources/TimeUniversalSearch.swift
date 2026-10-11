import SwiftUI

private struct TimeSearchHit: Identifiable {
    let id:String
    let title:String
    let subtitle:String
    let cell:Cell
    let symbol:String
}

struct TimeUniversalSearch: View {
    @ObservedObject var model:TimeModel
    let onSelect:(Cell)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var query=""
    private var hits:[TimeSearchHit] {
        let needle=NamedPlaces.normalize(query)
        guard !needle.isEmpty else { return [] }
        var results:[TimeSearchHit]=[]
        for place in model.data.places {
            guard NamedPlaces.normalize(place.name).contains(needle),
                  let first=place.cellIDs.compactMap(TimeAnalytics.cell).first else { continue }
            results.append(TimeSearchHit(id:"p"+place.id.uuidString,title:place.name,
               subtitle:"Zona · \(place.cellIDs.count) cuadrícula(s)",
               cell:first,symbol:"mappin.and.ellipse"))
        }
        for cell in model.allCells {
            if NamedPlaces.normalize(model.label(for:cell)).contains(needle) ||
                cell.id.contains(needle) {
                results.append(TimeSearchHit(id:"c"+cell.id,title:model.label(for:cell),
                   subtitle:"Cuadrícula · \(DurationFormat.small(model.confirmedTotals()[cell.id] ?? 0))",
                   cell:cell,symbol:"square"))
            }
        }
        var territories=Set<String>()
        for (id,path) in model.data.territoryCache {
            guard let cell=TimeAnalytics.cell(id) else { continue }
            for (level,name) in path.hierarchy
            where NamedPlaces.normalize(name).contains(needle) {
                let key=level+"|"+name
                if territories.insert(key).inserted {
                    results.append(TimeSearchHit(id:"t"+key,title:name,
                       subtitle:level+" · cuadrícula clasificada",
                       cell:cell,symbol:"globe.europe.africa"))
                }
            }
        }
        return Array(results.prefix(150))
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Busca en tu mapa",systemImage:"magnifyingglass",
                      description:Text("Zonas como Montevalle, códigos Zona 001, coordenadas de cuadrícula o territorios ya clasificados."))
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text:query)
                }
                ForEach(hits) { hit in
                    Button {
                        onSelect(hit.cell)
                        dismiss()
                    } label: {
                        HStack(spacing:12) {
                            Image(systemName:hit.symbol).foregroundStyle(.teal)
                                .frame(width:24)
                            VStack(alignment:.leading,spacing:4) {
                                Text(hit.title).font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(hit.subtitle).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName:"arrow.up.left").foregroundStyle(.secondary)
                        }.padding(.vertical,3)
                    }
                }
                if hits.count>=150 {
                    Text("Mostrando los primeros 150 resultados. Especifica más la búsqueda.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text:$query,prompt:"Zona, cuadrícula, país, ciudad…")
            .navigationTitle("Buscar")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
