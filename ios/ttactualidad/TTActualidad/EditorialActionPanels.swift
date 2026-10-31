import SwiftUI
import UIKit
import CryptoKit

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
    @State private var showHints = false
    @State private var showTTProjectLink = false
    @State private var ttProjectLinkInput = UserDefaults.standard.string(
        forKey: "TTActualidad.chatgpt.projectTT.url") ?? ""
    @State private var confirmTrendToNews = false
    @Environment(\.openURL) private var openURL

    private var title: String { news?.title ?? trend?.name ?? "" }
    private var fullText: String { news?.editorial ?? trend?.explanation ?? "" }
    private var rank: Int { trend?.rank ?? 0 }
    private var revision: Int { news?.revision ?? trend?.revision ?? 0 }
    private var editorialID: String { news?.id ?? trend?.editorialID ?? "" }
    private var project: String { news == nil ? "ttendencias" : "ttittulares" }

    var body: some View {
        VStack(spacing: 7) {
            // Search is useful in every trend state, especially when research
            // needs clues. It never depends on Listas, text or GitHub login.
            if let trend {
                quickButton("Buscar en X", "magnifyingglass") {
                    var parts = URLComponents(string: "https://x.com/search")
                    parts?.queryItems = [URLQueryItem(name: "q", value: trend.name),
                                         URLQueryItem(name: "f", value: "live")]
                    if let url = parts?.url { openURL(url) }
                }
            }
            if let trend, trend.isCovered {
                Text("Agrupada en: " + trend.coveredByName)
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                quickButton("Quitar de Listas", "trash", danger: true) { request("deleted") }
                quickButton("Copiar explicación original", "doc.on.doc") { copy(fullText) }
                if let joint = store.snapshot.trendListas.first(where: { $0.editorialID == trend.coveredByID }) {
                    quickButton("Copiar publicación conjunta", "rectangle.3.group") { copy(joint.explanation) }
                }
            } else if let news, news.status != "LISTA" {
                HStack(spacing: 7) {
                    quickButton("Copiar título", "doc.on.doc") { copy(news.title) }
                    quickButton("Buscar en X", "magnifyingglass") {
                        var parts = URLComponents(string: "https://x.com/search")
                        parts?.queryItems = [URLQueryItem(name: "q", value: news.title),
                                             URLQueryItem(name: "f", value: "live")]
                        if let link = parts?.url { openURL(link) }
                    }
                }
                if news.status == "EN ELABORACIÓN" {
                    HStack(spacing: 7) {
                        quickButton("Copiar orden editorial", "doc.on.doc") {
                            copyManualEditorialPrompt()
                        }
                        quickButton("Abrir ChatGPT", "arrow.up.right.square") {
                            openChatGPTApp()
                        }
                    }
                    quickButton("URGENTE · Elaborar ya", "bolt.fill", urgent: true) {
                        launchUrgentEditorial()
                    }
                    Text("Copia la orden prioritaria y abre ChatGPT. Solo queda pegarla y enviarla.")
                        .font(.system(size: 10))
                        .foregroundStyle(TTTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    quickButton("Suprimir · No pasar a Listas", "trash", danger: true) {
                        request("discard")
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
                HStack(spacing: 7) {
                    quickButton("Copiar orden editorial", "doc.on.doc") {
                        copyManualEditorialPrompt()
                    }
                    quickButton("Abrir ChatGPT", "arrow.up.right.square") {
                        openChatGPTApp()
                    }
                }
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
            if let trend, trend.status != "EN ELABORACIÓN" {
                quickButton("Aportar pistas", "lightbulb") {
                    if github.authenticated {
                        showHints = true
                    } else {
                        showSettings = true
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
            if trend != nil {
                HStack(spacing: 7) {
                    quickButton("Copiar imagen Site", "square.on.square") {
                        copyTrendSiteImagePrompt()
                    }
                    quickButton("Abrir chat TT", "plus.bubble") {
                        openTTProject()
                    }
                    .alert("Enlace del proyecto TT", isPresented: $showTTProjectLink) {
                        TextField("Enlace de PROYECTOS APP", text: $ttProjectLinkInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Guardar y abrir") { saveAndOpenTTProject() }
                        Button("Cancelar", role: .cancel) {}
                    } message: {
                        Text("Pega una vez el enlace de tu proyecto de ChatGPT (no el del Site ni un chat compartido). El botón abrirá ese proyecto para crear allí un chat nuevo.")
                    }
                }
            }
            if trend != nil {
                quickButton("Enviar a TTiTTulares", "newspaper") {
                    if github.authenticated {
                        confirmTrendToNews = true
                    } else {
                        showSettings = true
                    }
                }
            }
            if !outcome.isEmpty {
                Text(outcome).font(.caption2).foregroundStyle(TTTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showHints) {
            if let trend {
                TrendHintsSheet(trend: trend, github: github)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("¿Investigar esta tendencia como noticia?",
               isPresented: $confirmTrendToNews) {
            Button("Enviar a En elaboración") {
                if let trend { sendTrendToNews(trend) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("TTiTTulares investigará el posible hecho noticioso con fuentes independientes. La tendencia seguirá en TTendencias. No se publicará automáticamente.")
        }
        .confirmationDialog(intent == "deleted" ? "¿Quitar de Listas?" :
                            intent == "discard" && news?.status == "EN ELABORACIÓN" ?
                            "¿Suprimir esta noticia en elaboración?" :
                            intent == "discard" ? "¿Desestimar esta entrada?" :
                            "¿Investigar y redactar desde cero?",
                            isPresented: $confirm, titleVisibility: .visible) {
            if intent == "deleted" && (news?.status == "LISTA" ||
                                        trend?.inListas == true) {
                Button("Publicado · Quitar de Listas") { submit("published") }
                Button("No publicado · Quitar de Listas", role: .destructive) {
                    submit("deleted")
                }
            } else {
                Button("Confirmar", role: intent == "deleted" ||
                    intent == "discard" ? .destructive : nil) { submit(intent) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(trend?.isCovered == true && intent == "deleted"
                 ? "Ambas opciones retiran solo esta original; la ficha conjunta se conserva. Solo «Publicado» suma una publicación, después de la confirmación de GitHub."
                 : intent == "deleted" && (news?.status == "LISTA" ||
                                         trend?.inListas == true)
                 ? "Ambas opciones retiran esta entrada. Solo «Publicado» suma al contador de publicaciones registradas en las últimas 24 horas, después de que GitHub lo confirme."
                 : intent == "rework" || intent == "prepare"
                 ? "Se solicitará una investigación nueva, sin reutilizar explicación ni remate. La orden se confirmará con GitHub."
                 : intent == "discard" && news?.status == "EN ELABORACIÓN"
                 ? "Se cancelará la investigación en GitHub y no se añadirá a Listas. Si ya terminó mientras confirmabas, se te avisará para que la quites desde Listas."
                 : "La orden se comprobará contra la revisión vigente de GitHub.")
        }
    }

    private func sendTrendToNews(_ trend: TrendItem) {
        // Stable UUID makes repeated taps/retries idempotent for the exact
        // original editorial ID + revision. A later trend revision can be sent.
        let bytes = SHA256.hash(data: Data(
            ("ttactualidad-trend-news:" + trend.editorialID +
             ":r" + String(trend.revision)).utf8))
        var digits = Array(bytes.map { String(format: "%02x", $0) }.joined().prefix(32))
        digits[12] = "4"
        digits[16] = "8"
        let requestID = [
            String(digits[0..<8]), String(digits[8..<12]),
            String(digits[12..<16]), String(digits[16..<20]),
            String(digits[20..<32])
        ].joined(separator: "-")
        let manualID = "manual-" + requestID
        if store.operationHistory.contains(where: {
            $0.id == manualID && $0.status != "Rechazada"
        }) {
            outcome = "Esta tendencia ya se ha enviado a TTiTTulares. Consulta Órdenes pendientes."
            return
        }
        let headline = String(("Investigar noticia: " + trend.name).prefix(240))
        let context = String(trend.explanation.prefix(280))
        var instructions = "Origen TTendencias: ID \(trend.editorialID), revisión \(trend.revision), nombre \(trend.name), puesto \(trend.rank). "
        instructions += "Investiga si hay un hecho noticioso reciente detrás de esta tendencia. "
        instructions += "Comprueba fechas y fuentes independientes; el hashtag no demuestra que haya ocurrido. "
        instructions += "Sin pruebas suficientes, no inventes una noticia ni la presentes como verificada."
        if !context.isEmpty {
            instructions += " Contexto preliminar, pendiente de contrastar: " + context
        }
        store.beginManualNews(requestID: requestID, title: headline,
                              url: "", fromTrend: true)
        outcome = "Solicitud provisional enviada a TTiTTulares. Consultar Órdenes pendientes."
        Task {
            let result = await github.addNews(
                title: headline, url: "", instructions: instructions,
                requestID: requestID, originTrend: trend)
            store.completeManualNews(requestID: requestID, result: result,
                                     detail: github.notice)
        }
    }

    private func submit(_ decision: String) {
        let requestID = UUID().uuidString.lowercased()
        guard store.beginEditorialAction(project: project, id: editorialID,
                                         revision: revision, decision: decision,
                                         title: title, rank: rank,
                                         requestID: requestID) else { return }
        let requestedID = editorialID
        let requestedRevision = revision
        let requestedProject = project
        let requestedTitle = title
        let requestedRank = rank
        Task {
            let result = await github.decide(project: requestedProject,
                                             eventID: requestedID,
                                             revision: requestedRevision,
                                             decision: decision,
                                             title: requestedTitle, rank: requestedRank,
                                             requestID: requestID)
            store.completeEditorialAction(project: requestedProject, id: requestedID,
                                          revision: requestedRevision, requestID: requestID,
                                          result: result, detail: github.notice)
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
        if store.isActionInProgress(project: project, id: editorialID, revision: revision) {
            // A stale request was previously a permanent lock. Check the
            // authoritative remote receipts/decisions before refusing a new
            // deletion. Never silently issue a duplicate on stale cached data.
            outcome = "Comprobando la orden anterior en GitHub…"
            Task {
                await store.refreshIfStale(minInterval: 0)
                if !store.isActionInProgress(project: project, id: editorialID,
                                              revision: revision) {
                    outcome = ""
                    intent = action
                    confirm = true
                } else {
                    outcome = "La orden anterior sigue sin resolverse en GitHub. Comprueba Órdenes por confirmar."
                }
            }
            return
        }
        intent = action
        confirm = true
    }

    private func quickButton(_ name: String, _ symbol: String, danger: Bool = false,
                             urgent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 42)
                .foregroundStyle(danger ? Color(red: 1, green: 0.71, blue: 0.76) : .white)
                .background(danger ? TTTheme.red.opacity(0.65) :
                            urgent ? Color(red: 0.57, green: 0.31, blue: 0.08) :
                            Color(red: 0.19, green: 0.31, blue: 0.46),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                    danger ? .red.opacity(0.5) :
                    urgent ? .orange.opacity(0.8) : TTTheme.blue.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    private func quickLink(_ name: String, _ symbol: String, _ raw: String) -> some View {
        quickButton(name, symbol) {
            guard let url = URL(string: raw) else { return }
            openURL(url)
        }
    }

    // GAG_VISUAL_NATIVE_V2: misma dirección artística de la elaboración automática,
    // sin las tarjetas de texto que se producían al copiar el prompt antiguo.
    private var gagPrompt: String {
        let closer = news?.closer ?? fullText.components(separatedBy: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("🌶") }) ?? ""
        let confirmedFacts = fullText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("🌶") && !$0.hasPrefix("#") }
            .joined(separator: "\n")
        let factual = news?.factual ?? confirmedFacts
        let folded = (title + " " + confirmedFacts + " " + factual)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
        let sensitiveTerms = [
            "victim", "fallec", "muert", "murio", "traged", "accident",
            "agresion sexual", "violacion", "asesinat", "atentad",
            "desaparecid", "herid", "catastrof", "suicid"
        ]
        let sensitive = sensitiveTerms.contains { folded.contains($0) }
        // Banco de estilos del reparador editorial TT, para imágenes únicas
        // con acabado cuidado, sin encuadres de tarjeta ni tipografía.
        let styles = [
            "Caricatura editorial contemporánea de alta calidad, línea de tinta expresiva y acuarela controlada, gestos muy trabajados y fondo ligero.",
            "Cómic europeo contemporáneo, entintado preciso, volumen sólido, expresiones fuertes y composición cinematográfica pero despejada.",
            "Póster gráfico editorial sofisticado, formas contundentes, geometría limpia y textura de impresión; SIN tipografía ni rótulos.",
            "Escena absurda semirrealista, materiales y texturas cuidados, iluminación natural y situación imposible tratada con precisión visual.",
            "Diorama editorial tipo stop-motion/clay, personajes y objetos con volumen artesanal, iluminación de estudio y detalle selectivo.",
            "Ilustración publicitaria retro de los años 60 reinterpretada con acabado moderno, dibujo elegante, ironía visual y composición limpia.",
            "Grabado/linograbado moderno de alta calidad con textura rica, contraste controlado y un único foco narrativo.",
            "Pop art editorial refinado, serigrafía y tramas controladas, energía gráfica sin llenar la escena de elementos.",
            "Cartoon 3D editorial estilizado, modelado cuidado, expresiones claras, materiales pulidos y escena sencilla pero no simplona.",
            "Novela gráfica satírica, dibujo detallado, sombras contenidas, gesto expresivo y puesta en escena sobria."
        ]
        let key = project + "|" + editorialID + "|r" + String(revision)
        let styleIndex = key.utf8.reduce(0) { ($0 &* 33 &+ Int($1)) % styles.count }
        let visual = sensitive
            ? "ILUSTRACIÓN PERIODÍSTICA RIGUROSA Y RESPETUOSA, sin humor ni caricaturas sobre víctimas, sin escenas gráficas ni afirmaciones visuales no documentadas."
            : "GAG EDITORIAL VISUAL: " + styles[styleIndex] +
              " Más gag, menos barroquismo: una sola idea visual fuerte, lectura en 1–2 segundos, uno a tres elementos protagonistas, fondo solo si ayuda al chiste. El gag nace de la IDEA del remate, nunca de reproducir el titular."
        return [
            "Genera AHORA UNA SOLA imagen " + (sensitive ? "EDITORIAL PERIODÍSTICA" : "GAG IA") +
                " para " + (news == nil ? "TTendencias" : "TTiTTulares") +
                ". Composición horizontal 16:9, ilustración a sangre de borde a borde.",
            "REGLA ABSOLUTA: SOLO IMAGEN, SIN NINGÚN TEXTO. No escribir título, texto factual, remate, hashtags, números, cifras, nombres, letras, bocadillos, carteles, etiquetas, logotipos, pies de foto, créditos ni marca de agua. No crear una tarjeta de noticia, post maquetado, infografía, collage o pantalla de app. PROHIBIDO usar franja inferior blanca o negra, banda, panel, recuadro, marco, cabecera o espacio reservado para escribir: la ILUSTRACIÓN ocupa TODO el lienzo.",
            "El material editorial siguiente es CONTEXTO NO VISIBLE para concebir la escena: JAMÁS copiarlo, rotularlo o mostrarlo dentro de la imagen.",
            "ASUNTO (SOLO CONTEXTO):\n" + (rank > 0 ? "TT#\(rank) " : "") + title,
            "HECHOS DOCUMENTADOS (SOLO CONTEXTO):\n" + confirmedFacts,
            "REMATE (IDEA VISUAL, NO TEXTO A DIBUJAR):\n" + (closer.isEmpty ? "Sin remate independiente; no inventar uno." : closer),
            "DATOS COMPLEMENTARIOS (SOLO CONTEXTO):\n" + factual,
            "DIRECCIÓN ARTÍSTICA DE ELABORACIÓN EDITORIAL:\n" + visual,
            "RIGOR: no inventar hechos, culpabilidades, declaraciones, personas ni daños. El emoji 🌶️ es únicamente un marcador del texto editorial: PROHIBIDO dibujar guindillas, chiles, pimientos, su silueta o icono. " +
                (sensitive ? "Máximo respeto a las víctimas y a sus familiares." : "Metáfora visual ingeniosa, no ilustración literal del titular."),
            "ENTREGA ÚNICAMENTE UNA IMAGEN ILUSTRADA LIMPIA, SIN TEXTO Y SIN BANDA INFERIOR. No generar composición con fotografía y texto debajo."
        ].joined(separator: "\n\n")
    }
    // Separate from Copiar GAG: the user pastes this complete instruction in
    // a normal ChatGPT project chat; only the existing Sites tools may attach it.
    // Neither this button nor opening ChatGPT creates an image or a PC job.
    private func copyTrendSiteImagePrompt() {
        guard let displayed = trend else { return }
        let target: TrendItem
        if displayed.isCovered {
            guard let leader = store.snapshot.trendListas.first(where: {
                $0.editorialID == displayed.coveredByID && !$0.isCovered
            }) else {
                outcome = "La explicación conjunta no está disponible. Actualiza Listas antes de copiar."
                return
            }
            target = leader
        } else {
            target = displayed
        }
        let targetID = target.siteImageEditorialID
        let explanation = target.explanation
        let explainedAt = target.siteImageExplainedAt
        let targetRevision = target.siteImageRevision
        guard targetID.range(of: "^[A-Za-z0-9_-]{3,160}$",
                             options: .regularExpression) != nil,
              !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !explainedAt.isEmpty, targetRevision >= 0,
              target.status != "EN ELABORACIÓN" else {
            outcome = "Falta identidad, fecha o explicación exacta. No se puede crear un prompt seguro."
            return
        }
        let lower = (target.name + " " + explanation).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_ES"))
        let sensitive = [
            "victim", "fallec", "muert", "murio", "traged", "accident",
            "agresion", "violacion", "asesinat", "atentad", "desaparecid",
            "herid", "catastrof", "suicid", "dana", "funeral", "rescate"
        ].contains(where: { lower.contains($0) })
        let visual = sensitive
            ? "Ilustración periodística sobria y respetuosa, sin humor ni caricaturas, sin escenas gráficas, víctimas inventadas o representación especulativa."
            : "GAG editorial ingenioso e inmediato: una sola metáfora visual del hecho o del remate, composición limpia y estilo ilustrado de alta calidad. Más gag, menos barroquismo."
        let closer = explanation.components(separatedBy: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("🌶") }) ?? ""
        let prompt = [
            "TTENDENCIAS_SITE_IMAGE_V3 — GENERAR, ADJUNTAR Y VERIFICAR EN UNA SOLA EJECUCIÓN",
            "Ejecuta en Chat normal dentro del proyecto de ChatGPT PROYECTOS APP. Sin Work, PC, API de pago ni cambios en la web o scripts del PC.",
            "SITE EXISTENTE: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/\nproject_id: appgprj_6ae4dcf7d7488191a574e5b649e67370",
            "IDENTIDAD EDITORIAL DE LA EXPLICACIÓN (NO IDENTIFICAR POR NOMBRE NI PUESTO):\ntarget_id: \(targetID)\nname: \(target.name)\nrevision: \(targetRevision)\nscope: editorial\nexplained_at: \(explainedAt)",
            "EXPLICACIÓN EXACTA — NO REESCRIBIR:\n\(explanation)",
            "REMATE EXACTO, SI EXISTE (SOLO CONTEXTO):\n\(closer.isEmpty ? "No hay remate separado." : closer)",
            "DIRECCIÓN VISUAL: \(visual) Composición horizontal 16:9, a sangre. SOLO IMAGEN, SIN NINGÚN TEXTO: no dibujar cifras, letras, títulos, nombres, hashtags, bocadillos, logotipos, tarjetas, franjas ni guindillas. No inventar hechos, daños o declaraciones.",
            "1. Invoca mcp__TTendencias___TTActualidad__inspect_top30_images. Comprueba que la explicación compartida, target_id, revisión, texto LITERAL y explained_at siguen siendo EXACTAMENTE los de arriba. Si cambian, detente; NO regeneres con datos antiguos. Si no está en el Top 30, verifica en los datos originales y con verify_trend_image; si no puedes confirmar su identidad vigente, detente.",
            "2. Comprueba con mcp__TTendencias___TTActualidad__verify_trend_image que no hay imagen IA válida. Foto de archivo no cuenta. Revisa si el PC mantiene un trabajo activo, LAUNCHED sin entrega verificable o incierto: en tal caso detente para no duplicar. Si hay un original inequívocamente terminado, reutilízalo.",
            "3. Si sigue siendo elegible, utiliza ChatGPT Images AHORA para generar UNA SOLA imagen siguiendo el contexto y la dirección visual indicados. Conserva el archivo PNG ORIGINAL y su identificador real. La generación es solo un paso intermedio: NO TERMINES AL MOSTRAR LA IMAGEN.",
            "4. A continuación, en este MISMO CHAT y SIN REGENERAR, invoca mcp__TTendencias___TTActualidad__attach_trend_image con file igual al archivo PNG ORIGINAL recién generado y context con los siete campos exactos project_id, target_id, name, revision, scope, explanation y explained_at. Revalida identidad antes de adjuntar. No uses rutas inventadas, imágenes parecidas ni identificaciones por nombre/puesto.",
            "5. Inmediatamente invoca mcp__TTendencias___TTActualidad__verify_trend_image con el mismo context. Solo declara ÉXITO cuando devuelva status: verified, URL del PNG persistido y SHA-256, y comprueba la ficha pública si el acceso lo permite. El mecanismo existente no requiere republicar ni crear otro Site.",
            "6. Si falla la incorporación, conserva el original y comunica el error exacto para reintentar ÚNICAMENTE attach_trend_image y verify_trend_image, sin regeneración. Procesa una sola tendencia y termina. No toques listeners, scripts ni imagen automática del PC."
        ].joined(separator: "\n\n")
        copy(prompt)
        outcome = "Prompt Site copiado para ID " + targetID + ". Abre un chat del proyecto TT y pégalo."
    }

    // ChatGPT does not document an external URL that starts a new conversation
    // inside an arbitrary private project. Save the user's actual project URL
    // and open it; then New chat in that project retains the correct context.
    private func validatedTTProjectURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https", url.host?.lowercased() == "chatgpt.com",
              url.path.hasPrefix("/g/g-p-") || url.path.hasPrefix("/project/") else {
            return nil
        }
        return url
    }

    private func openTTProject() {
        if let saved = UserDefaults.standard.string(forKey: "TTActualidad.chatgpt.projectTT.url"),
           let url = validatedTTProjectURL(saved) {
            openURL(url)
            outcome = "Proyecto TT abierto. Pulsa Nuevo chat dentro del proyecto y pega el prompt."
        } else {
            showTTProjectLink = true
        }
    }

    private func saveAndOpenTTProject() {
        guard let url = validatedTTProjectURL(ttProjectLinkInput) else {
            outcome = "Introduce un enlace HTTPS válido del proyecto de ChatGPT (no del Site)."
            return
        }
        UserDefaults.standard.set(url.absoluteString,
                                  forKey: "TTActualidad.chatgpt.projectTT.url")
        openURL(url)
        outcome = "Enlace del proyecto TT guardado. Crea un chat allí y pega el prompt."
    }

    /// Manual cloud-only fallback when Windows editorial listeners are offline.
    /// The prompt is a REQUEST, not a GitHub dispatch or a claim of completion.
    /// A fresh GitHub read and the official outbox are mandatory for success.
    private var manualEditorialPrompt: String {
        let common = [
            "TT_ACTUALIDAD_MANUAL_EDITORIAL_V1 | Ejecuta AHORA la elaboración editorial REAL de este elemento desde ChatGPT, SIN depender del ordenador Windows.",
            "Repositorio autoritativo: fabricelop/europapress-rss, rama main. Utiliza el conector GitHub y búsqueda web para investigar y persistir. Si no puedes acceder o escribir en GitHub, indícalo y NO declares que has terminado.",
            "Proyecto: \(project). Elemento: \(title). ID exacto: \(editorialID). Revisión solicitada: \(revision).",
            "ANTES DE EMPEZAR, lee el contrato editorial vigente del proyecto en main y su cola y estado autoritativos. Relee el ID y revisión justo antes de investigar y antes de escribir. Si ya está explicado, READY, publicado, desestimado, eliminado, agrupado bajo una explicación vigente, o sustituido por otra revisión, NO lo reelabores ni lo dupliques; comprueba el cierre y explícalo.",
            "Trata solamente la revisión indicada y las relaciones editoriales imprescindibles para cerrar su grupo, sin reprocesar indiscriminadamente toda la cola. El título y los datos copiados del móvil son pistas, NO hechos verificados. Investiga con fuentes actuales e independientes; si no hay pruebas suficientes, conserva el estado pendiente o problemático y explica por qué.",
            "No llames a ImageGen, no generes imágenes, no envíes mensajes editoriales a Telegram, no publiques en X y no uses listeners, scripts ni tareas del PC. Nunca bloquees READY/explicada por falta de imagen.",
            "Aplica el resultado SOLO mediante el transporte/aplicador oficial de GitHub para este proyecto, sin modificar PR de control #2/#7, FabCalendar, SeLoRecordamos ni otros proyectos. El resultado no es válido por haber redactado un texto en el chat: verifica su persistencia real releyendo main y el estado final.",
            "AL TERMINAR informa del estado exacto, enlace al commit o aplicación, y si el elemento ha desaparecido de En elaboración y está en Listas. Si la escritura falla o sigue pendiente, dilo expresamente, sin afirmar éxito."
        ]
        if let news {
            var details = [
                "CONTRATO TTiTTulares: ttittulares/editorial-run-prompt.md.",
                "ESTADO TTiTTulares: ttittulares/editorial-queue.json, ttittulares/status.json, telegram/editorial-processing.json, ttittulares/prepared.json y ttittulares/decisions.json.",
                "Investiga y elabora el texto factual, 2–3 hashtags concretos y UN remate conforme al contrato. El tuit completo debe medir como máximo 256 caracteres. Si es publicable, materializa esta misma revisión en READY/Listas mediante el outbox oficial transportado por issue #164 y verifica el aplicador; no basta publicar un comentario.",
                "Fuentes detectadas en la tarjeta: \(news.sources)."
            ]
            if let url = news.sourceURL {
                details.append("Enlace de referencia para verificar, no prueba suficiente: \(url.absoluteString)")
            }
            return (common + details).joined(separator: "\n\n")
        }
        var details = [
            "CONTRATO TTendencias: trends/editorial-run-prompt.md.",
            "ESTADO TTendencias: trends/editorial-queue.json, trends/requests.json, trends/telegram-manual-explained.json y trends/mobile-decisions.json.",
            "Investiga la tendencia y redacta UNA explicación común si forma parte de un grupo lógico. Reutiliza el grupo si ya está explicado; no crees tarjetas duplicadas. Persiste el estado explained para el ID y revisión originales y sus miembros válidos mediante el outbox/aplicador oficial ttendencias-editorial-apply.yml. Comprueba que desaparece de preparing/update; en Listas puede figurar una sola tarjeta líder del grupo.",
            "Posición registrada en el móvil: \(rank)."
        ]
        if let trend, !trend.problemReason.isEmpty {
            details.append("Motivo de revisión mostrado, sin verificar: \(trend.problemReason)")
        }
        return (common + details).joined(separator: "\n\n")
    }

    private var urgentEditorialPrompt: String {
        [
            "TTITTULARES_URGENTE_MANUAL_V1 | PRIORIDAD EDITORIAL INMEDIATA. Atiende SOLO esta noticia ahora, sin esperar a una ejecución horaria, desde ChatGPT en la nube; no necesitas el PC.",
            "La prioridad significa investigar y comprobar esta noticia antes que otras entradas de la cola. NO omitas comprobación de hechos, fuentes, umbrales del contrato ni revalidación de ID/revisión; NO marques READY sin publicación verificable en el estado autoritativo.",
            "Si sigue en PROCESSING/rewrite_pending, elabora y persiste la noticia mediante el transporte GitHub oficial. Si se cerró entretanto, informa del estado real sin duplicarla. Las imágenes NO deben bloquear el texto.",
            manualEditorialPrompt
        ].joined(separator: "\n\n")
    }

    private func launchUrgentEditorial() {
        guard news?.status == "EN ELABORACIÓN", !editorialID.isEmpty else {
            outcome = "La noticia no está confirmada En elaboración. Actualiza la tarjeta."
            return
        }
        copy(urgentEditorialPrompt)
        outcome = "Orden urgente copiada. Pégala y envíala en ChatGPT para iniciar."
        openChatGPTApp()
    }

    /// Open ChatGPT's installed iOS app, not the separate Safari web session.
    /// Both schemes have been used by ChatGPT iOS; never fall back to the
    /// unauthenticated web homepage. Keep the editorial prompt on clipboard.
    private func openChatGPTApp() {
        guard let primary = URL(string: "chatgpt://"),
              let secondary = URL(string: "com.openai.chat://") else {
            outcome = "Orden copiada. Abre la app ChatGPT instalada y pega la orden."
            return
        }
        UIApplication.shared.open(primary, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(secondary, options: [:]) { alternativeOpened in
                    guard !alternativeOpened else { return }
                    DispatchQueue.main.async {
                        outcome = "No se pudo abrir ChatGPT automáticamente. La orden sigue copiada; abre la app desde el iPhone."
                    }
                }
            }
        }
    }

    private func copyManualEditorialPrompt() {
        guard !editorialID.isEmpty else {
            outcome = "Falta el ID editorial. Actualiza la tarjeta antes de copiar."
            return
        }
        copy(manualEditorialPrompt)
        outcome = "Orden copiada. Abre ChatGPT en el móvil, pega y envía. No necesita el PC."
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

