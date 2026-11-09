import SwiftUI
import UIKit

// Explicit, manual share draft. No Buffer or X publishing API is called.
// Only the human pressing Publish in the X app can send this post.
struct TTManualXPhotoShare: Identifiable {
    let id = UUID()
    let text: String
    let image: UIImage
}

// A regular iOS share sheet accepts an image AND text, but the receiving
// X share extension controls whether it uses both inputs. This is why the
// experimental button is separate from the unchanged text-only X intent.
struct TTManualXPhotoShareSheet: UIViewControllerRepresentable {
    let text: String
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [text, image],
            applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
