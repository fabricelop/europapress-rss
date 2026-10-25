import SwiftUI
import WidgetKit
import ActivityKit

// Solo extensión para la Live Activity. No se publica widget de escritorio.
/// Compact seven-family BIOGRID ledger replacing the old mini-map and the
/// last-six-hours bar graph. Counts are for the CURRENT 100m square only.
private struct LiveBIOGRIDFamilies:View {
    let counts:[Int64]?
    let updatedAt:Date?
    private let names=["L","M","X","J","V","S","D"]
    private let palette:[Color]=[
        Color(red:0.88,green:0.16,blue:0.18),
        Color(red:0.12,green:0.36,blue:0.92),
        Color(red:0.12,green:0.65,blue:0.23),
        Color(red:1.00,green:0.56,blue:0.02),
        Color(red:0.61,green:0.23,blue:0.78),
        Color(red:0.90,green:0.73,blue:0.00),
        Color(red:0.02,green:0.72,blue:0.79)
    ]

    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:5) {
                Image(systemName:"circle.hexagongrid.fill")
                    .foregroundStyle(.teal)
                Text("BIOGRID · bacterias en esta cuadrícula")
                    .font(.system(size:10,weight:.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength:0)
                if let counts,counts.count==7 {
                    Text("Total: \(counts.reduce(Int64(0),+).formatted())")
                        .font(.system(size:9,weight:.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let counts,counts.count==7 {
                HStack(spacing:4) {
                    ForEach(0..<7,id:\.self) { index in
                        VStack(spacing:3) {
                            HStack(spacing:2) {
                                Circle().fill(palette[index]).frame(width:6,height:6)
                                Text(names[index])
                                    .font(.system(size:9,weight:.semibold))
                            }
                            Text(counts[index].formatted(.number.notation(.compactName)))
                                .font(.system(size:11,weight:.bold,design:.rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(maxWidth:.infinity,minHeight:35)
                        .background(palette[index].opacity(0.10),
                                    in:RoundedRectangle(cornerRadius:5))
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel("Familia \(names[index]): \(counts[index]) bacterias")
                    }
                }
            } else {
                Text("Calculando población de las siete familias…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let updatedAt {
                Text("Recuento de la simulación · \(updatedAt.formatted(date:.omitted,time:.shortened))")
                    .font(.system(size:8)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
private struct MiMapaLivePanel:View {
    let state:TimeMapActivityAttributes.ContentState
    let isStale:Bool

    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top,spacing:7) {
                Image(systemName:state.resting ? "moon.zzz.fill" :
                      state.moving ? "figure.walk" : "location.fill")
                    .foregroundStyle(.teal)
                VStack(alignment:.leading,spacing:1) {
                    Text(state.cellName).font(.subheadline.weight(.bold)).lineLimit(2)
                    Text(state.cellNumber).font(.system(size:10))
                        .foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.trailing,spacing:1) {
                    Text(state.moving ? "EN MOVIMIENTO" : "ESTANCIA")
                        .font(.system(size:9,weight:.semibold))
                        .foregroundStyle(.secondary)
                    liveClock.font(.system(.title3,design:.rounded,weight:.bold))
                        .monospacedDigit().frame(minWidth:90,alignment:.trailing)
                }
            }
            if let site=state.siteName {
                HStack(spacing:5) {
                    Image(systemName:"mappin.and.ellipse").foregroundStyle(.teal)
                    Text("Sitio: (site)")
                        .font(.system(size:11,weight:.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if state.siteConfirmed != true {
                        Text("Propuesto").font(.system(size:8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing:8) {
                VStack(alignment:.leading,spacing:1) {
                    Text("Total cuadrícula").font(.system(size:9)).foregroundStyle(.secondary)
                    Text(TimeLiveDuration.compact(state.confirmedCellSeconds))
                        .font(.subheadline.weight(.semibold))
                }.frame(maxWidth:.infinity,alignment:.leading)
                if let zone=state.confirmedZoneSeconds {
                    VStack(alignment:.leading,spacing:1) {
                        Text("Total zona").font(.system(size:9)).foregroundStyle(.secondary)
                        Text(TimeLiveDuration.compact(zone))
                            .font(.subheadline.weight(.semibold))
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            if let stay=state.currentZoneStaySeconds {
                HStack(spacing:5) {
                    Image(systemName:"mappin.circle.fill").foregroundStyle(.teal)
                    Text("Esta visita a la zona:")
                    Text(TimeLiveDuration.compact(stay))
                        .fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size:10))
                .foregroundStyle(.secondary)
            }
            LiveBIOGRIDFamilies(counts:state.bioGridCounts,
                                updatedAt:state.bioGridUpdatedAt)
            if let milestone=state.milestone {
                Label(milestone,systemImage:"flag.fill")
                    .font(.system(size:10,weight:.medium))
                    .foregroundStyle(.teal).lineLimit(1)
            }
            HStack(spacing:4) {
                Image(systemName:state.resting ? "moon.zzz.fill" :
                      isStale ? "exclamationmark.triangle.fill" : "location.circle.fill")
                    .foregroundStyle(isStale ? .orange : .teal)
                Text(state.resting ? "GPS en pausa" :
                     isStale ? "Sin GPS reciente · reloj limitado" : "GPS verificado")
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength:0)
                if let last=state.lastGPSAt {
                    Text(last,style:.relative).lineLimit(1)
                }
            }
            .font(.system(size:10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal,12).padding(.vertical,8)
    }
    private var liveClock:Text {
        if state.resting { return Text(state.stayStartedAt,style:.timer) }
        return Text(timerInterval:state.stayStartedAt...state.timerValidUntil,
                    pauseTime:state.timerValidUntil,countsDown:false,showsHours:true)
    }
}
struct MiMapaRestLiveActivity:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:TimeMapActivityAttributes.self) { context in
            MiMapaLivePanel(state:context.state,isStale:context.isStale)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(context.state.cellName).font(.headline).lineLimit(2)
                        Text(context.state.moving ? "En movimiento" : context.state.cellNumber)
                            .font(.caption2).foregroundStyle(.secondary)
                        if let site=context.state.siteName {
                            Text("Sitio: \(site)")
                                .font(.caption2).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment:.trailing,spacing:2) {
                        Text("Estancia").font(.caption2)
                        if context.state.resting {
                            Text(context.state.stayStartedAt,style:.timer)
                        } else {
                            Text(timerInterval:context.state.stayStartedAt...context.state.timerValidUntil,
                                 pauseTime:context.state.timerValidUntil,
                                 countsDown:false,showsHours:true)
                        }
                    }.font(.caption).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment:.center,spacing:8) {
                        VStack(alignment:.leading,spacing:3) {
                            if context.state.moving {
                                Text("15 min · \(context.state.recentDistanceMeters) m")
                                    .font(.caption.weight(.semibold))
                                Text("\(context.state.crossedCells) cuadrículas recorridas")
                                    .font(.caption2)
                            } else {
                                Label(TimeLiveDuration.compact(context.state.confirmedCellSeconds),
                                      systemImage:"square.grid.2x2")
                                if let zone=context.state.currentZoneStaySeconds {
                                    Text("Zona esta visita: \(TimeLiveDuration.compact(zone))")
                                }
                            }
                            Text(context.isStale ? "GPS sin actualizar" :
                                 context.state.resting ? "GPS pausado" : "GPS activo")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        Spacer(minLength:0)
                    }
                    LiveBIOGRIDFamilies(counts:context.state.bioGridCounts,
                                        updatedAt:context.state.bioGridUpdatedAt)
                }
            } compactLeading: {
                Image(systemName:context.isStale ? "exclamationmark.triangle" :
                      context.state.moving ? "figure.walk" :
                      context.state.resting ? "moon.zzz.fill" : "location.fill")
            } compactTrailing: {
                if context.state.moving {
                    Text(context.state.recentDistanceMeters>=1000 ?
                         String(format:"%.1fkm",Double(context.state.recentDistanceMeters)/1000) :
                         "\(context.state.recentDistanceMeters)m")
                        .font(.caption2).monospacedDigit()
                        .frame(maxWidth:52)
                } else if context.state.resting {
                    Text(context.state.stayStartedAt,style:.timer)
                        .monospacedDigit().frame(maxWidth:52)
                } else {
                    Text(timerInterval:context.state.stayStartedAt...context.state.timerValidUntil,
                         pauseTime:context.state.timerValidUntil,
                         countsDown:false,showsHours:true)
                        .monospacedDigit().frame(maxWidth:52)
                }
            } minimal: {
                Image(systemName:context.state.moving ? "figure.walk" : "hourglass")
            }
            .widgetURL(URL(string:"mimapadeltiempoprueba://mapa"))
        }
    }
}
@main struct MiMapaLiveActivityBundle:WidgetBundle {
    var body:some Widget { MiMapaRestLiveActivity() }
}
