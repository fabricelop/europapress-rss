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
            TimeMapCardLiveRows(model:model,picked:picked,mode:mode,
                                now:context.date,showEstimationHelp:$showEstimationHelp)
        }
        .alert("Tiempo estimado",isPresented:$showEstimationHelp) {
            Button("Entendido",role:.cancel) { }
        } message: {
            Text(model.isResting ?
                 "Mientras el GPS está en pausa, se añade tiempo asumido a la última cuadrícula. Se distingue del tiempo confirmado por posiciones GPS." :
                 "Parte del contador es provisional hasta recibir y comprobar la siguiente posición GPS. No se guarda como tiempo confirmado por adelantado.")
        }
    }
}

private struct TimeMapCardLiveRows:View {
    @ObservedObject var model:TimeModel
    let picked:Cell?
    let mode:TimeMapCardSize
    let now:Date
    @Binding var showEstimationHelp:Bool

    private var zone:TimeCustomZone? {
        picked.flatMap { model.primaryZone(for:$0) }
    }
    private var isHere:Bool { picked != nil && picked == model.activeCell }
    private var isEstimated:Bool {
        guard isHere,let picked else { return false }
        return model.isResting ||
            model.provisionalSeconds(for:[picked.id],now:now)>0
    }

    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if mode == .compact {
                table
            } else {
                detailed
            }
            estimateStatus
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private var table:some View {
        Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:5) {
            GridRow {
                Text("").frame(minWidth:64,alignment:.leading)
                Text("Total").foregroundStyle(.secondary)
                Text("Estancia").foregroundStyle(.secondary)
            }
            if let zone {
                GridRow {
                    Text("Zona")
                    Text(TimeMapCardClock.display(model.total(for:zone,now:now)))
                        .fontWeight(.semibold)
                    Text(isHere ? TimeMapCardClock.display(
                        model.zoneStaySeconds(for:zone,now:now)) : "—")
                        .fontWeight(.semibold)
                }
            }
            if let picked {
                GridRow {
                    Text("Cuadrícula")
                    Text(TimeMapCardClock.display(model.total(for:picked,now:now)))
                        .fontWeight(.semibold)
                    Text(isHere ? TimeMapCardClock.display(
                        model.staySeconds(now:now)) : "—")
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.system(size:12,weight:.regular,design:.rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.68)
    }

    private var detailed:some View {
        VStack(alignment:.leading,spacing:8) {
            if let zone {
                Label("Zona · \(zone.cellIDs.count) cuadrículas",
                      systemImage:"square.3.layers.3d")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TimeMapDetailRow(label:"Tiempo total en la zona",
                                 seconds:model.total(for:zone,now:now))
                if isHere {
                    TimeMapDetailRow(label:"Estancia actual en la zona",
                                     seconds:model.zoneStaySeconds(for:zone,now:now))
                }
            }
            if let picked {
                if zone != nil { Divider().padding(.vertical,2) }
                Label(isHere ? "Cuadrícula actual" : "Cuadrícula consultada",
                      systemImage:"square.grid.3x3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TimeMapDetailRow(label:"Tiempo total en esta cuadrícula",
                                 seconds:model.total(for:picked,now:now))
                if isHere {
                    TimeMapDetailRow(label:"Estancia actual en esta cuadrícula",
                                     seconds:model.staySeconds(now:now))
                }
            }
        }
    }

    @ViewBuilder private var estimateStatus:some View {
        if isEstimated {
            Button {
                showEstimationHelp=true
            } label: {
                Label(model.isResting ? "Tiempo estimado · GPS en pausa" :
                      "Tiempo provisional · pendiente de GPS",
                      systemImage:"clock.badge.questionmark")
                    .font(.system(size:11,weight:.medium))
                    .foregroundStyle(.orange)
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
        if mode == .expanded && model.isResting {
            Text("La ubicación permanece asumida mientras el GPS está en pausa. No es tiempo confirmado por un nuevo punto GPS.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
        if let age=model.gpsFixAge(now:now),age>120, !model.isResting, isHere {
            Label("Sin GPS reciente · contador provisional detenido",
                  systemImage:"exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
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
