import SwiftUI
import WidgetKit
import ActivityKit
private struct Entry:TimelineEntry { let date:Date }
private struct Provider:TimelineProvider {
    func placeholder(in context:Context)->Entry { Entry(date:.now) }
    func getSnapshot(in context:Context,completion:@escaping (Entry)->Void) {
        completion(Entry(date:.now))
    }
    func getTimeline(in context:Context,completion:@escaping (Timeline<Entry>)->Void) {
        completion(Timeline(entries:[Entry(date:.now)],
                            policy:.after(Date().addingTimeInterval(3600))))
    }
}
struct SimpleProbeWidget:Widget {
    var body:some WidgetConfiguration {
        StaticConfiguration(kind:"WidgetProbeSimple",provider:Provider()) { _ in
            VStack(spacing:8) {
                Image(systemName:"checkmark.seal.fill").font(.title2)
                Text("WIDGET OK").font(.headline)
                Text("Sin App Group").font(.caption2)
            }
            .foregroundStyle(.teal)
            .containerBackground(for:.widget) { Color.teal.opacity(0.12) }
        }
        .configurationDisplayName("Diagnóstico Widget")
        .description("Prueba de firma de extensión WidgetKit sin datos compartidos.")
        .supportedFamilies([.systemSmall,.systemMedium,.accessoryRectangular])
    }
}
struct SimpleProbeLiveActivity:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:ProbeActivityAttributes.self) { context in
            HStack(spacing:12) {
                Image(systemName:"clock.fill")
                VStack(alignment:.leading) {
                    Text("ACTIVITY OK").font(.headline)
                    Text(context.state.caption).font(.caption)
                }
                Spacer()
                Text(context.state.startedAt,style:.timer)
            }
            .padding(14)
            .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack {
                        Text("ACTIVITY OK")
                        Text(context.state.startedAt,style:.timer)
                    }
                }
            } compactLeading: {
                Image(systemName:"clock")
            } compactTrailing: {
                Text(context.state.startedAt,style:.timer)
                    .frame(maxWidth:48)
            } minimal: {
                Image(systemName:"checkmark.seal.fill")
            }
        }
    }
}
@main
struct ProbeWidgetBundle:WidgetBundle {
    var body:some Widget {
        SimpleProbeWidget()
        SimpleProbeLiveActivity()
    }
}
