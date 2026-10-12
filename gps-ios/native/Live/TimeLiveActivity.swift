import SwiftUI
import WidgetKit
import ActivityKit

// WidgetKit es el punto de extensión obligatorio de ActivityKit;
// no se publica ningún widget del escritorio ni se usa App Group.
private struct LiveGeoTile:View {
    let level:Int
    let selected:Bool
    var body:some View {
        RoundedRectangle(cornerRadius:2)
            .fill(selected ? Color.teal :
                  level>0 ? Color.teal.opacity(0.12+Double(level)*0.17) :
                  Color.gray.opacity(0.16))
            .frame(width:15,height:13)
            .overlay {
                if selected {
                    Image(systemName:"location.fill")
                        .font(.system(size:8,weight:.bold))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius:2)
                    .stroke(selected ? Color.orange : .clear,lineWidth:1.6)
            }
    }
}

private struct LiveGeoMiniMap:View {
    let levels:[Int]
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text("Cuadrículas").font(.system(size:9,weight:.medium))
                .foregroundStyle(.secondary)
            VStack(spacing:2) {
                ForEach(0..<3,id:\.self) { row in
                    HStack(spacing:2) {
                        ForEach(0..<3,id:\.self) { column in
                            let index=row*3+column
                            LiveGeoTile(level:index<levels.count ? levels[index] : 0,
                                        selected:index==4)
                        }
                    }
                }
            }
        }
    }
}

private struct LiveHoursGraph:View {
    let percentages:[Int]
    let isZone:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text(isZone ? "6 h · zona" : "6 h · cuadrícula")
                .font(.system(size:9,weight:.medium))
                .foregroundStyle(.secondary)
            HStack(alignment:.bottom,spacing:3) {
                ForEach(0..<6,id:\.self) { index in
                    let percent=index<percentages.count ? max(0,min(100,percentages[index])) : 0
                    RoundedRectangle(cornerRadius:2)
                        .fill(index==5 ? Color.teal : Color.teal.opacity(0.42))
                        .frame(maxWidth:.infinity)
                        .frame(height:max(2,CGFloat(percent)*0.36))
                        .frame(height:38,alignment:.bottom)
                }
            }
            HStack {
                Text("−6 h")
                Spacer()
                Text("Ahora")
            }
            .font(.system(size:8)).foregroundStyle(.secondary)
        }
    }
}

private struct MiMapaLivePanel:View {
    let state:TimeMapActivityAttributes.ContentState
    let isStale:Bool

    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(alignment:.top,spacing:7) {
                Image(systemName:state.resting ? "moon.zzz.fill":"location.fill")
                    .foregroundStyle(.teal)
                VStack(alignment:.leading,spacing:1) {
                    Text(state.cellName).font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Text(state.cellNumber).font(.system(size:10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.trailing,spacing:1) {
                    Text("ESTANCIA").font(.system(size:9,weight:.semibold))
                        .foregroundStyle(.secondary)
                    liveClock.font(.system(.title3,design:.rounded,weight:.bold))
                        .monospacedDigit()
                        .frame(minWidth:90,alignment:.trailing)
                }
            }
            HStack(spacing:6) {
                VStack(alignment:.leading,spacing:1) {
                    Text("Total cuadrícula").font(.system(size:9)).foregroundStyle(.secondary)
                    Text(TimeLiveDuration.compact(state.confirmedCellSeconds))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                if let zone=state.confirmedZoneSeconds {
                    VStack(alignment:.leading,spacing:1) {
                        Text("Total zona").font(.system(size:9)).foregroundStyle(.secondary)
                        Text(TimeLiveDuration.compact(zone))
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            HStack(alignment:.center,spacing:12) {
                LiveGeoMiniMap(levels:state.nearbyIntensity)
                    .frame(width:65,alignment:.leading)
                LiveHoursGraph(percentages:state.lastSixHours,
                               isZone:state.chartIsZone)
                    .frame(maxWidth:.infinity)
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
                        Text(context.state.cellNumber)
                            .font(.caption2).foregroundStyle(.secondary)
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
                    HStack(spacing:12) {
                        VStack(alignment:.leading) {
                            Label(TimeLiveDuration.compact(context.state.confirmedCellSeconds),
                                  systemImage:"square.grid.2x2")
                            if let zone=context.state.confirmedZoneSeconds {
                                Label(TimeLiveDuration.compact(zone),
                                      systemImage:"square.3.layers.3d")
                            }
                            Text(context.isStale ? "GPS sin actualizar" :
                                 context.state.resting ? "GPS pausado" : "GPS activo")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        Spacer()
                        LiveGeoMiniMap(levels:context.state.nearbyIntensity)
                    }
                }
            } compactLeading: {
                Image(systemName:context.isStale ? "exclamationmark.triangle" :
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
                Image(systemName:"hourglass")
            }
            .widgetURL(URL(string:"mimapadeltiempoprueba://mapa"))
        }
    }
}

// Único contenido de la extensión: ActivityKit. No hay StaticConfiguration.
@main struct MiMapaLiveActivityBundle:WidgetBundle {
    var body:some Widget {
        MiMapaRestLiveActivity()
    }
}
