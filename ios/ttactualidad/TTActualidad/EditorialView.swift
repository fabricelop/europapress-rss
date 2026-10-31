import SwiftUI

struct EditorialView: View {
    @EnvironmentObject private var store: EditorialStore
    @State private var search = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Proyecto", selection: $store.section) {
                    ForEach(EditorialSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .accessibilityLabel("Proyecto editorial")

                summary
                if store.section == .trends {
                    Picker("Vista de tendencias", selection: $store.trendFilter) {
                        ForEach(TrendFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if store.section == .news {
                            newsList
                        } else {
                            trendsList
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .refreshable { await store.refresh() }
                footer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("TTActualidad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Actualizar desde GitHub")
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                labelCount("Noticias en Listas", count: store.snapshot.news.count, color: .mint)
                Spacer()
                labelCount("Tendencias en Listas", count: store.snapshot.trendListas.count, color: .cyan)
            }
            .padding(.vertical, 4)

            HStack(spacing: 6) {
                Image(systemName: store.snapshot.partial ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle")
                Text(store.message)
                Spacer()
                if let date = store.snapshot.updatedAt {
                    Text(date, format: .dateTime.day().month().hour().minute())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(store.liveStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func labelCount(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(count)).font(.title.monospacedDigit().bold()).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var newsList: some View {
        let rows = store.snapshot.news.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        }
        searchField
        if rows.isEmpty {
            ContentUnavailableView("No hay noticias en Listas", systemImage: "newspaper",
                                   description: Text("Desliza hacia abajo para consultar GitHub."))
                .padding(.top, 20)
        } else {
            ForEach(rows) { row in
                DisclosureGroup {
                    if !row.text.isEmpty {
                        Text(row.text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        ShareLink(item: row.text) {
                            Label("Compartir texto", systemImage: "square.and.arrow.up")
                        }
                        .font(.caption)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.subheadline.weight(.semibold))
                        if let date = row.publishedAt {
                            Text(date, format: .dateTime.day().month().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var trendsList: some View {
        let rows = (store.trendFilter == .top ?
            store.snapshot.top30 : store.snapshot.trendListas).filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.explanation.localizedCaseInsensitiveContains(search)
            }
        searchField
        if rows.isEmpty {
            ContentUnavailableView("No hay tendencias en esta vista", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Desliza para actualizar desde GitHub."))
                .padding(.top, 20)
        } else {
            ForEach(rows) { row in
                TrendRowView(item: row, showRank: store.trendFilter == .top, inLists: store.trendFilter == .listas)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 4)
    }

    private var footer: some View {
        Text("Datos: GitHub directo · Sin Cloudflare · Live Activity actualizada al abrir o refrescar la aplicación")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
    }
}

private struct TrendRowView: View {
    let item: TrendItem
    let showRank: Bool
    var inLists = false

    private var bandColor: Color {
        if inLists && item.isCovered && !item.isJointGroup {
            return Color(red: 0.30, green: 0.15, blue: 0.44)
        }
        switch item.ageBand() {
        case 1: return Color(red: 0.12, green: 0.36, blue: 0.25)
        case 2: return Color(red: 0.40, green: 0.32, blue: 0.11)
        case 3: return Color(red: 0.40, green: 0.16, blue: 0.20)
        default: return Color(uiColor: .secondarySystemGroupedBackground)
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if item.explanation.isEmpty {
                    Text("Todavía no hay explicación editorial disponible.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.explanation)
                        .textSelection(.enabled)
                    ShareLink(item: item.explanation) {
                        Label("Compartir explicación", systemImage: "square.and.arrow.up")
                    }
                    .font(.caption)
                }
                if let aiImage = item.siteImageURL {
                    TrendEditorialImage(url: aiImage, label: "Imagen IA · TTendencias Site")
                } else if let archivePhoto = item.imageURL {
                    TrendEditorialImage(url: archivePhoto, label: "Foto de archivo")
                }
                if item.inListas {
                    Label("Disponible en Listas", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.subheadline)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if showRank {
                    Text("#\(item.rank)")
                        .font(.subheadline.monospacedDigit().bold())
                        .frame(width: 36, alignment: .leading)
                }
                if let imageURL = item.siteImageURL ?? item.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 52, height: 40)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel(item.siteImageURL == nil
                                        ? "Fotografía de archivo" : "Imagen IA")
                }
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.status)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    if let date = item.lastExplained {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 115, alignment: .trailing)
            }
        }
        .tint(.primary)
        .padding(12)
        .background(bandColor, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TrendEditorialImage: View {
    let url: URL
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label("Imagen no disponible. Se conserva la referencia original.",
                          systemImage: "photo.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
