import SwiftUI
import WidgetKit
import ActivityKit

// Solo extensión de la Live Activity, sin widget en el escritorio.
// iOS limita la altura de la actividad: nunca añadir filas expansivas
// al panel principal. Se usan los mismos datos BIOGRID ya calculados.
private struct LiveBIOGRIDFamilies:View {
    let counts:[Int64]?
    let updatedAt:Date?
    let dense:Bool
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
    private var safe:[Int64]? { TimeLiveCompactPresentation.families(counts) }

    var body:some View {
        VStack(alignment:.leading,spacing:dense ? 3 : 4) {
            HStack(spacing:4) {
                Image(systemName:"circle.hexagongrid.fill")
                    .font(.system(size:10))
                    .foregroundStyle(.teal)
                Text("BIOGRID · cuadrícula actual")
                    .font(.system(size:10,weight:.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength:4)
                if let safe {
                    Text("Σ \(safe.reduce(Int64(0),+).formatted())")
                        .font(.system(size:10,weight:.medium,design:.rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let safe {
                HStack(spacing:2) {
                    ForEach(0..<7,id:\.self) { index in
                        VStack(spacing:2) {
                            HStack(spacing:2) {
                                Circle().fill(palette[index])
                                    .frame(width:6,height:6)
                                Text(names[index])
                                    .font(.system(size:9,weight:.semibold))
                            }
                            Text(safe[index].formatted(.number.notation(.compactName)))
                                .font(.system(size:dense ? 10 : 11,
                                             weight:.bold,design:.rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(maxWidth:.infinity)
                        .padding(.vertical,dense ? 2 : 3)
                        .background(palette[index].opacity(0.10),
                                    in:RoundedRectangle(cornerRadius:4))
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel("Familia \(names[index]): \(safe[index]) bacterias")
                    }
                }
            } else {
                Text("Actualizando poblaciones…")
                    .font(.system(size:10))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children:.contain)
    }
}

private struct MiMapaLivePanel:View {
    let state:TimeMapActivityAttributes.ContentState
    let isStale:Bool

    private var primary:String {
        TimeLiveCompactPresentation.title(site:state.siteName,
                                          fallback:state.cellName)
    }
    private var suggested:Bool {
        TimeLiveCompactPresentation.isProposed(site:state.siteName,
                                               confirmed:state.siteConfirmed)
    }

    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            // One headline, not two competing titles and an extra site row.
            HStack(alignment:.top,spacing:7) {
                Image(systemName:state.resting ? "moon.zzz.fill" :
                      state.moving ? "figure.walk" : "location.fill")
                    .font(.system(size:14))
                    .foregroundStyle(.teal)
                    .frame(width:18)
                VStack(alignment:.leading,spacing:1) {
                    Text(primary)
                        .font(.system(size:15,weight:.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    HStack(spacing:5) {
                        Text(state.cellNumber)
                        if suggested { Text("· Propuesto") }
                    }
                    .font(.system(size:10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.trailing,spacing:1) {
                    Text(state.moving ? "MOVIMIENTO" : "ESTANCIA")
                        .font(.system(size:8,weight:.semibold))
                        .foregroundStyle(.secondary)
                    liveClock.font(.system(size:22,weight:.semibold,design:.rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(width:122,alignment:.trailing)
            }
            .frame(height:42,alignment:.top)

            // Keep the two previous total measurements; a second zone-stay
            // row and graphical history caused the screenshot's clipping.
            HStack(spacing:10) {
                VStack(alignment:.leading,spacing:1) {
                    Text("Total cuadrícula").font(.system(size:9))
                        .foregroundStyle(.secondary)
                    Text(TimeLiveDuration.compact(state.confirmedCellSeconds))
                        .font(.system(size:14,weight:.semibold,design:.rounded))
                        .lineLimit(1)
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                if let zone=state.confirmedZoneSeconds {
                    VStack(alignment:.leading,spacing:1) {
                        Text("Total zona").font(.system(size:9))
                            .foregroundStyle(.secondary)
                        Text(TimeLiveDuration.compact(zone))
                            .font(.system(size:14,weight:.semibold,design:.rounded))
                            .lineLimit(1)
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            .frame(height:32,alignment:.top)

            LiveBIOGRIDFamilies(counts:state.bioGridCounts,
                                updatedAt:state.bioGridUpdatedAt,dense:false)

            HStack(spacing:4) {
                Image(systemName:state.resting ? "moon.zzz.fill" :
                      isStale ? "exclamationmark.triangle.fill" : "location.circle.fill")
                    .foregroundStyle(isStale ? .orange : .teal)
                Text(state.resting ? "GPS en pausa" :
                     isStale ? "GPS sin actualizar" : "GPS verificado")
                    .lineLimit(1)
                Spacer(minLength:0)
                if let updated=state.bioGridUpdatedAt {
                    Text("BIOGRID \(updated.formatted(date:.omitted,time:.shortened))")
                        .lineLimit(1)
                }
            }
            .font(.system(size:9))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal,11)
        .padding(.vertical,5)
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
                    VStack(alignment:.leading,spacing:2) {
                        Text(TimeLiveCompactPresentation.title(
                            site:context.state.siteName,
                            fallback:context.state.cellName))
                            .font(.system(size:12,weight:.semibold))
                            .lineLimit(1)
                        Text(context.state.cellNumber)
                            .font(.system(size:10))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment:.trailing,spacing:2) {
                        Text("Estancia").font(.system(size:9))
                        if context.state.resting {
                            Text(context.state.stayStartedAt,style:.timer)
                        } else {
                            Text(timerInterval:context.state.stayStartedAt...context.state.timerValidUntil,
                                 pauseTime:context.state.timerValidUntil,
                                 countsDown:false,showsHours:true)
                        }
                    }
                    .font(.system(size:12,weight:.semibold))
                    .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveBIOGRIDFamilies(counts:context.state.bioGridCounts,
                                        updatedAt:context.state.bioGridUpdatedAt,
                                        dense:true)
                        .padding(.top,2)
                }
            } compactLeading: {
                Image(systemName:context.isStale ? "exclamationmark.triangle" :
                      context.state.moving ? "figure.walk" :
                      context.state.resting ? "moon.zzz.fill" : "location.fill")
            } compactTrailing: {
                if context.state.resting {
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
