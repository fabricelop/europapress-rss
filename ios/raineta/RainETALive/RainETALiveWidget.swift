import SwiftUI
import WidgetKit
import ActivityKit

private struct RainLiveSummary: View {
    let state: RainETAAttributes.ContentState
    let isStale: Bool
    var body: some View {
        if isStale {
            Label("Previsión sin actualizar", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        } else if let target = state.arrival, target > Date() {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.rainingNow ? "Dejará de llover en" : "Lloverá en")
                    .font(.caption)
                Text(timerInterval: Date()...target, countsDown: true)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
        } else {
            Text(state.summary).font(.headline)
        }
    }
}

struct RainETALiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainETAAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.rainingNow ? "cloud.rain.fill" : "cloud.sun.rain.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 5) {
                    Text("RainETA · \(context.attributes.locationName)")
                        .font(.caption.bold())
                    RainLiveSummary(state: context.state, isStale: context.isStale)
                    Text("Radar/modelo: \(context.state.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .activityBackgroundTint(Color(red: 0.025, green: 0.07, blue: 0.16))
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
                        RainLiveSummary(state: context.state, isStale: context.isStale)
                        Spacer()
                        Text(context.state.updatedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "cloud.rain.fill")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else if let target = context.state.arrival, target > Date() {
                    Text(timerInterval: Date()...target, countsDown: true, showsHours: false)
                        .font(.caption2.monospacedDigit())
                } else {
                    Text("SECO").font(.caption2.bold())
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
