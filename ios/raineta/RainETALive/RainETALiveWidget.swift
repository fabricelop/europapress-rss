import SwiftUI
import WidgetKit
import ActivityKit

// This extension intentionally contains ONLY a Live Activity; it does not
// expose an independent Home Screen widget that needs an extra install path.

private enum LivePrecipitation {
    static func kind(_ state:RainETAAttributes.ContentState) -> RainPrecipitationPhase {
        RainPrecipitationPhase(rawValue:state.precipitationKind ?? "") ?? .rain
    }
    static func glyph(_ state:RainETAAttributes.ContentState) -> String {
        if state.summary == "Actualizando previsión" {return "arrow.clockwise"}
        return state.rainingNow ? kind(state).glyph :
               "cloud.fill"
    }
    static func source(_ state:RainETAAttributes.ContentState)->String {
        state.sourceLabel ?? "Previsión orientativa"
    }
}

private struct RainLiveSummary:View {
    let state:RainETAAttributes.ContentState
    let isStale:Bool

    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            if state.summary == "Actualizando previsión" {
                Label("Consultando precipitación…",systemImage:"arrow.clockwise")
                    .foregroundStyle(.cyan)
            } else if isStale {
                Label("Datos sin actualizar",systemImage:"exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
            } else if let target=state.arrival,target>Date() {
                Text(state.rainingNow ?
                     "Termina \(LivePrecipitation.kind(state).label) en" :
                     "Llega \(LivePrecipitation.kind(state).label) en")
                    .font(.caption).foregroundStyle(.secondary)
                Text(timerInterval:Date()...target,countsDown:true)
                    .font(.system(size:27,weight:.bold,design:.rounded))
                    .monospacedDigit()
            } else {
                Text(state.summary)
                    .font(.headline.bold())
                    .fixedSize(horizontal:false,vertical:true)
                    .lineLimit(2)
            }
        }
    }
}

private struct RainLivePulse:View {
    let state:RainETAAttributes.ContentState
    let height:CGFloat

    var body:some View {
        if let bars=state.nextHourBars,!bars.isEmpty {
            VStack(alignment:.leading,spacing:4) {
                HStack(alignment:.bottom,spacing:3) {
                    ForEach(Array(bars.prefix(12).enumerated()),id:\.offset) { item in
                        RoundedRectangle(cornerRadius:2)
                            .fill(item.element==0 ?
                                  Color.gray.opacity(0.30) :
                                  LivePrecipitation.kind(state)==(.snow) ?
                                  Color.white.opacity(0.92) : Color.cyan)
                            .frame(maxWidth:.infinity)
                            .frame(height:max(3,height*CGFloat(item.element+1)/5))
                    }
                }
                .frame(height:height,alignment:.bottom)
                HStack {
                    Text("Ahora")
                    Spacer()
                    Text("+30 min")
                    Spacer()
                    Text("+60 min")
                }
                .font(.system(size:9))
                .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Evolución orientativa de precipitación en los próximos 60 minutos")
        }
    }
}

private struct RainLiveDetails:View {
    let state:RainETAAttributes.ContentState
    let stale:Bool
    var body:some View {
        HStack(spacing:5) {
            Text(LivePrecipitation.source(state))
            if !stale,let observed=state.radarObservedAt {
                Text("· radar \(observed.formatted(date:.omitted,time:.shortened))")
            }
            Spacer(minLength:0)
            Text(state.updatedAt,style:.time)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        if LivePrecipitation.kind(state) != .rain {
            Text("Tipo de precipitación según modelo; radar no distingue nieve")
                .font(.system(size:9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct RainETALiveWidget:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:RainETAAttributes.self) { context in
            VStack(alignment:.leading,spacing:9) {
                HStack(alignment:.center,spacing:9) {
                    Image(systemName:LivePrecipitation.glyph(context.state))
                        .font(.title2)
                        .foregroundStyle(.cyan)
                    Text("RainETA · \(context.state.locationName ?? context.attributes.locationName)")
                        .font(.caption.bold())
                        .lineLimit(1)
                    Spacer(minLength:3)
                    if let temp=context.state.temperatureC {
                        Text("\(Int(temp.rounded()))°")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                RainLiveSummary(state:context.state,isStale:context.isStale)
                RainLivePulse(state:context.state,height:32)
                RainLiveDetails(state:context.state,stale:context.isStale)
            }
            .padding(13)
            .activityBackgroundTint(Color(red:0.025,green:0.07,blue:0.15))
            .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: {context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("RainETA",systemImage:LivePrecipitation.glyph(context.state))
                        .foregroundStyle(.cyan)
                        .font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.locationName ?? context.attributes.locationName)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment:.leading,spacing:8) {
                        RainLiveSummary(state:context.state,isStale:context.isStale)
                        RainLivePulse(state:context.state,height:25)
                        RainLiveDetails(state:context.state,stale:context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName:LivePrecipitation.glyph(context.state))
                    .foregroundStyle(context.isStale ? .yellow : .cyan)
            } compactTrailing: {
                if context.state.summary=="Actualizando previsión" {
                    Text("…").font(.caption2.bold())
                } else if context.isStale {
                    Image(systemName:"exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else if let target=context.state.arrival,target>Date() {
                    Text(timerInterval:Date()...target,countsDown:true,showsHours:false)
                        .font(.caption2.monospacedDigit())
                } else {
                    Text(context.state.rainingNow ? 
                         (LivePrecipitation.kind(context.state)==(.snow) ? "NIEVE":"LLUEVE") : "SECO")
                        .font(.system(size:9,weight:.bold))
                }
            } minimal: {
                Image(systemName:LivePrecipitation.glyph(context.state))
                    .foregroundStyle(context.isStale ? .yellow : .cyan)
            }
        }
    }
}

@main
struct RainETALiveBundle:WidgetBundle {
    var body:some Widget {
        RainETALiveWidget()
    }
}
