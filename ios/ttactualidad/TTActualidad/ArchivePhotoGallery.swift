import SwiftUI
import UIKit

/// Only editorial archive photographs are shown here. This gallery never
/// reads ChatGPT Images, AI-generated image folders or TTImages transport.
struct ArchivePhotoGallery: View {
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ArchivePhoto?
    @State private var notice = ""

    struct ArchivePhoto: Identifiable {
        let id: String
        let title: String
        let group: String
        let date: Date?
        let url: URL
    }

    static func photos(from snapshot: EditorialSnapshot) -> [ArchivePhoto] {
        var photos: [ArchivePhoto] = []
        var urls = Set<String>()
        func add(id: String, title: String, group: String, date: Date?, url: URL?) {
            guard let url, url.scheme == "https",
                  urls.insert(url.absoluteString).inserted else { return }
            photos.append(ArchivePhoto(id: id, title: title, group: group, date: date, url: url))
        }
        for item in snapshot.news {
            add(id: "news-" + item.id, title: item.title, group: "TTiTTulares",
                date: item.publishedAt, url: item.imageURL)
        }
        for item in snapshot.trendListas {
            add(id: "ready-" + item.id, title: item.name, group: "TTendencias · Listas",
                date: item.lastExplained, url: item.imageURL)
        }
        for item in snapshot.top30 {
            add(id: "top-" + item.id, title: item.name, group: "TTendencias · Top 30",
                date: item.lastExplained, url: item.imageURL)
        }
        return photos.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var photos: [ArchivePhoto] { Self.photos(from: store.snapshot) }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ZStack {
                TTTheme.base.ignoresSafeArea()
                if photos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42)).foregroundStyle(TTTheme.teal)
                        Text("Sin fotos de archivo disponibles")
                            .font(.headline)
                        Text("No hay fotografías de archivo vinculadas a las noticias y tendencias actuales. Puedes seguir utilizando «Abrir ChatGPT Images» desde cada tarjeta para gestionar las imágenes IA por separado.")
                            .font(.subheadline)
                            .foregroundStyle(TTTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(26)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(photos) { photo in
                                Button { selected = photo } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AsyncImage(url: photo.url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            case .failure:
                                                Image(systemName: "photo.badge.exclamationmark")
                                                    .foregroundStyle(TTTheme.muted)
                                            default:
                                                ProgressView().tint(TTTheme.teal)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 138)
                                        .clipped()
                                        .background(TTTheme.panel)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        Text(photo.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(photo.group)
                                            .font(.system(size: 10))
                                            .foregroundStyle(TTTheme.teal)
                                            .lineLimit(1)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 13))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .navigationTitle("Fotos de archivo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(item: $selected) { photo in
                ArchivePhotoDetail(photo: photo)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ArchivePhotoDetail: View {
    let photo: ArchivePhotoGallery.ArchivePhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ZStack {
                TTTheme.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AsyncImage(url: photo.url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                ContentUnavailableView("No se pudo cargar la fotografía", systemImage: "photo")
                            default:
                                ProgressView().tint(TTTheme.teal)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Text(photo.title).font(.headline)
                        Text(photo.group).font(.caption).foregroundStyle(TTTheme.muted)
                        if let date = photo.date {
                            Text(date, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(TTTheme.muted)
                        }
                        Button {
                            Task {
                                do {
                                    let (data, response) = try await URLSession.shared.data(from: photo.url)
                                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                                          let image = UIImage(data: data) else {
                                        throw URLError(.cannotDecodeContentData)
                                    }
                                    UIPasteboard.general.image = image
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    message = "Fotografía copiada al portapapeles"
                                } catch {
                                    message = "No se pudo copiar la fotografía"
                                }
                            }
                        } label: {
                            Label("Copiar foto de archivo", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(TTTheme.teal)
                        Button {
                            openURL(photo.url)
                        } label: {
                            Label("Abrir fotografía original", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        if !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(TTTheme.muted)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Foto de archivo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
