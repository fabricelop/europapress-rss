import SwiftUI

// One free-form field. Editor-supplied information is always unverified.
struct TrendHintsSheet: View {
    let trend: TrendItem
    @ObservedObject var github: GitHubEditor
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss
    @State private var hints = ""
    @State private var error = ""
    @State private var submitting = false

    private var clean: String { hints.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(trend.name)
                    .font(.headline)
                Text("Incluye lo que has descubierto, enlaces, contexto, nombres o hipótesis. La investigación comprobará los hechos antes de publicar nada.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $hints)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                    .padding(9)
                    .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(TTTheme.teal.opacity(0.35)))
                    .accessibilityLabel("Pistas, explicaciones y enlaces")
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Button(action: submit) {
                    Label("Enviar pistas e investigar", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(TTTheme.teal)
                .disabled(clean.count < 8 || clean.count > 6000 || submitting)
                Text("Al enviarlo se mostrará una orden provisional. Solo el comprobante de GitHub confirmará su recepción y la nueva elaboración.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(TTTheme.base.ignoresSafeArea())
            .navigationTitle("Aportar pistas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        guard github.authenticated else {
            error = "Vincula GitHub desde el panel de conexión."
            return
        }
        guard !submitting else { return }
        submitting = true
        let id = trend.editorialID
        let revision = trend.revision
        let name = trend.name
        let rank = trend.rank
        let text = clean
        let requestID = UUID().uuidString.lowercased()
        Task {
            var accepted = store.beginEditorialAction(
                project: "ttendencias", id: id, revision: revision,
                decision: "hints", title: name, rank: rank, requestID: requestID)
            if !accepted {
                // A stale local 14:29 request must be reconciled with fresh
                // authoritative GitHub state before refusing editor clues.
                await store.refreshIfStale(minInterval: 0)
                accepted = store.beginEditorialAction(
                    project: "ttendencias", id: id, revision: revision,
                    decision: "hints", title: name, rank: rank,
                    requestID: requestID)
            }
            guard accepted else {
                error = "GitHub sigue teniendo una elaboración activa o no se pudo comprobar su estado. Revisa Órdenes pendientes."
                submitting = false
                return
            }
            dismiss()
            let result = await github.submitTrendHints(
                eventID: id, revision: revision,
                title: name, rank: rank, hints: text, requestID: requestID)
            store.completeEditorialAction(project: "ttendencias", id: id,
                                          revision: revision, result: result,
                                          detail: github.notice)
            submitting = false
        }
    }
}
