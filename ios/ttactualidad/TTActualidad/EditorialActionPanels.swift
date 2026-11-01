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
                HStack(spacing: 7) {
                    quickButton("Publicar en X", "square.and.arrow.up") { publishOnX() }
                    quickButton("Copiar foto", "photo.on.rectangle") {
                        Task { await copyPhoto() }
                    }
                }
                quickButton("Quitar de Listas", "trash", danger: true) { request("deleted") }
                quickButton("Copiar explicación original", "doc.on.doc") { copy(fullText) }
                // A covered original is still its own editorial identity. The
                // existing rework action opens a NEW investigation without
                // deleting this original or the previously published joint.
                quickButton("Volver a evaluar", "arrow.triangle.2.circlepath") {
                    request("rework")
                }
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
                quickButton("Publicar en X", "square.and.arrow.up") { publishOnX() }
            }
            HStack(spacing: 7) {
                quickButton("Copiar GAG", "sparkles") { copy(gagPrompt) }
                quickLink("ChatGPT Images", "photo.artframe", "https://chatgpt.com/images")
            }
            HStack(spacing: 7) {
                quickButton("Copiar texto", "doc.on.doc") { copy(fullText) }
                quickButton("Copiar foto", "photo.on.rectangle") {
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
                 : trend?.isCovered == true && intent == "rework"
                 ? "Se pedirá una evaluación nueva e independiente de esta tendencia, sin reutilizar el texto ni la imagen antigua. La explicación original y la ficha conjunta se conservarán. Solo se marcará como solicitada cuando GitHub lo confirme."
                 : intent == "rework" || intent == "prepare"
                 ? "Se solicitará una investigación nueva, sin reutilizar explicación ni remate. La orden se confirmará con GitHub."
                 : intent == "discard" && news?.status == "EN ELABORACIÓN"
                 ? "Se cancelará la investigación en GitHub y no se añadirá a Listas. Si ya terminó mientras confirmabas, se te avisará para que la quites desde Listas."
                 : "La orden se comprobará contra la revisión vigente de GitHub.")
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
        let imagePrompt = [
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
        // The manually copied GAG must carry the same immutable context as
        // the button for associating an already-created image. Never use rank,
        // title or a pending request ID as an upload authorization.
        guard news == nil, let displayed = trend else { return imagePrompt }
        let leader = displayed.isCovered
            ? store.snapshot.trendListas.first(where: {
                $0.editorialID == displayed.coveredByID && !$0.isCovered
            })
            : nil
        let target = leader ?? displayed
        let targetID = target.siteImageEditorialID
        let explanation = target.explanation
        let explainedAt = target.siteImageExplainedAt
        let revision = target.siteImageRevision
        guard !targetID.isEmpty, !targetID.hasPrefix("site-term-"),
              !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !explainedAt.isEmpty, revision >= 0,
              target.status != "EN ELABORACIÓN",
              !(displayed.isCovered && leader == nil) else { return imagePrompt }
        let context: [String: Any] = [
            "project_id": "appgprj_6ae4dcf7d7488191a574e5b649e67370",
            "target_id": targetID,
            "name": target.name,
            "revision": revision,
            "scope": "editorial",
            "explanation": explanation,
            "explained_at": explainedAt
        ]
        guard let raw = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
              let exactContext = String(data: raw, encoding: .utf8) else { return imagePrompt }
        return imagePrompt + """

        
        TTENDENCIAS_GAG_AUTO_ATTACH_V2 — ENTREGA AUTOMÁTICA DE LA IMAGEN NUEVA.
        Genera UNA SOLA imagen y conserva su PNG ORIGINAL de ESTA MISMA CONVERSACIÓN. Este encargo manual más reciente tiene PRIORIDAD sobre trabajos anteriores de TTImages que todavía estén pendientes; un LAUNCHED antiguo NO puede bloquearlo. No utilices otra imagen ni una miniatura.
        Contexto editorial vigente a revalidar sin reescribir:
        \(exactContext)
        Después de ImageGen, SIN esperar otra orden del usuario: llama a inspect_top30_images y verifica target_id, revision, explanation literal y explained_at. Llama a verify_trend_image. Si falta imagen en Site, ejecuta attach_trend_image con el PNG ORIGINAL recién creado y el context exacto, luego verify_trend_image. Si la imagen anterior existe, la NUEVA es la preferida: solicita sustitución ÚNICAMENTE si el conector Site ofrece una operación autorizada y verificable de reemplazo para la misma identidad. No elimines ni falsifiques la asociación previa. Si el conector solo acepta alta y prohíbe sobrescribir, informa REEMPLAZO BLOQUEADO POR SITE, no afirmes que reemplazaste.
        Después de status verified y URL/SHA-256 reales, sincroniza GitHub main trends/site-ai-images.json manteniendo todas las otras entradas y reemplazando solo el registro exacto (target_id, revision) con explanation y explained_at literales; relee el catálogo. Comunica GENERACIÓN, SITE y APP por separado. No marques asociada la imagen nueva si Site solo conservó la imagen anterior.
        Si el turno termina al dibujar y no puedes ejecutar las herramientas, indica ASOCIACIÓN PENDIENTE. No solicites imágenes ni adjuntos de forma manual y no repitas la generación: la imagen original permanece en esta conversación para un retorno posterior. No inventes acceso a la galería ni anuncies éxito sin comprobación en Site y GitHub.
        """
    }
    // "Copiar imagen Site" is ONLY a safe existing-image attachment guide.
    // Prefer the ORIGINAL PNG already available in the same conversation.
    // A gallery/other-chat image needs explicit attachment if it is not in
    // current context; a thumbnail or shared URL is NOT the original.
    // Neither this button nor its prompt starts image generation.
    private func copyTrendSiteImagePrompt() {
        guard let displayed = trend else { return }

        // An original covered by a joint grouping should reuse the leader's
        // exact editorial identity, never an arbitrary matching name or rank.
        let leader = displayed.isCovered
            ? store.snapshot.trendListas.first(where: {
                $0.editorialID == displayed.coveredByID && !$0.isCovered
            })
            : nil
        let target = leader ?? displayed
        let targetID = target.siteImageEditorialID
        let explanation = target.explanation
        let explainedAt = target.siteImageExplainedAt
        let targetRevision = target.siteImageRevision
        let validID = targetID.range(of: "^[A-Za-z0-9_-]{3,160}$",
                                     options: .regularExpression) != nil
        let hasEditorialIdentity = validID &&
            !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !explainedAt.isEmpty && targetRevision >= 0 &&
            target.status != "EN ELABORACIÓN" &&
            !targetID.hasPrefix("site-term-") &&
            !(displayed.isCovered && leader == nil)

        let editorialContext = hasEditorialIdentity
            ? "IDENTIDAD EDITORIAL CANDIDATA (REVALIDAR ANTES DE ADJUNTAR):\n" +
              "target_id: \(targetID)\nname: \(target.name)\nrevision: \(targetRevision)\n" +
              "scope: editorial\nexplained_at: \(explainedAt)\n" +
              "EXPLICACIÓN LITERAL — NO REESCRIBIR:\n\(explanation)"
            : "IDENTIDAD AÚN NO CONFIRMADA PARA ADJUNTAR:\n" +
              "nombre visible: \(displayed.name)\npuesto orientativo: \(displayed.rank)\n" +
              "id provisional o antiguo: \(targetID.isEmpty ? "sin ID" : targetID)\n" +
              "estado actual: \(target.status)\n" +
              (displayed.isCovered
                ? "agrupada en: \(displayed.coveredByName), ID del grupo: \(displayed.coveredByID)\n"
                : "") +
              "El texto y/o la fecha editorial exactos no están disponibles aquí. " +
              "NO inventes scope editorial, ID, explicación ni explained_at."

        let prompt = [
            "TTENDENCIAS_SITE_ATTACH_EXISTING_V1 — SOLO ASOCIAR PNG ORIGINAL YA CREADO",
            "Proyecto ChatGPT PROYECTOS APP, chat normal, con las conexiones TTendencias y GitHub. " +
                "NO uses ImageGen ni generes, redibujes, mejores, conviertas o sustituyas imágenes. " +
                "NO publiques en X ni Telegram y NO utilices Work, PC, listeners ni API de pago.",
            "SITE ORIGINAL: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/\n" +
                "project_id: appgprj_6ae4dcf7d7488191a574e5b649e67370\n" +
                "Catálogo para iPhone: fabricelop/europapress-rss, main, trends/site-ai-images.json.",
            editorialContext,
            "ARCHIVO A ASOCIAR: primero identifica la ÚNICA imagen ORIGINAL ya " +
                "generada o aportada por el usuario EN ESTA MISMA CONVERSACIÓN, " +
                "preferiblemente en el mensaje al que se refiere expresamente " +
                "al decir «Asocia esta imagen a la tendencia». Si el archivo original " +
                "está disponible para attach_trend_image, REUTILÍZALO DIRECTAMENTE: " +
                "no pidas copiar, descargar ni adjuntar de nuevo y NO generes otra imagen. " +
                "Si hay varias candidatas, pregunta cuál de ellas debe asociarse; " +
                "nunca adivines por el aspecto ni el nombre. " +
                "Si la imagen está SOLO en otro chat o en la galería Imágenes y no " +
                "tienes acceso a su archivo original desde ESTA conversación, " +
                "pide al usuario que la seleccione/comparta o adjunte aquí mediante " +
                "Imágenes o Biblioteca. No afirmes que puedes recorrer la galería " +
                "personal automáticamente. " +
                "Un enlace a un chat compartido, una vista previa, una captura " +
                "o una ruta inventada NO sustituyen el archivo original requerido " +
                "por el conector. No uses una imagen de otra tendencia.",
            "1. Ejecuta mcp__TTendencias___TTActualidad__inspect_top30_images para obtener " +
                "el contexto editorial VIGENTE del Site. Resuelve exactamente la tendencia y, " +
                "si está agrupada, la identidad de su grupo. El nombre y el puesto aquí son pistas " +
                "de búsqueda, nunca prueba suficiente para escribir. Si el contexto editorial " +
                "actual no coincide con la identidad candidata, descarta la candidata y usa " +
                "SOLO los datos vigentes que puedas verificar de forma inequívoca. " +
                "Si el conector informa Authoritative Top 30 is stale, DETENTE: " +
                "informa «BLOQUEADO POR TOP 30 ANTICUADO» y reintenta la asociación " +
                "cuando la fuente se actualice, sin generar otra imagen.",
            "2. REQUISITO NO NEGOCIABLE: antes de invocar attach_trend_image deben existir " +
                "target_id editorial válido, revision, name, scope editorial, explicación literal " +
                "NO VACÍA y explained_at NO VACÍO que pertenezcan a LA MISMA revisión. " +
                "Si la ficha sigue pendiente, devuelve «PENDIENTE DE EXPLICACIÓN» y señala " +
                "«Elaborar desde cero» en TTActualidad. No intentes adjuntar una imagen a " +
                "scope term o a una explicación inventada. Cuando se explique, se podrá " +
                "reintentar con el mismo PNG sin volver a generarlo.",
            "3. Con el contexto exacto y vigente llama a " +
                "mcp__TTendencias___TTActualidad__verify_trend_image. Si ya existe una imagen " +
                "Site válida, no la sustituyas: omite attach y pasa al catálogo de iPhone " +
                "para verificar/reparar ÚNICAMENTE la asociación existente.",
            "4. Si el Site no tiene una imagen válida, adjunta el PNG ORIGINAL disponible " +
                "en ESTA conversación, generado aquí o aportado por el usuario, mediante " +
                "mcp__TTendencias___TTActualidad__attach_trend_image " +
                "con su parámetro file real y context EXACTO: project_id, target_id, name, " +
                "revision, scope, explanation, explained_at. " +
                "Un encargo antiguo del PC con status LAUNCHED sin entrega NO prohíbe " +
                "adjuntar el PNG aportado por el usuario: NO estás iniciando otra generación. " +
                "Si hay conflicto porque otra imagen terminó antes, no sobrescribas; verifica.",
            "5. Llama otra vez a mcp__TTendencias___TTActualidad__verify_trend_image " +
                "y confirma status verified, ruta pública real y SHA-256. Si falla, detente, " +
                "explica el error y conserva el original. No declares éxito ni actualices GitHub " +
                "basándote en un archivo local o una URL supuesta.",
            "6. Solo después del Site verificado, sincroniza esa MISMA imagen con iPhone: " +
                "lee trends/site-ai-images.json de GitHub main con fetch_file, conservando " +
                "TODAS las entradas. Actualiza únicamente el registro de (target_id, revision) " +
                "con explanation y explained_at LITERALES, image_url pública HTTPS del Site " +
                "y sha256 REAL. Usa update_file con SHA vigente; en conflicto relee y " +
                "reintenta. Si el manifiesto no es escribible, informa APP pendiente " +
                "pero nunca borres ni dupliques imágenes.",
            "7. Relee el manifiesto desde GitHub main para confirmar persistencia exacta. " +
                "Finaliza con los estados SEPARADOS SITE: verified/pending; APP: manifest verified/pending. " +
                "Da URL y SHA-256 solo si están realmente verificados. " +
                "Procesa UNA tendencia y UNA imagen. No cambies ni el texto ni el PC."
        ].joined(separator: "\n\n")
        copy(prompt)
        outcome = hasEditorialIdentity
            ? "Guía copiada. Pégala donde creaste la imagen; solo selecciónala si el original no está accesible."
            : "Guía copiada. Esta ficha aún no tiene identidad editorial completa: primero debe explicarse. Conserva tu PNG."
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
    private func publishOnX() {
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            outcome = "Sin texto para publicar"
            return
        }
        var parts = URLComponents(string: "https://twitter.com/intent/tweet")
        parts?.queryItems = [URLQueryItem(name: "text", value: fullText)]
        if let url = parts?.url { openURL(url) }
    }

    private func copyPhoto() async {
        // Prefer the verified AI image that is displayed in the trend card.
        // Fall back to the archive only if there is no accessible IA file.
        let sources: [URL] = [trend?.siteImageURL, news?.imageURL ?? trend?.imageURL].compactMap { $0 }
        guard !sources.isEmpty else {
            outcome = "No hay imagen IA ni foto de archivo disponible."
            return
        }
        for (index, url) in sources.enumerated() {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { continue }
                UIPasteboard.general.image = image
                outcome = "Foto copiada: " + (index == 0 && trend?.siteImageURL != nil
                    ? "imagen IA" : "archivo")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return
            } catch {
                continue
            }
        }
        outcome = "No se pudo descargar ninguna imagen. Reintenta tras actualizar."
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

