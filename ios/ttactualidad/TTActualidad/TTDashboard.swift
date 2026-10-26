import SwiftUI
import UIKit

// Designed natively for the iPhone. No web container.
struct TTDashboard: View {
    @EnvironmentObject private var store: EditorialStore
    @StateObject private var github = GitHubEditor()
    @State private var search = ""
    @State private var showNewStory = false
    @State private var showSettings = false
    @State private var showArchivePhotos = false

    var body: some View {
        ZStack {
            TTTheme.base.ignoresSafeArea()
            LinearGradient(colors: [
                Color(red: 0.06, green: 0.23, blue: 0.32).opacity(0.72),
                TTTheme.base], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                topSections
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        heading
                        counters
                        connectedLabel
                        subTabs
                        searchField
                        if store.section == .trends { trendsContent }
                        else { newsContent }
                        Color.clear.frame(height: 18)
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 18)
                }
                .refreshable { await store.refresh() }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNewStory) {
            NewsSubmissionSheet(github: github).presentationDetents([.large])
        }
        .sheet(isPresented: $showSettings) {
            GitHubConnectionSheet(github: github).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showArchivePhotos) {
            ArchivePhotoGallery().environmentObject(store)
        }
        .onChange(of: store.section) { _, _ in
            search = ""
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(TTTheme.teal.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(TTTheme.teal.opacity(0.5)))
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(TTTheme.teal)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("TTActualidad")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .tracking(-1.0)
                Text("CONTROL EDITORIAL")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.2).foregroundStyle(TTTheme.teal)
            }
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: github.authenticated ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(github.authenticated ? TTTheme.teal : TTTheme.muted)
                    .font(.system(size: 20))
                    .frame(width: 42, height: 42)
                    .background(TTTheme.panel, in: Circle())
            }
            .accessibilityLabel("Conexión GitHub")
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isLoading { ProgressView().tint(TTTheme.teal) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 19, weight: .bold)) }
                }
                .frame(width: 42, height: 42)
                .background(TTTheme.panel, in: Circle())
            }
            .tint(TTTheme.teal)
            .disabled(store.isLoading)
            .accessibilityLabel("Actualizar")
        }
        .padding(.horizontal, 15)
        .padding(.top, 7)
        .padding(.bottom, 12)
    }

    private var topSections: some View {
        HStack(spacing: 4) {
            tab("TTiTTulares", active: store.section == .news) { store.section = .news }
            tab("TTendencias", active: store.section == .trends) { store.section = .trends }
        }
        .padding(5)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 15)
    }
    private func tab(_ name: String, active: Bool, change: @escaping () -> Void) -> some View {
        Button(action: change) {
            Text(name)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 41)
                .background(active ? Color(red: 0.15, green: 0.31, blue: 0.45) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? TTTheme.teal.opacity(0.55) : .clear))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.section == .trends ? "Top 30 España" : "Noticias listas")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                Text(store.section == .trends ? "Radar · Clasificación editorial" : "Noticias preparadas para publicar")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            Spacer()
            if store.section == .news {
                Button { showNewStory = true } label: {
                    Label("Noticia", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TTTheme.base)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(TTTheme.teal, in: Capsule())
                }
                .accessibilityLabel("Añadir noticia")
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 9) {
            metric(label: "NOTICIAS EN LISTAS", number: store.snapshot.news.count,
                   icon: "newspaper.fill", tint: TTTheme.teal)
            metric(label: "TENDENCIAS EN LISTAS", number: store.snapshot.trendListas.count,
                   icon: "chart.bar.fill", tint: TTTheme.blue)
        }
    }
    private func metric(label: String, number: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(TTTheme.muted).lineLimit(1).minimumScaleFactor(0.7)
            Text(String(number))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(tint.opacity(0.35)))
    }

    private var connectedLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: store.snapshot.partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(store.snapshot.partial ? .orange : TTTheme.teal)
            Text(store.snapshot.partial ? "Copia local disponible" : "GitHub directo · Sin Cloudflare")
            Spacer(minLength: 2)
            if let checked = store.snapshot.updatedAt {
                Text(checked, format: .dateTime.day().month().hour().minute())
            }
        }
        .font(.system(size: 10)).foregroundStyle(TTTheme.muted)
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    private var subTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if store.section == .trends {
                    chip("Top 30", number: store.snapshot.top30.count,
                         active: store.trendFilter == .top) { store.trendFilter = .top }
                    chip("Listas", number: store.snapshot.trendListas.count,
                         active: store.trendFilter == .listas) { store.trendFilter = .listas }
                    chip("En elaboración", number: store.snapshot.trendsElaboracion.count,
                         active: store.trendFilter == .elaboracion) { store.trendFilter = .elaboracion }
                    chip("Fotos archivo", number: ArchivePhotoGallery.photos(from: store.snapshot).count,
                         active: false) { showArchivePhotos = true }
                } else {
                    chip("Listas", number: store.snapshot.news.count,
                         active: store.newsFilter == .listas) { store.newsFilter = .listas }
                    chip("En elaboración", number: store.snapshot.newsElaboracion.count,
                         active: store.newsFilter == .elaboracion) { store.newsFilter = .elaboracion }
                    chip("Revisión", number: store.snapshot.newsRevision.count,
                         active: store.newsFilter == .revision) { store.newsFilter = .revision }
                    chip("Creciendo", number: store.snapshot.newsCreciendo.count,
                         active: store.newsFilter == .creciendo) { store.newsFilter = .creciendo }
                    chip("Tremending", number: store.snapshot.newsTremending.count,
                         active: store.newsFilter == .tremending) { store.newsFilter = .tremending }
                    chip("Fotos archivo", number: ArchivePhotoGallery.photos(from: store.snapshot).count,
                         active: false) { showArchivePhotos = true }
                }
            }
            .padding(.vertical, 2)
        }
    }
    private func chip(_ title: String, number: Int, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(String(number)).foregroundStyle(active ? TTTheme.teal : TTTheme.muted)
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(active ? TTTheme.teal.opacity(0.19) : TTTheme.panel, in: Capsule())
            .overlay(Capsule().stroke(active ? TTTheme.teal.opacity(0.65) : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(TTTheme.muted)
            TextField(store.section == .news ? "Buscar noticia..." : "Buscar tendencia...", text: $search)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(TTTheme.muted)
            }
            Divider().frame(height: 18)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .foregroundStyle(TTTheme.teal)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var newsContent: some View {
        let category: [NewsItem] = {
            switch store.newsFilter {
            case .listas: return store.snapshot.news
            case .elaboracion: return store.snapshot.newsElaboracion
            case .revision: return store.snapshot.newsRevision
            case .creciendo: return store.snapshot.newsCreciendo
            case .tremending: return store.snapshot.newsTremending
            }
        }()
        let visible = category.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.text.localizedCaseInsensitiveContains(search)
        }
        if visible.isEmpty { emptyNotice("No hay noticias en Listas") }
        ForEach(visible) { story in
            NewsTile(item: story, github: github, settings: $showSettings)
        }
    }

    @ViewBuilder private var trendsContent: some View {
        let category: [TrendItem] = {
            switch store.trendFilter {
            case .top: return store.snapshot.top30
            case .listas: return store.snapshot.trendListas
            case .elaboracion: return store.snapshot.trendsElaboracion
            }
        }()
        let visible = category.filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.explanation.localizedCaseInsensitiveContains(search)
            }
        if visible.isEmpty { emptyNotice("No hay tendencias para mostrar") }
        ForEach(visible) { item in
            TrendTile(item: item, showRank: store.trendFilter == .top,
                      github: github, settings: $showSettings)
        }
    }
    private func emptyNotice(_ label: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(TTTheme.muted)
            Text(label).font(.headline)
            Text("Desliza para actualizar desde GitHub.").font(.caption).foregroundStyle(TTTheme.muted)
        }
        .frame(maxWidth: .infinity).padding(24)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NewsTile: View {
    let item: NewsItem
    @ObservedObject var github: GitHubEditor
    @Binding var settings: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Label(item.status, systemImage: item.status == "LISTA" ? "checkmark.circle.fill" : "clock.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(TTTheme.teal)
                if item.sources > 0 { Text("Fuentes: \(item.sources)").foregroundStyle(TTTheme.muted) }
                Spacer()
                if let date = item.publishedAt {
                    Text(date, format: .dateTime.day().month().hour().minute())
                }
            }
            .font(.system(size: 10))
            Text(item.title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            if let image = item.imageURL {
                AsyncImage(url: image) { picture in picture.resizable().scaledToFill() } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(TTTheme.panel).overlay(ProgressView())
                }
                .frame(height: 155).frame(maxWidth: .infinity)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(item.factual.isEmpty ? (item.text.isEmpty ? "Pendiente de explicación editorial." : item.text) : item.factual)
                .font(.system(size: 14))
                .lineSpacing(4).foregroundStyle(Color.white.opacity(0.86))
                .textSelection(.enabled)
            if !item.closer.isEmpty {
                Text(item.closer).font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(red: 1, green: 0.80, blue: 0.55))
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            EditorialActions(news: item, github: github, showSettings: $settings)
        }
        .padding(15)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(TTTheme.muted.opacity(0.25)))
    }
}

private struct TrendTile: View {
    let item: TrendItem
    let showRank: Bool
    @ObservedObject var github: GitHubEditor
    @Binding var settings: Bool

    private var ageColor: Color {
        switch item.ageBand() {
        case 1: return TTTheme.green
        case 2: return TTTheme.yellow
        case 3: return TTTheme.red
        default: return TTTheme.panel
        }
    }
    private var outline: Color {
        switch item.ageBand() {
        case 1: return TTTheme.teal.opacity(0.7)
        case 2: return .yellow.opacity(0.65)
        case 3: return .red.opacity(0.6)
        default: return Color.white.opacity(0.16)
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 13) {
                if item.explanation.isEmpty {
                    Text("Aún no hay explicación editorial.")
                        .font(.subheadline).foregroundStyle(TTTheme.muted)
                } else {
                    Text(item.explanation)
                        .font(.system(size: 14)).lineSpacing(4)
                        .textSelection(.enabled)
                }
                if let image = item.imageURL {
                    AsyncImage(url: image) { picture in picture.resizable().scaledToFit() } placeholder: {
                        ProgressView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                EditorialActions(trend: item, github: github, showSettings: $settings)
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 6) {
                if showRank {
                    Text("#\(item.rank)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(TTTheme.blue)
                        .frame(width: 33, alignment: .leading)
                }
                Text(item.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.status)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(2).multilineTextAlignment(.trailing)
                    if let date = item.lastExplained {
                        Text("Exp. " + date.formatted(.dateTime.day().month().hour().minute()))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: 113, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .tint(TTTheme.muted)
        .padding(12)
        .background(ageColor, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(outline))
    }
}
