import SwiftUI

// Native editorial overview: no extra service or backend writes.
struct EditorialHub: View {
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss
    let openLists: () -> Void
    let openRadar: () -> Void
    let openWorking: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Centro editorial")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                        Text("Del radar a la publicación")
                            .font(.subheadline).foregroundStyle(TTTheme.muted)
                    }
                    .padding(.top, 10)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                        stage("RADAR", value: store.snapshot.top30.count +
                              store.snapshot.newsCreciendo.count, symbol: "waveform.path.ecg",
                              foot: "Top 30 y Creciendo", tint: TTTheme.blue, action: openRadar)
                        stage("EN ELABORACIÓN", value: store.snapshot.newsElaboracion.count +
                              store.snapshot.trendsElaboracion.count,
                              symbol: "pencil.line", foot: "Noticias y tendencias",
                              tint: .orange, action: openWorking)
                        stage("LISTAS", value: store.snapshot.news.count +
                              store.snapshot.trendListas.count, symbol: "checkmark.seal.fill",
                              foot: "Preparadas para publicar",
                              tint: TTTheme.teal, action: openLists)
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: "paperplane.fill")
                                .font(.title3).foregroundStyle(TTTheme.muted)
                            Text("PUBLICADAS")
                                .font(.caption.weight(.heavy)).foregroundStyle(TTTheme.muted)
                            Text("Histórico externo")
                                .font(.subheadline.weight(.semibold))
                            Text("No se deduce al abrir X")
                                .font(.caption2).foregroundStyle(TTTheme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                        .padding(12)
                        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    }

                    HStack {
                        Label("Novedades", systemImage: "sparkle.magnifyingglass")
                            .font(.headline).foregroundStyle(TTTheme.teal)
                        Spacer()
                        if store.isLoading { ProgressView() }
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Consultar", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .disabled(store.isLoading)
                    }
                    if store.novedades.isEmpty {
                        Text("No hay novedades detectadas desde la última visita completa.")
                            .font(.subheadline).foregroundStyle(TTTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 13))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.novedades, id: \.self) { message in
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6)).foregroundStyle(TTTheme.teal)
                                        .padding(.top, 6)
                                    Text(message)
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 9)
                                Divider().overlay(Color.white.opacity(0.12))
                            }
                        }
                        .padding(.horizontal, 13)
                        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 13))
                    }

                    Label(store.snapshot.partial ? "Hay datos en caché o incompletos" :
                          "Última consulta completa a GitHub", systemImage:
                          store.snapshot.partial ? "exclamationmark.triangle" : "checkmark.shield")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                }
                .padding(16)
            }
            .background(TTTheme.base)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func stage(_ name: String, value: Int, symbol: String, foot: String,
                       tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2).foregroundStyle(TTTheme.muted)
                }
                Text(name)
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(TTTheme.muted)
                Text(String(value))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint).monospacedDigit()
                Text(foot)
                    .font(.caption2).foregroundStyle(TTTheme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .padding(12)
            .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.28)))
        }
        .buttonStyle(.plain)
    }
}