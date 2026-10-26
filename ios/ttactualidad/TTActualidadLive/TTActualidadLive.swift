import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// This extension offers ONLY a Live Activity; there are no ordinary widgets.
@main
struct TTActualidadLiveBundle: WidgetBundle {
    var body: some Widget {
        TTActualidadLiveWidget()
    }
}

struct TTActualidadLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveCountsAttributes.self) { context in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("TTActualidad", systemImage: "newspaper")
                        .font(.caption.weight(.semibold))
                    Text(context.isStale ? "Datos pendientes de actualizar" :
                         context.state.partialData ? "Datos parciales" : "Listas para revisar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Consulta: " + context.state.checkedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                counter(context.state.newsReady, title: "Noticias", tint: .mint)
                counter(context.state.trendsReady, title: "Tendencias", tint: .cyan)
                Button(intent: RefreshLiveCountsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 40)
                        .background(.cyan.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actualizar contadores desde GitHub")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .widgetURL(URL(string: "ttactualidad://listas"))
            .activityBackgroundTint(Color(red: 0.07, green: 0.12, blue: 0.18))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("TTActualidad · En Listas")
                        .font(.caption.weight(.bold))
                }
                DynamicIslandExpandedRegion(.leading) {
                    Link(destination: URL(string: "ttactualidad://noticias")!) {
                        counter(context.state.newsReady, title: "Noticias", tint: .mint)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "ttactualidad://tendencias")!) {
                        counter(context.state.trendsReady, title: "Tendencias", tint: .cyan)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Datos sin actualizar" :
                             "Comprobado a las " + context.state.checkedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(intent: RefreshLiveCountsIntent()) {
                            Label("Actualizar", systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } compactLeading: {
                Text("N\(context.state.newsReady)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.mint)
            } compactTrailing: {
                Text("T\(context.state.trendsReady)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "newspaper")
            }
            .keylineTint(.cyan)
            .widgetURL(URL(string: "ttactualidad://listas"))
        }
    }

    private func counter(_ count: Int, title: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(String(count)).font(.title3.monospacedDigit().weight(.bold)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
