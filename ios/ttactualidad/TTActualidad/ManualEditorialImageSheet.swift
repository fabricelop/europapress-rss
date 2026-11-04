import CryptoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Selects one image for an EXACT editorial episode. This is not a new
// publisher: the approved inbox and both public readbacks remain authoritative.
struct ManualEditorialImageSheet: View {
    @ObservedObject var github: GitHubEditor
    let project: String
    let editorialID: String
    let revision: Int
    let title: String
    let editorialText: String

    @Environment(\.dismiss) private var dismiss
    @State private var chosenPhoto: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var showInbox = false
    @State private var imagePNG: Data?
    @State private var preview: UIImage?
    @State private var working = false
    @State private var notice = ""
    @State private var published = false
    @State private var githubImageURL: URL?

    private struct UploadResult: Decodable {
        let id: String
        let state: String
        let identity: Identity
    }

    private struct Identity: Codable {
        let project: String
        let editorialId: String
        let revision: Int
        let episodeFingerprint: String
        let commandId: String
        let rasterSHA256: String
    }

    private struct Decision: Encodable {
        let action: String
        let expectedIdentity: Identity
    }

    private struct Publication: Decodable {
        let state: String
        let appVerified: Bool?
        let sitesVerified: Bool?
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.headline)
                    Text(project == "ttendencias" ? "TTendencias" : "TTiTTulares")
                        .foregroundStyle(.secondary).font(.caption)
                    Text("Ficha " + editorialID + " · revisión " + String(revision))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Selecciona una fotografía, dibujo o imagen ya creada. Se asociará solo a esta ficha y revisión.")
                        .font(.subheadline)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 260)
                            .accessibilityLabel("Imagen seleccionada para esta ficha")
                    } else {
                        ContentUnavailableView("Sin imagen", systemImage: "photo",
                            description: Text("Pega desde el portapapeles o elige una imagen de Fotos o Archivos."))
                    }
                    Button {
                        paste()
                    } label: {
                        Label("Pegar imagen", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(working)
                    PhotosPicker(selection: $chosenPhoto, matching: .images) {
                        Label("Elegir de Fotos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(working)
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Elegir de Archivos", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(working)
                    if !notice.isEmpty {
                        Text(notice).font(.footnote)
                            .foregroundStyle(published ? Color.green : Color.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if let githubImageURL {
                        Link("Abrir original guardado en GitHub", destination: githubImageURL)
                            .font(.footnote)
                    }
                    if working { ProgressView("Validando y asociando imagen…") }
                    Button {
                        Task { await submit() }
                    } label: {
                        Label("Subir y aprobar", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || imagePNG == nil || published || !github.authenticated)
                    Text("La confirmación solo se mostrará cuando la web y la app hayan verificado la publicación. En caso de error, la imagen seleccionada permanece aquí para reintentar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Abrir imágenes pendientes") { showInbox = true }
                        .disabled(working)
                }
                .padding()
            }
            .navigationTitle("Añadir imagen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }.disabled(working)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 40_000_000 {
                        notice = "Archivo demasiado grande (máximo 40 MB de entrada)."
                        return
                    }
                    select(try Data(contentsOf: url))
                } catch {
                    notice = "No se pudo leer el archivo seleccionado."
                }
            }
            .onChange(of: chosenPhoto) { _, selected in
                guard let selected else { return }
                Task {
                    do {
                        guard let bytes = try await selected.loadTransferable(type: Data.self) else {
                            notice = "No se pudo acceder a la foto."
                            return
                        }
                        select(bytes)
                    } catch {
                        notice = "No se pudo importar esa foto."
                    }
                }
            }
            .sheet(isPresented: $showInbox) {
                ImageApprovalInbox(github: github).presentationDetents([.large])
            }
        }
        .preferredColorScheme(.dark)
    }

    private func paste() {
        if let data = UIPasteboard.general.data(forPasteboardType: UTType.png.identifier) {
            select(data)
        } else if let image = UIPasteboard.general.image {
            select(image.pngData() ?? Data())
        } else {
            notice = "El portapapeles no contiene una imagen compatible."
        }
    }

    private func select(_ input: Data) {
        guard !working else { return }
        published = false
        githubImageURL = nil
        imagePNG = nil
        preview = nil
        guard !input.isEmpty, input.count <= 40_000_000, let image = UIImage(data: input),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 10_000, image.size.height <= 10_000,
              image.size.width * image.size.height <= 60_000_000 else {
            notice = "La imagen no es compatible o supera los 40 MB."
            return
        }
        // Normalize orientation and drop EXIF/location metadata. Backend accepts
        // PNG only. Scaling is deterministic, so an uncertain POST can be retried
        // with the same episode, command identity and original raster hash.
        var output: Data?
        for maxSide in [2400.0, 1800.0, 1400.0, 1024.0, 768.0] {
            let ratio = min(1.0, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, (image.size.width * ratio).rounded()),
                              height: max(1, (image.size.height * ratio).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let png = UIGraphicsImageRenderer(size: size, format: format)
                .pngData { context in image.draw(in: CGRect(origin: .zero, size: size)) }
            if png.count <= 8_000_000 {
                output = png
                break
            }
        }
        guard let output, let normalized = UIImage(data: output) else {
            notice = "No se pudo adaptar la imagen al límite de 8 MB."
            return
        }
        imagePNG = output
        preview = normalized
        notice = "Imagen preparada. Pulsa «Subir y aprobar»."
    }

    private func commandID(_ png: Data) -> String {
        let raster = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let episode = [project, editorialID, String(revision), editorialText, raster]
            .joined(separator: "\u{001f}")
        let key = SHA256.hash(data: Data(episode.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "manual-" + key
    }

    private func submit() async {
        guard !working, let png = imagePNG, github.authenticated else { return }
        working = true
        defer { working = false }
        do {
            let (data, code) = try await github.uploadEditorialImage(
                project: project, editorialID: editorialID, revision: revision,
                title: title, editorialText: editorialText, png: png,
                commandID: commandID(png))
            let serverError = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            guard code == 200 || code == 201 else {
                if code == 404 {
                    // The Sites upload route is missing. The editor's existing
                    // Contents permission can persist the ORIGINAL image and
                    // exact assignment without a second server or secret.
                    // Never claim Sites publication from a GitHub receipt.
                    notice = "Servidor de imágenes sin subida manual; intentando el circuito GitHub…"
                    let url = try await github.associateManualImageInGitHub(
                        project: project, editorialID: editorialID, revision: revision,
                        editorialText: editorialText, png: png)
                    githubImageURL = url
                    await SiteAIImageCatalog.invalidateCache()
                    await NewsAIImageCatalog.invalidateCache()
                    notice = "Imagen original guardada y asociada en GitHub. Actualiza la app para verla. Su aparición en la web aún no está confirmada."
                } else if code == 409 {
                    notice = "La identidad o revisión de la ficha ya no coincide (409: " + (serverError ?? "conflicto") + "). La imagen permanece seleccionada."
                } else if code == 503 {
                    notice = "El servidor de imágenes no está disponible (503: " + (serverError ?? "sin detalle") + "). No se ha confirmado ninguna subida."
                } else {
                    notice = "No se confirmó la subida (HTTP \(code): " + (serverError ?? "sin detalle") + "). Imagen conservada."
                }
                return
            }
            let receipt = try JSONDecoder().decode(UploadResult.self, from: data)
            guard receipt.identity.project == project,
                  receipt.identity.editorialId == editorialID,
                  receipt.identity.revision == revision,
                  receipt.identity.commandId == commandID(png),
                  receipt.identity.rasterSHA256 ==
                      SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined()
            else {
                notice = "La identidad de la subida no coincide con la ficha. No se aprobará."
                return
            }
            if receipt.state == "published" {
                notice = "El servidor ya registró la publicación de esta imagen. Comprueba web y app."
                return
            }
            // Retry the same /decision for a previously approved candidate:
            // the Site may finish pending publication on that idempotent call.
            guard ["pending", "existing", "approved_awaiting_publication"].contains(receipt.state) else {
                notice = "Estado de imagen " + receipt.state + ". No se ha realizado una nueva aprobación."
                return
            }
            let decision = try JSONEncoder().encode(Decision(action: "approve",
                                                              expectedIdentity: receipt.identity))
            let (resultData, resultCode) = try await github.privateImageInboxRequest(
                path: "/v1/images/" + receipt.id + "/decision", method: "POST", jsonBody: decision)
            let errorCode = ((try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any])?["error"] as? String
            guard resultCode == 200 else {
                notice = "Imagen recibida en la bandeja, pero aprobación pendiente (HTTP \(resultCode), \(errorCode ?? "sin detalle")). No vuelvas a generar ni subir otra imagen."
                return
            }
            let publication = try JSONDecoder().decode(Publication.self, from: resultData)
            if publication.state == "published" &&
                publication.appVerified == true && publication.sitesVerified == true {
                published = true
                await SiteAIImageCatalog.invalidateCache()
                await NewsAIImageCatalog.invalidateCache()
                notice = "Imagen publicada y verificada en web y app."
            } else if publication.state == "approved_awaiting_publication" {
                notice = "Imagen aprobada. Publicación pendiente: consulta Imágenes pendientes o actualiza la ficha."
            } else {
                notice = "Recibida la respuesta " + publication.state + ". No hay confirmación de publicación."
            }
        } catch {
            notice = "No se ha confirmado la subida o publicación: " + error.localizedDescription
                + ". La foto sigue seleccionada, sin generar duplicados."
        }
    }
}
