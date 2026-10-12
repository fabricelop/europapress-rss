import SwiftUI
import WidgetKit
import ActivityKit

// Solo extensión para la Live Activity. No se publica widget de escritorio.
private struct LiveGeoTile:View {
    let level:Int
    let selected:Bool
    let inTrail:Bool
    let headingDegrees:Double?
    var body:some View {
        RoundedRectangle(cornerRadius:2)
            .fill(selected ? Color.teal :
                  level>0 ? Color.teal.opacity(0.12+Double(level)*0.17) :
                  Color.gray.opacity(0.16))
            .frame(width:15,height:13)
            .overlay {
                if selected {
                    Image(systemName:headingDegrees == nil ? "location.fill" : "location.north.fill")
                        .font(.system(size:8,weight:.bold))
                        .rotationEffect(.degrees(headingDegrees ?? 0))
                        .foregroundStyle(.white)
                } else if inTrail {
                    Circle().fill(.orange).frame(width:4,height:4)
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
    let trail:[Int]
    let heading:Double?
    let moving:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text(moving ? "Rastro reciente" : "Cuadrículas")
                .font(.system(size:9,weight:.medium))
                .foregroundStyle(.secondary)
            ZStack {
                VStack(spacing:2) {
                    ForEach(0..<3,id:\.self) { row in
                        HStack(spacing:2) {
                            ForEach(0..<3,id:\.self) { col in
                                let index=row*3+col
                                LiveGeoTile(level:index<levels.count ? levels[index] : 0,
                                    selected:index==4,
                                    inTrail:trail.contains(index),
                                    headingDegrees:moving ? heading : nil)
                            }
                        }
                    }
                }
                if moving,trail.count>1 {
                    Path { path in
                        for (i,index) in trail.enumerated() where (0..<9).contains(index) {
                            let point=CGPoint(x:CGFloat(index%3)*17+7.5,
                                              y:CGFloat(index/3)*15+6.5)
                            if i==0 { path.move(to:point) }
                            else { path.addLine(to:point) }
                        }
                    }
                    .stroke(Color.orange.opacity(0.95),
                            style:StrokeStyle(lineWidth:1.4,lineCap:.round,lineJoin:.round))
                    .frame(width:49,height:43)
                    .allowsHitTesting(false)
                }
            }
            .frame(width:49,height:43)
        }
        .accessibilityElement(children:.combine)
        .accessibilityLabel(moving ? "Rastro GPS por cuadrículas recientes" :
            "Minimapa de nueve cuadrículas con la posición actual al centro")
    }
}
private struct LiveHoursGraph:View {
    let percentages:[Int]
    let minutes:[Int]
    let isZone:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Text(isZone ? "Permanencia · zona" : "Permanencia · cuadrícula")
                .font(.system(size:9,weight:.medium)).foregroundStyle(.secondary)
            HStack(alignment:.bottom,spacing:3) {
                ForEach(0..<6,id:\.self) { index in
                    let percent=index<percentages.count ? max(0,min(100,percentages[index])) : 0
                    let minute=index<minutes.count ? minutes[index] : 0
                    VStack(spacing:1) {
                        Text("\(minute)m").font(.system(size:8,weight:.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        RoundedRectangle(cornerRadius:2)
                            .fill(index==5 ? Color.teal : Color.teal.opacity(0.5))
                            .frame(height:max(2,CGFloat(percent)*0.30))
                            .frame(height:30,alignment:.bottom)
                    }
                    .frame(maxWidth:.infinity,alignment:.bottom)
                }
            }
            HStack {
                Text("Hace 6 h")
                Spacer()
                Text("Últimos 60 min")
            }
            .font(.system(size:8)).foregroundStyle(.secondary)
        }
    }
}
private struct LiveRecentRoute:View {
    let state:TimeMapActivityAttributes.ContentState
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            LiveGeoMiniMap(levels:state.nearbyIntensity,
                           trail:state.trailIndices,
                           heading:state.headingDegrees,moving:true)
                .frame(width:65,alignment:.leading)
            VStack(alignment:.leading,spacing:4) {
                HStack {
                    Label("Últimos 15 min",systemImage:"figure.walk")
                        .font(.system(size:10,weight:.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength:0)
                }
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    Text(state.recentDistanceMeters>=1000 ?
                         String(format:"%.1f km",Double(state.recentDistanceMeters)/1000) :
                         "\(state.recentDistanceMeters) m")
                        .font(.title3.weight(.bold))
                    Text("\(state.crossedCells) cuadrículas")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("Rastro de muestras GPS válidas")
                    .font(.system(size:9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth:.infinity,alignment:.leading)
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
            if state.moving {
                LiveRecentRoute(state:state)
            } else {
                HStack(alignment:.center,spacing:12) {
                    LiveGeoMiniMap(levels:state.nearbyIntensity,
                                   trail:[],heading:nil,moving:false)
                        .frame(width:65,alignment:.leading)
                    LiveHoursGraph(percentages:state.lastSixHours,
                                   minutes:state.lastSixMinutes,
                                   isZone:state.chartIsZone)
                        .frame(maxWidth:.infinity)
                }
            }
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
                        LiveGeoMiniMap(levels:context.state.nearbyIntensity,
                                       trail:context.state.trailIndices,
                                       heading:context.state.headingDegrees,
                                       moving:context.state.moving)
                    }
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
