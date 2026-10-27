import SwiftUI
import UIKit

enum TTTheme {
    static let base = Color(red: 0.035, green: 0.065, blue: 0.13)
    static let panel = Color(red: 0.10, green: 0.145, blue: 0.26)
    static let teal = Color(red: 0.35, green: 0.89, blue: 0.81)
    static let blue = Color(red: 0.46, green: 0.70, blue: 1.0)
    static let muted = Color(red: 0.70, green: 0.77, blue: 0.86)
    static let red = Color(red: 0.39, green: 0.16, blue: 0.21)
    static let yellow = Color(red: 0.38, green: 0.32, blue: 0.12)
    static let green = Color(red: 0.09, green: 0.35, blue: 0.26)
    static let cardInterior = Color(red: 0.11, green: 0.17, blue: 0.27)
    static let cardBorder = Color(red: 0.018, green: 0.032, blue: 0.078)
    static let cardHighlight = Color(red: 0.19, green: 0.29, blue: 0.40)
}

struct EditorialActions: View {
    var news: NewsItem? = nil
    var trend: TrendItem? = nil
    @ObservedObject var github: GitHubEditor
    @EnvironmentObject private var store: EditorialStore
    @Binding var showSettings: Bool
    @State private var confirm = false
    @State private var intent = "deleted"
    @State private var outcome = ""
    @Environment(\.openURL) private var openURL

    private var title: String { news?.title ?? trend?.name ?? "" }
    private var fullText: String { news?.editorial ?? trend?.explanation ?? "" }
    private var rank: Int { trend?.rank ?? 0 }
    private var revision: Int { news?.revision ?? trend?.revision ?? 0 }
    private var editorialID: String { news?.id ?? trend?.editorialID ?? "" }
    private var project: String { news == nil ? "ttendencias" : "ttittulares" }

    var body: some View {
        VStack(spacing: 7) {
            if let news, news.status != "LISTA" {
                HStack(spacing: 7) {
                    quickButton("Copiar título", "doc.on.doc") { copy(news.title) }
                    quickButton("Buscar en X", "magnifyingglass") {
                        var parts = URLComponents(string: "https://x.com/search")
                        parts?.queryItems = [URLQueryItem(name: "q", value: news.title),
                                             URLQueryItem(name: "f", value: "live")]
                        if let link = parts?.url { openURL(link) }
                    }
                }
                if ["CRECIENDO", "REVISIÓN"].contains(news.status) {
                    HStack(spacing: 7) {
                        quickButton("Elaborar desde cero", "sparkles") { request("prepare") }
                        quickButton("Desestimar", "xmark.circle", danger: true) { request("discard") }
                    }
                } else if news.status == "TREMENDING" {
                    HStack(spacing: 7) {
                        if let original = tremendingOriginal(news.sourceURL) {
                            quickButton("Ver en Público", "arrow.up.right.square") {
                                openURL(original)
                            }
                        } else {
                            Text("Enlace original no disponible")
                                .font(.system(size: 11))
                                .foregroundStyle(TTTheme.muted)
                                .frame(maxWidth: .infinity)
                        }
                        quickButton("Quitar", "trash", danger: true) {
                            request("deleted")
                        }
                    }
                }
            } else if trend?.status == "EN ELABORACIÓN" {
                Text("Elaboración solicitada en GitHub; pendiente de cierre editorial.")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                quickButton("Copiar nombre", "doc.on.doc") { copy(title) }
            } else {
            HStack(spacing: 7) {
                quickLink("TTImages", "photo.stack", "https://t.me/TTImages_bot")
                quickButton("Publicar en X", "square.and.arrow.up") {
                    guard !fullText.isEmpty else { outcome = "Sin texto para publicar"; return }
                    var parts = URLComponents(string: "https://twitter.com/intent/tweet")
                    parts?.queryItems = [URLQueryItem(name: "text", value: fullText)]
                    if let url = parts?.url { openURL(url) }
                }
            }
            HStack(spacing: 7) {
                quickButton("Copiar GAG", "sparkles") { copy(gagPrompt) }
                quickLink("ChatGPT Images", "photo.artframe", "https://chatgpt.com/images")
            }
            HStack(spacing: 7) {
                quickButton("Copiar texto", "doc.on.doc") { copy(fullText) }
                quickButton("Foto archivo", "photo.on.rectangle") {
                    Task { await copyPhoto() }
                }
            }
            HStack(spacing: 7) {
                if news != nil || trend?.inListas == true {
                    quickButton("Quitar de Listas", "trash", danger: true) { request("deleted") }
                }
                if trend != nil {
                    // A single backend-supported fresh investigation for both
                    // unexplained Top 30 entries and already-explained trends.
                    quickButton("Elaborar desde cero", "arrow.triangle.2.circlepath") {
                        request("rework")
                    }
                } else {
                    // This action is served by the same authenticated direct
                    // GitHub dispatch as trend rework, once deployed to main.
                    quickButton("Elaborar desde cero", "arrow.triangle.2.circlepath") {
                        request("rework")
                    }
                }
            }
            if news != nil {
                quickButton("Buscar en X", "magnifyingglass") {
                    var parts = URLComponents(string: "https://x.com/search")
                    parts?.queryItems = [URLQueryItem(name: "q", value: title),
                                         URLQueryItem(name: "f", value: "live")]
                    if let url = parts?.url { openURL(url) }
                }
            }
            }
            if !outcome.isEmpty {
                Text(outcome).font(.caption2).foregroundStyle(TTTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(intent == "deleted" ? "¿Quitar de Listas?" :
                            intent == "discard" ? "¿Desestimar esta entrada?" :
                            "¿Investigar y redactar desde cero?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Confirmar", role: intent == "deleted" ? .destructive : nil) {
                let requestID = UUID().uuidString.lowercased()
                guard store.beginEditorialAction(project: project, id: editorialID,
                                                 revision: revision, decision: intent,
                                                 title: title, rank: rank,
                                                 requestID: requestID) else { return }
                let requestedDecision = intent
                let requestedID = editorialID
                let requestedRevision = revision
                let requestedProject = project
                let requestedTitle = title
                let requestedRank = rank
                Task {
                    let result = await github.decide(project: requestedProject,
                                                     eventID: requestedID,
                                                     revision: requestedRevision,
                                                     decision: requestedDecision,
                                                     title: requestedTitle, rank: requestedRank,
                                                     requestID: requestID)
                    store.completeEditorialAction(project: requestedProject, id: requestedID,
                                                  revision: requestedRevision,
                                                  result: result, detail: github.notice)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(intent == "rework" || intent == "prepare"
                 ? "Se solicitará una investigación nueva, sin reutilizar explicación ni remate. La orden se confirmará con GitHub."
                 : "La orden se comprobará contra la revisión vigente de GitHub. Enviar no significa que el cambio ya esté aplicado.")
        }
    }

    // Only open the original article from the trusted Tremending feed.
    // Never manufacture a search URL if an article has no valid source link.
    private func tremendingOriginal(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              ["publico.es", "www.publico.es"].contains(url.host?.lowercased() ?? ""),
              url.path.hasPrefix("/tremending/") else { return nil }
        return url
    }

    private func request(_ action: String) {
        guard github.authenticated else { showSettings = true; return }
        guard !editorialID.isEmpty else { outcome = "Identificador editorial no disponible. Actualiza antes."; return }
        guard !store.isActionInProgress(project: project, id: editorialID, revision: revision) else {
            outcome = "La orden ya está registrada y pendiente de confirmación."
            return
        }
        intent = action
        confirm = true
    }

    private func quickButton(_ name: String, _ symbol: String, danger: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 42)
                .foregroundStyle(danger ? Color(red: 1, green: 0.71, blue: 0.76) : .white)
                .background(danger ? TTTheme.red.opacity(0.65) : Color(red: 0.19, green: 0.31, blue: 0.46),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(danger ? .red.opacity(0.5) : TTTheme.blue.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    private func quickLink(_ name: String, _ symbol: String, _ raw: String) -> some View {
        quickButton(name, symbol) {
            guard let url = URL(string: raw) else { return }
            openURL(url)
        }
    }

    private var gagPrompt: String {
        let closer = news?.closer ?? fullText.components(separatedBy: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("🌶") }) ?? ""
        return [
            "Genera AHORA UNA SOLA imagen GAG IA para \(news == nil ? "TTendencias" : "TTiTTulares").",
            "TÍTULO:\n\(rank > 0 ? "TT#\(rank) " : "")\(title)",
            "TEXTO EXACTO CERRADO. NO LO REESCRIBAS:\n\(fullText)",
            "REMATE EXACTO:\n\(closer)",
            "CONTEXTO DOCUMENTADO:\n\(news?.factual ?? fullText)",
            "DIRECCIÓN VISUAL: gag satírico original. Una sola idea visual fuerte, composición limpia, lectura en 1-2 segundos, sin inventar hechos."
        ].joined(separator: "\n\n")
    }
    private func copy(_ value: String) {
        guard !value.isEmpty else { outcome = "No hay texto disponible."; return }
        UIPasteboard.general.string = value
        outcome = "Copiado al portapapeles"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    private func copyPhoto() async {
        guard let url = news?.imageURL ?? trend?.imageURL else {
            outcome = "Todavía no hay foto de archivo disponible."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            UIPasteboard.general.image = image
            outcome = "Fotografía copiada"
        } catch { outcome = "No se pudo copiar la fotografía." }
    }
}

struct NewsSubmissionSheet: View {
    @ObservedObject var github: GitHubEditor
    let onQueued: () -> Void
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss
    @State private var headline = ""
    @State private var url = ""
    @State private var instructions = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Añadir noticia") {
                    TextField("Titular o descripción", text: $headline, axis: .vertical).lineLimit(2...5)
                    TextField("Enlace HTTPS (opcional)", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Indicaciones editoriales (opcional)", text: $instructions, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Button {
                        let cleanTitle = headline.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanTitle.isEmpty || !cleanURL.isEmpty else { return }
                        if !cleanTitle.isEmpty && cleanTitle.count < 5 { return }
                        if !cleanURL.isEmpty &&
                            !(URL(string: cleanURL).map { $0.scheme == "https" && $0.host != nil } ?? false) {
                            return
                        }
                        let requestID = UUID().uuidString.lowercased()
                        sent = true
                        store.beginManualNews(requestID: requestID, title: cleanTitle, url: cleanURL)
                        onQueued()
                        dismiss()
                        let description = instructions
                        Task {
                            let result = await github.addNews(title: cleanTitle, url: cleanURL,
                                                              instructions: description,
                                                              requestID: requestID)
                            store.completeManualNews(requestID: requestID,
                                                     result: result, detail: github.notice)
                        }
                    } label: {
                        Label("Enviar a En elaboración", systemImage: "paperplane.fill")
                    }
                    .disabled(!github.authenticated || sent)
                    if sent {
                        Label("En elaboración (provisional). Confirmando con GitHub…", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !github.authenticated {
                        Text("Conecta una GitHub App desde Ajustes para poder añadir noticias.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(github.notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("＋ Noticia")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct GitHubConnectionSheet: View {
    @ObservedObject var github: GitHubEditor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(github.authenticated ? "Sesión conectada" : "Acceso seguro a GitHub",
                          systemImage: "lock.shield.fill")
                        .font(.title2.bold()).foregroundStyle(TTTheme.teal)
                    Text("Lectura siempre disponible. Para acciones editoriales, GitHub autoriza la aplicación directamente, sin Cloudflare ni introducir un token personal.")
                        .font(.subheadline).foregroundStyle(TTTheme.muted)
                    if github.authenticated {
                        Label("Sesión segura y renovable", systemImage: "checkmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TTTheme.teal)
                        Text(github.sessionSummary)
                            .font(.caption)
                            .foregroundStyle(TTTheme.muted)
                        Button("Desvincular", role: .destructive) { github.logout() }
                            .buttonStyle(.bordered)
                    } else {
                        Text("Configuración única: crea e instala una GitHub App limitada a fabricelop/europapress-rss, con permiso Contents lectura/escritura y Device Flow activado. Copia solamente su Client ID público.")
                            .font(.caption).foregroundStyle(TTTheme.muted)
                        Link("Configuración de GitHub Apps",
                             destination: URL(string: "https://github.com/settings/apps")!)
                        TextField("Client ID (Iv23li...)", text: $github.clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(12).background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 11))
                        Button("Conectar GitHub") { github.beginLogin() }
                            .buttonStyle(.borderedProminent).tint(TTTheme.teal)
                        if !github.deviceCode.isEmpty {
                            Text(github.deviceCode)
                                .font(.system(size: 27, weight: .heavy, design: .monospaced))
                                .foregroundStyle(TTTheme.teal)
                            Button("Autorizar en github.com/login/device") {
                                openURL(URL(string: "https://github.com/login/device")!)
                            }
                            .buttonStyle(.bordered)
                            Text("Código copiado al portapapeles. Autorízalo en GitHub. No cierres esta pantalla durante la vinculación.")
                                .font(.caption)
                        }
                    }
                    Text(github.notice).font(.caption).foregroundStyle(TTTheme.muted)
                }
                .padding(18)
            }
            .background(TTTheme.base)
            .navigationTitle("Conexión GitHub")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
