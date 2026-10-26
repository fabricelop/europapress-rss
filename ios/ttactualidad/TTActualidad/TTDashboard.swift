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
    @State private var showCombinedListas = false
    @State private var showEditorialHub = false

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
                        if store.section == .news && !showCombinedListas { sourceCounters }
                        connectedLabel
                        subTabs
                        searchField
                        if showCombinedListas { combinedListasContent }
                        else if store.section == .trends { trendsContent }
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
        .sheet(isPresented: $showEditorialHub) {
            EditorialHub(
                openLists: { showCombinedListas = true },
                openRadar: { showCombinedListas = false; store.section = .trends; store.trendFilter = .top },
                openWorking: { showCombinedListas = false; store.section = .news; store.newsFilter = .elaboracion }
            ).environmentObject(store)
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
            Button { showEditorialHub = true } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(TTTheme.teal)
                    .font(.system(size: 19))
                    .frame(width: 36, height: 42)
            }
            .accessibilityLabel("Tablero y novedades")
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
            tab("TTiTTulares", active: !showCombinedListas && store.section == .news) {
                showCombinedListas = false; store.section = .news
            }
            tab("TTendencias", active: !showCombinedListas && store.section == .trends) {
                showCombinedListas = false; store.section = .trends
            }
            tab("Listas", active: showCombinedListas) { showCombinedListas = true }
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
                Text(showCombinedListas ? "Listas editoriales" :
                     store.section == .trends ? "Top 30 España" : "Noticias listas")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                Text(showCombinedListas ? "Publica o gestiona todo desde aquí" :
                     store.section == .trends ? "Radar · Clasificación editorial" : "Noticias preparadas para publicar")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            Spacer()
            if store.section == .news && !showCombinedListas {
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

    private func signedDelta(_ delta: Int?) -> String {
        guard let delta else { return "(—)" }
        return "(" + (delta > 0 ? "+" : "") + String(delta) + ")"
    }

    private var sourceCounters: some View {
        HStack(spacing: 12) {
            Label("1 fuente", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(TTTheme.muted)
            Text(store.snapshot.oneSourceCount.map(String.init) ?? "—")
                .fontWeight(.bold).monospacedDigit()
            Text(signedDelta(store.snapshot.oneSourceDelta))
                .foregroundStyle(TTTheme.teal)
            Spacer(minLength: 5)
            Text("2 fuentes").foregroundStyle(TTTheme.muted)
            Text(store.snapshot.twoSourceCount.map(String.init) ?? "—")
                .fontWeight(.bold).monospacedDigit()
            Text(signedDelta(store.snapshot.twoSourceDelta))
                .foregroundStyle(TTTheme.teal)
        }
        .font(.system(size: 11, weight: .medium))
        .minimumScaleFactor(0.7).lineLimit(1)
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel("Radar: noticias con una fuente y dos fuentes, variación respecto al radar anterior")
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
        Group {
        if !showCombinedListas {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if store.section == .trends {
                    chip("Top 30", number: store.snapshot.top30.count,
                         active: store.trendFilter == .top) { store.trendFilter = .top }
                    chip("Listas", number: store.snapshot.trendListas.count,
                         active: store.trendFilter == .listas) { store.trendFilter = .listas }
                    chip("En elaboración", number: store.snapshot.trendsElaboracion.count,
                         active: store.trendFilter == .elaboracion) { store.trendFilter = .elaboracion }
                    chip("Nuevas", number: filteredTrends(.nuevas).count,
                         active: store.trendFilter == .nuevas) { store.trendFilter = .nuevas }
                    chip("Recientes", number: filteredTrends(.recientes).count,
                         active: store.trendFilter == .recientes) { store.trendFilter = .recientes }
                    chip("Pendientes", number: filteredTrends(.pendientes).count,
                         active: store.trendFilter == .pendientes) { store.trendFilter = .pendientes }
                    chip("Antiguas", number: filteredTrends(.antiguas).count,
                         active: store.trendFilter == .antiguas) { store.trendFilter = .antiguas }
                    chip("↑↓", number: filteredTrends(.movimientos).count,
                         active: store.trendFilter == .movimientos) { store.trendFilter = .movimientos }
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

    private var combinedListasContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("TTiTTulares", systemImage: "newspaper.fill")
                    .font(.headline).foregroundStyle(TTTheme.teal)
                Spacer()
                Text(String(store.snapshot.news.count))
                    .font(.headline.monospacedDigit()).foregroundStyle(TTTheme.teal)
            }
            ForEach(store.snapshot.news.filter {
                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            }) { story in
                NewsTile(item: story, github: github, settings: $showSettings)
            }
            HStack {
                Label("TTendencias", systemImage: "chart.bar.fill")
                    .font(.headline).foregroundStyle(TTTheme.blue)
                Spacer()
                Text(String(store.snapshot.trendListas.count))
                    .font(.headline.monospacedDigit()).foregroundStyle(TTTheme.blue)
            }
            .padding(.top, 8)
            LazyVStack(spacing: 5) {
                ForEach(store.snapshot.trendListas.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                }) { item in
                    TrendTile(item: item, showRank: false,
                              github: github, settings: $showSettings)
                }
            }
            if store.snapshot.news.isEmpty && store.snapshot.trendListas.isEmpty {
                emptyNotice("No hay elementos en Listas")
            }
        }
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

    private func filteredTrends(_ filter: TrendFilter) -> [TrendItem] {
        let items = store.snapshot.top30
        switch filter {
        case .top: return items
        case .listas: return store.snapshot.trendListas
        case .elaboracion: return store.snapshot.trendsElaboracion
        case .nuevas:
            return items.filter { $0.movement == "new" ||
                ($0.enteredAt.map { Date().timeIntervalSince($0) < 3 * 3600 &&
                    Date().timeIntervalSince($0) >= 0 } ?? false) }
        case .recientes:
            return items.filter { $0.lastExplained.map {
                Date().timeIntervalSince($0) >= 0 && Date().timeIntervalSince($0) < 12 * 3600
            } ?? false }
        case .pendientes: return items.filter { $0.explanation.isEmpty }
        case .antiguas: return items.filter { $0.ageBand() == 3 }
        case .movimientos: return items.filter { $0.rankDelta != 0 ||
            ["up", "down"].contains($0.movement) }
        }
    }

    @ViewBuilder private var trendsContent: some View {
        let category = filteredTrends(store.trendFilter)
        let visible = category.filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.explanation.localizedCaseInsensitiveContains(search)
            }
        if visible.isEmpty { emptyNotice("No hay tendencias para mostrar") }
        LazyVStack(spacing: 5) {
            ForEach(visible) { item in
                TrendTile(item: item, showRank: store.trendFilter == .top,
                          github: github, settings: $showSettings)
            }
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

    private var shortStatus: String {
        switch item.status {
        case "EN ELABORACIÓN": return "ELAB."
        case "PREPARACIÓN MANUAL": return "MANUAL"
        case "EXPLICADA": return "EXPL."
        case "PENDIENTE": return "PEND."
        default: return item.status
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.status)
                        .font(.caption2.weight(.bold)).foregroundStyle(TTTheme.muted)
                    Spacer()
                    if let date = item.lastExplained {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(.caption2).foregroundStyle(TTTheme.muted)
                    }
                }
                if item.explanation.isEmpty {
                    Text("Aún no hay explicación editorial.")
                        .font(.subheadline).foregroundStyle(TTTheme.muted)
                } else {
                    Text(item.explanation)
                        .font(.system(size: 14)).lineSpacing(3)
                        .textSelection(.enabled)
                }
                if let image = item.imageURL {
                    AsyncImage(url: image) { picture in picture.resizable().scaledToFit() } placeholder: {
                        ProgressView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("Sin fotografía de archivo", systemImage: "photo")
                        .font(.caption2).foregroundStyle(TTTheme.muted)
                }
                EditorialActions(trend: item, github: github, showSettings: $settings)
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 5) {
                if showRank {
                    Text("#\(item.rank)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit().foregroundStyle(TTTheme.blue)
                        .frame(width: 28, alignment: .leading)
                }
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showRank && item.rankDelta != 0 {
                    Text(item.rankDelta > 0 ? "↑\(item.rankDelta)" : "↓\(abs(item.rankDelta))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(item.rankDelta > 0 ? TTTheme.teal : Color.orange)
                }
                Text(shortStatus)
                    .font(.system(size: 9, weight: .heavy))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(width: 50, alignment: .trailing)
                if let date = item.lastExplained {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 35, alignment: .trailing)
                }
            }
        }
        .tint(TTTheme.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ageColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(outline.opacity(0.7)))
    }
}
