import SwiftUI

// Explicit, verified multi-selection. The backend applies all items atomically.
struct EditorialBatchSheet: View {
    @ObservedObject var github: GitHubEditor
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss

    let news: [NewsItem]
    let trends: [TrendItem]
    let onCompleted: () -> Void

    @State private var decision = "deleted"
    @State private var topic = ""
    @State private var confirm = false
    @State private var feedback = ""
    @State private var running = false

    private var hasTrends: Bool { !trends.isEmpty }
    private var total: Int { news.count + trends.count }
    private var canDelete: Bool {
        hasTrends ? trends.allSatisfy(\.inListas) :
                    news.allSatisfy { $0.status == "LISTA" }
    }
    private var valid: Bool {
        guard (2...12).contains(total), github.authenticated else { return false }
        if decision == "deleted" { return canDelete }
        return hasTrends && topic.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }
    private var payload: [[String: Any]] {
        if hasTrends {
            return trends.map {
                ["event_id": $0.editorialID, "revision": $0.revision,
                 "title": $0.name, "rank": $0.rank]
            }
        }
        return news.map {
            ["event_id": $0.id, "revision": $0.revision,
             "title": $0.title, "rank": 0]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Selección editorial") {
                    Text("\(total) elementos seleccionados")
                        .font(.headline)
                    if hasTrends {
                        ForEach(trends) { item in
                            HStack(alignment: .top) {
                                Text("#\(item.rank) \(item.name)")
                                Spacer()
                                Text("r\(item.revision)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ForEach(news) { item in
                            HStack(alignment: .top) {
                                Text(item.title)
                                    .lineLimit(2)
                                Spacer()
                                Text("r\(item.revision)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Acción") {
                    if canDelete {
                        Button {
                            decision = "deleted"
                        } label: {
                            Label("Quitar de Listas", systemImage:
                                  decision == "deleted" ? "checkmark.circle.fill" : "trash")
                        }
                        .foregroundStyle(decision == "deleted" ? TTTheme.teal : .primary)
                    }
                    if hasTrends {
                        Button {
                            decision = "rework"
                        } label: {
                            Label("Reelaborar juntas", systemImage:
                                  decision == "rework" ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        }
                        .foregroundStyle(decision == "rework" ? TTTheme.teal : .primary)
                        if decision == "rework" {
                            TextField("Tema común (obligatorio)", text: $topic)
                                .autocorrectionDisabled()
                            Text("La investigación cubrirá el tema común conservando el ID y la revisión de cada tendencia. El servidor comprobará todas las revisiones antes de confirmar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !canDelete && !hasTrends {
                        Label("Para retirar noticias en lote, selecciónalas desde Listas.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !hasTrends && decision == "rework" {
                        Text("La reelaboración conjunta está disponible para tendencias.")
                    }
                }

                Section {
                    Button {
                        confirm = true
                    } label: {
                        HStack {
                            if running { ProgressView().padding(.trailing, 6) }
                            Text(running ? "Esperando confirmación de GitHub…" :
                                 "Aplicar a \(total) elementos")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!valid || running)
                    if !feedback.isEmpty {
                        Text(feedback)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(github.notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Acciones múltiples")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                        .disabled(running)
                }
            }
            .confirmationDialog(
                "¿Confirmar \(decision == "rework" ? "reelaboración conjunta" : "retirada") de \(total) elementos?",
                isPresented: $confirm, titleVisibility: .visible
            ) {
                Button("Confirmar", role: decision == "deleted" ? .destructive : nil) {
                    Task {
                        running = true
                        let ok = await github.batch(
                            project: hasTrends ? "ttendencias" : "ttittulares",
                            decision: decision, items: payload,
                            groupTopic: topic.trimmingCharacters(in: .whitespacesAndNewlines))
                        feedback = github.notice
                        running = false
                        if ok {
                            await store.refresh()
                            onCompleted()
                            dismiss()
                        }
                    }
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("GitHub comprobará los IDs y revisiones vigentes. Una aceptación HTTP no cuenta como persistencia.")
            }
            .onAppear {
                if !canDelete && hasTrends { decision = "rework" }
            }
        }
        .preferredColorScheme(.dark)
    }
}
