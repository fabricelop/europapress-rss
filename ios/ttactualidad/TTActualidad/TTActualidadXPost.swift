import Foundation

// Prepare a manual X draft with the fixed section URL as plain text, not a
// custom website card. X may independently unfurl links; the app never attaches
// a card, and the editor can attach the chosen original photo in X.
// Strip an existing copy of the same section URL to keep it unique.
enum TTActualidadXPost {
    static let newsURL = "https://ttactualidad.rainyraven22.chatgpt.site/noticias"
    static let trendsURL = "https://ttactualidad.rainyraven22.chatgpt.site/tendencias"
    private static let contentBudget = 280
    // X weighs each t.co URL at 23 characters, irrespective of display length.
    private static let sectionURLBudget = 23
    private static let sectionSeparator = "\n\n"

    static func weight(_ value: String) -> Int {
        value.reduce(into: 0) { total, glyph in
            let scalars = glyph.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation }) {
                total += 2
                return
            }
            for scalar in scalars {
                let n = scalar.value
                if n == 0xFE0F || n == 0x200D { continue }
                total += (n <= 0x10FF ||
                          (0x2000...0x200D).contains(n) ||
                          (0x2010...0x201F).contains(n) ||
                          (0x2032...0x2037).contains(n)) ? 1 : 2
            }
        }
    }

    private static func shortened(_ value: String, maxWeight: Int) -> String {
        guard weight(value) > maxWeight else { return value }
        guard maxWeight > 2 else { return "" }
        var result = ""
        var used = 0
        for glyph in value {
            let piece = String(glyph)
            let size = weight(piece)
            if used + size + 2 > maxWeight { break }
            result.append(glyph)
            used += size
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func payload(editorial: String, news: Bool) -> String {
        let site = news ? newsURL : trendsURL
        var text = editorial.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(site) {
            text = String(text.dropLast(site.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let editorialBudget = contentBudget - sectionURLBudget - weight(sectionSeparator)
        if weight(text) > editorialBudget {
            let suffixStart = text.range(of: "\n\n#", options: .backwards)?.lowerBound ??
                              text.range(of: "\n🌶️", options: .backwards)?.lowerBound
            if let suffixStart {
                let prefix = String(text[..<suffixStart])
                let suffix = String(text[suffixStart...])
                if weight(suffix) < editorialBudget - 35 {
                    text = shortened(prefix, maxWeight: editorialBudget - weight(suffix)) + suffix
                } else {
                    text = shortened(text, maxWeight: editorialBudget)
                }
            } else {
                text = shortened(text, maxWeight: editorialBudget)
            }
        }
        return text + sectionSeparator + site
    }
}
