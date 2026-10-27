import SwiftUI

// Authoritative publication-history view for exactly the previous 86,400 s.
// The oldest confirmed publication is shown first, numbered N down to 1.
struct PublishedHistorySheet: View {
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss

    let project: String

    private var heading: String {
        project == "ttittulares" ? "Titulares publicados" : "Tendencias publicadas"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let history = store.publicationsHistoryLast24h(
                project: project, now: context.date)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Últimas 24 horas exactas")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TTTheme.muted)
                            Spacer()
                            Text(history.map { String($0.count) } ?? "—")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(project == "ttittulares" ?
                                                 TTTheme.teal : TTTheme.blue)
                        }
                        .padding(.vertical, 5)

                        if let history {
                            if history.isEmpty {
                                ContentUnavailableView(
                                    "Sin publicaciones confirmadas",
                                    systemImage: "clock",
                                    description: Text(
                                        "No hay entradas marcadas como «Publicado» y confirmadas por GitHub en las últimas 24 horas."))
                            } else {
                                ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                                    historyRow(item, number: history.count - index)
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "Historial no disponible",
                                systemImage: "wifi.exclamationmark",
                                description: Text(
                                    "Aún no se ha podido consultar el registro de publicaciones de GitHub."))
                        }

                        Text("Ordenadas desde la más antigua. Horas en la zona horaria de este iPhone. Solo se cuentan confirmaciones reales de GitHub; no es un historial automático de publicaciones de X.")
                            .font(.system(size: 11))
                            .foregroundStyle(TTTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                    .padding(16)
                }
                .background(TTTheme.base.ignoresSafeArea())
                .navigationTitle(heading)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { dismiss() }
                            .foregroundStyle(TTTheme.teal)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func historyRow(_ item: ConfirmedPublication, number: Int) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text("#\(number)")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(project == "ttittulares" ? TTTheme.teal : TTTheme.blue)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.confirmedAt, format: .dateTime.day().month(.abbreviated())
                      .year().hour().minute().second())
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(TTTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("ID: " + item.eventID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TTTheme.muted.opacity(0.75))
                Label("Publicado · confirmado en GitHub",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TTTheme.teal)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(TTTheme.cardBorder, lineWidth: 1))
    }
}
