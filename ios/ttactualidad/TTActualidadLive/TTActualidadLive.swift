import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Live Activity only. ActivityKit controls lifetime and foreground refreshes;
// the widget never claims a push-based background feed that does not exist.
@main
struct TTActualidadLiveBundle: WidgetBundle {
    var body: some Widget {
        TTActualidadLiveWidget()
    }
}

struct TTActualidadLiveWidget: Widget {
    private let navy = Color(red: 0.07, green: 0.12, blue: 0.20)
    private let panel = Color(red: 0.12, green: 0.19, blue: 0.30)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveCountsAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "globe.europe.africa.fill")
                        .foregroundStyle(.mint)
                    Text("TTActualidad").font(.caption.weight(.bold))
                    Spacer(minLength: 2)
                    statusText(context)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(context.isStale || context.state.partialData ?
                                         Color.orange : Color.mint)
                    Text(context.state.checkedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }
                HStack(spacing: 7) {
                    Link(destination: URL(string: "ttactualidad://noticias")!) {
                        metric(context.state.newsReady, name: "Noticias",
                               working: context.state.newsWorking, color: .mint)
                    }
                    Link(destination: URL(string: "ttactualidad://tendencias")!) {
                        metric(context.state.trendsReady, name: "Tendencias",
                               working: context.state.trendsWorking, color: .cyan)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: context.state.pendingActions > 0 ?
                          "clock.badge.exclamationmark" : "checkmark.shield.fill")
                        .foregroundStyle(context.state.pendingActions > 0 ? Color.orange : Color.mint)
                    Text(context.state.pendingActions > 0 ?
                         "\(context.state.pendingActions) orden(es) por confirmar" :
                         "Consulta desde GitHub")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                    Spacer(minLength: 0)
                    Button(intent: RefreshLiveCountsIntent()) {
                        Label("Actualizar", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Actualizar contadores desde GitHub")
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .widgetURL(URL(string: "ttactualidad://listas"))
            .activityBackgroundTint(navy)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack {
                        Text("TTActualidad · Control editorial")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 0)
                        Text(context.state.checkedAt, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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
                    VStack(spacing: 7) {
                        HStack {
                            Label("\(context.state.newsWorking) noticias · \(context.state.trendsWorking) tendencias en elaboración",
                                  systemImage: "pencil.line")
                                .font(.system(size: 10))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                        }
                        HStack {
                            Label(context.state.pendingActions > 0 ?
                                  "\(context.state.pendingActions) orden(es) pendientes" :
                                  context.isStale ? "Datos desactualizados" :
                                  context.state.partialData ? "Datos parciales" :
                                  "GitHub sincronizado",
                                  systemImage: context.state.pendingActions > 0 ?
                                  "clock" : "checkmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(context.isStale || context.state.partialData ||
                                                 context.state.pendingActions > 0 ? Color.orange : Color.mint)
                            Spacer(minLength: 4)
                            Button(intent: RefreshLiveCountsIntent()) {
                                Label("Actualizar", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } compactLeading: {
                Text("N\(context.state.newsReady)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.mint)
            } compactTrailing: {
                HStack(spacing: 2) {
                    Text("T\(context.state.trendsReady)")
                    if context.state.pendingActions > 0 {
                        Circle().fill(Color.orange).frame(width: 4, height: 4)
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: context.state.pendingActions > 0 ?
                      "clock.badge.exclamationmark" : "newspaper")
                    .foregroundStyle(context.state.pendingActions > 0 ? Color.orange : Color.mint)
            }
            .keylineTint(.cyan)
            .widgetURL(URL(string: "ttactualidad://listas"))
        }
    }

    private func statusText(_ context: ActivityViewContext<LiveCountsAttributes>) -> some View {
        Group {
            if context.isStale { Text("Desactualizado") }
            else if context.state.partialData { Text("Datos parciales") }
            else { Text("Sincronizado") }
        }
    }

    private func metric(_ count: Int, name: String, working: Int, color: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(String(count))
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(working) en elaboración")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private func counter(_ count: Int, title: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(String(count))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
