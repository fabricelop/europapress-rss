import Foundation

/// All copied image-delivery instructions pass through the same manual-approval policy.
/// Legacy templates remain for context extraction, never for publication instructions.
enum ImageApprovalInstructions {
    static func replacingLegacy(_ legacy: String) -> String {
        guard let line = legacy.components(separatedBy: .newlines).first(where: { $0.hasPrefix("{") }),
              let bytes = line.data(using: .utf8),
              let context = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return "BLOQUEADO: faltan identidad, revisión, texto o fecha. Conserva el original y actualiza la ficha; no generes ni publiques." }
        return manual(project: context["event_id"] == nil ? "ttendencias" : "ttittulares",
            id: context["target_id"] as? String ?? context["event_id"] as? String ?? "",
            revision: context["revision"] as? Int ?? -1,
            title: context["name"] as? String ?? context["title"] as? String ?? "",
            text: context["explanation"] as? String ?? context["editorial_text"] as? String ?? "",
            date: context["explained_at"] as? String ?? context["prepared_at"] as? String ?? "",
            create: true)
    }

    static func manual(project: String, id: String, revision: Int, title: String,
                       text: String, date: String, create: Bool) -> String {
        guard id.range(of: "^[A-Za-z0-9_-]{3,160}$", options: .regularExpression) != nil,
              revision >= 0, !text.isEmpty, !date.isEmpty,
              !id.hasPrefix("site-term-") else {
            return "PENDIENTE DE EXPLICACIÓN: identidad incompleta. No generes ni publiques; conserva el original."
        }
        let metadata: [String: Any] = ["project": project, "editorialId": id,
            "revision": revision, "title": title, "editorialText": text, "editorialAt": date]
        let json = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
        TT_IMAGE_PRIVATE_APPROVAL_V1 — ENTREGA PRIVADA, APROBACIÓN SOLO EN APP
        \(create ? "Genera como máximo UNA imagen con la referencia visual; si existe el original exacto, reutilízalo." : "NO uses ImageGen ni generes otra imagen. Usa exclusivamente el original adjuntado para esta ficha.")
        Descubre ANTES de generar la herramienta privada submit_image_for_approval de TTActualidad. Si falta, detente y conserva el original: no uses una subida pública alternativa.
        CONTEXTO EXACTO (no cambiar ID, revisión, texto ni fecha):
        \(json)
        Entrega el PNG ORIGINAL con file y este objeto con context a submit_image_for_approval.
        La herramienta calcula las huellas reales y revalida la ficha. No uses capturas, miniaturas, otra ficha, ni conviertas o renombres JPEG/WebP para fingir PNG. Si el formato no es compatible, conserva el original e informa del bloqueo.
        Confirma únicamente RECEPCIÓN PRIVADA y su identificador real. Nada se asocia ni publica todavía. No escribas originales ni catálogos en GitHub público, ni uses attachBytes o scripts de asociación.
        El usuario abrirá Imágenes pendientes en la APP y elegirá Aprobar o Rechazar. Solo Aprobar autoriza ese original para esa revisión y episodio, conjuntamente en APP y web. No apruebes en su nombre ni ofrezcas publicación solo web/app.
        No modificar texto, fotos de archivo, Windows, X o Telegram. Si la entrega falla, conservar el original y reintentar solo el transporte, nunca generar otra imagen.
        """
    }
}
