import SwiftUI
import Foundation

/// Solo presentación: nunca modifica el historial GPS ni los datos guardados.
enum TimeMapCardSize:Equatable {
    case minimized, compact, expanded
}

enum TimeMapCardClock {
    static func display(_ seconds:TimeInterval)->String {
        guard seconds.isFinite else { return "—" }
        let total=Int(max(0,seconds).rounded(.down))
        return String(format:"%02d:%02d:%02d",total/3600,(total/60)%60,total%60)
    }
}

/// Reloj independiente para que el segundo cambiante no fuerce a repintar el mapa.
struct TimeMapMiniClock:View {
    @ObservedObject var model:TimeModel
    let picked:Cell?
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            if let picked {
                let zone=model.primaryZone(for:picked)
                Text(TimeMapCardClock.display(zone.map {
                    model.total(for:$0,now:context.date)
                } ?? model.total(for:picked,now:context.date)))
                .font(.system(size:12,weight:.semibold,design:.rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
    }
}

struct TimeMapCardContents:View {
    @ObservedObject var model:TimeModel
    let picked:Cell?
    let mode:TimeMapCardSize
    @State private var showEstimationHelp=false

    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let now=context.date
            let zone=picked.flatMap { model.primaryZone(for:$0) }
            let here=picked != nil && picked == model.activeCell
            let estimated=here && (model.isResting ||
                (picked.map { model.provisionalSeconds(for:[$0.id],now:now) > 0 } ?? false))
            VStack(alignment:.leading,spacing:8) {
                if mode == .compact {
                    Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:5) {
                        GridRow {
                            Text("").frame(minWidth:64,alignment:.leading)
                            Text("Total").foregroundStyle(.secondary)
                            Text("Estancia").foregroundStyle(.secondary)
                        }
                        if let zone {
                            GridRow {
                                Text("Zona").foregroundStyle(.primary)
                                Text(TimeMapCardClock.display(model.total(for:zone,now:now)))
                                    .fontWeight(.semibold)
                                Text(here ? TimeMapCardClock.display(
                                    model.zoneStaySeconds(for:zone,now:now)) : "—")
                                    .fontWeight(.semibold)
                            }
                        }
                        if let picked {
                            GridRow {
                                Text("Cuadrícula").foregroundStyle(.primary)
                                Text(TimeMapCardClock.display(model.total(for:picked,now:now)))
                                    .fontWeight(.semibold)
                                Text(here ? TimeMapCardClock.display(
                                    model.staySeconds(now:now)) : "—")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .font(.system(size:12,design:.rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                } else {
                    if let zone {
                        Label("Zona · \(zone.cellIDs.count) cuadrículas",
                              systemImage:"square.3.layers.3d")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TimeMapDetailRow(label:"Tiempo total en la zona",
                                         seconds:model.total(for:zone,now:now))
                        if here {
                            TimeMapDetailRow(label:"Estancia actual en la zona",
                                             seconds:model.zoneStaySeconds(for:zone,now:now))
                        }
                    }
                    if let picked {
                        if zone != nil { Divider().padding(.vertical,2) }
                        Label(here ? "Cuadrícula actual" : "Cuadrícula consultada",
                              systemImage:"square.grid.3x3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TimeMapDetailRow(label:"Tiempo total en esta cuadrícula",
                                         seconds:model.total(for:picked,now:now))
                        if here {
                            TimeMapDetailRow(label:"Estancia actual en esta cuadrícula",
                                             seconds:model.staySeconds(now:now))
                        }
                    }
                }
                if estimated {
                    Button {
                        showEstimationHelp=true
                    } label: {
                        Label(model.isResting ? "Tiempo estimado · GPS en pausa" :
                              "Tiempo provisional · pendiente de GPS",
                              systemImage:"clock.badge.questionmark")
                            .font(.system(size:11,weight:.medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal:false,vertical:true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Información sobre el tiempo estimado por GPS")
                } else if model.isResting {
                    Label("GPS en pausa · última ubicación",
                          systemImage:"moon.zzz.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if mode == .expanded,model.isResting {
                    Text("La ubicación permanece asumida mientras el GPS está en pausa. No es tiempo confirmado por un nuevo punto GPS.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
                if let age=model.gpsFixAge(now:now),age>120, !model.isResting, here {
                    Label("Sin GPS reciente · contador provisional detenido",
                          systemImage:"exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth:.infinity,alignment:.leading)
            .alert("Tiempo estimado",isPresented:$showEstimationHelp) {
                Button("Entendido",role:.cancel) { }
            } message: {
                Text(model.isResting ?
                     "Mientras el GPS está en pausa, se añade tiempo asumido a la última cuadrícula. Se distingue del tiempo confirmado por posiciones GPS." :
                     "Parte del contador es provisional hasta recibir y comprobar la siguiente posición GPS. No se guarda como tiempo confirmado por adelantado.")
            }
        }
    }
}

private struct TimeMapDetailRow:View {
    let label:String
    let seconds:TimeInterval
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(DurationFormat.full(seconds))
                .font(.system(size:18,weight:.semibold,design:.rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
