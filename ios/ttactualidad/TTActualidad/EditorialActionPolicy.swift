import Foundation

enum EditorialActionPolicy {
    static let imagesURL = "https://chatgpt.com/images"
    static let projectURL = "https://chatgpt.com/g/g-p-6aad81af6424819194017c5a04d611db/project"

    static func targetRevision(decision: String, current: Int) -> Int {
        current + (["rework", "hints"].contains(decision) ? 1 : 0)
    }

    // A failed/missing IA must never silently copy the archive photo, or vice versa.
    static func imageURL(ai: Bool, archive: URL?, generated: URL?) -> URL? {
        ai ? generated : archive
    }

    static func prompt(visual: String, association: String, associate: Bool) -> String {
        associate ? visual + "\n\n" + association : visual
    }
}
