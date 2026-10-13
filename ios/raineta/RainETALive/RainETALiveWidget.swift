import SwiftUI
import WidgetKit
import ActivityKit

struct RainETALiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainETAAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.rainingNow ? "cloud.rain.fill" : "cloud.drizzle.fill")
                    .font(.title)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RainETA · \(context.attributes.locationName)")
                        .font(.caption.bold())
                    Text(context.isStale ? "Previsión sin actualizar" :
                         (context.state.rainingNow ? "La lluvia terminará en" : "La lluvia llegará en"))
                        .font(.subheadline)
                    if !context.isStale {
                        Text(timerInterval: Date()...context.state.arrival, countsDown: true)
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                    Text("Última consulta \(context.state.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.04, green: 0.1, blue: 0.2))
            .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("RainETA", systemImage: "cloud.rain.fill")
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.locationName)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Previsión caducada" :
                             (context.state.rainingNow ? "Termina en" : "Empieza en"))
                        Spacer()
                        if !context.isStale {
                            Text(timerInterval: Date()...context.state.arrival, countsDown: true)
                                .monospacedDigit()
                        }
                    }
                    .font(.headline)
                }
            } compactLeading: {
                Image(systemName: "cloud.rain.fill")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "exclamationmark.circle")
                } else {
                    Text(timerInterval: Date()...context.state.arrival, countsDown: true, showsHours: false)
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: "cloud.rain.fill")
                    .foregroundStyle(.cyan)
            }
        }
    }
}

@main
struct RainETALiveBundle: WidgetBundle {
    var body: some Widget {
        RainETALiveWidget()
    }
}
